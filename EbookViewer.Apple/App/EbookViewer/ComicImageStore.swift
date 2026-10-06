import Foundation
import CoreGraphics
import ImageIO
import Observation
import EbookCore

/// CGImage を NSCache に入れるための箱。
final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// コミックのページ画像をデコードしてキャッシュし、周辺ページを先読みする。
/// 画像は表示用に長辺 3000px まで縮小してデコードするので、巨大なスキャン画像でもメモリを使いすぎない。
@MainActor
@Observable
final class ComicImageStore {
    let comic: ComicDocument
    nonisolated static let displayMaxPixel = 3000
    nonisolated static let thumbnailMaxPixel = 240

    /// キャッシュが更新されるたびに増える。ビューはこれを読むことで (Observation 経由で) 再描画される。
    private(set) var generation = 0
    /// 既知のページ寸法。デコード済みのページだけでなく、起動時のヘッダー走査でも埋まる。
    private(set) var sizes: [Int: CGSize] = [:]

    @ObservationIgnored private let images = NSCache<NSNumber, CGImageBox>()
    @ObservationIgnored private let thumbnails = NSCache<NSNumber, CGImageBox>()
    @ObservationIgnored private var loadingImages: Set<Int> = []
    @ObservationIgnored private var loadingThumbnails: Set<Int> = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    init(comic: ComicDocument) {
        self.comic = comic
        images.totalCostLimit = 400 * 1024 * 1024
        thumbnails.countLimit = 600
        for (i, page) in comic.pages.enumerated() {
            if let s = page.knownSize { sizes[i] = CGSize(width: s.width, height: s.height) }
        }
        startSizeScan()
    }

    /// 別のコミックに切り替えるときに呼ぶ。進行中の走査を止め、以後の読み込み要求を無視する。
    func cancel() {
        cancelled = true
        scanTask?.cancel()
    }

    var pageCount: Int { comic.pageCount }

    /// 表示用画像。未デコードなら読み込みを始めて nil を返す (完了すると generation が進み再描画される)。
    func image(_ index: Int) -> CGImage? {
        _ = generation
        if let box = images.object(forKey: index as NSNumber) { return box.image }
        requestImage(index)
        return nil
    }

    /// サムネイル (長辺 240px)。
    func thumbnail(_ index: Int) -> CGImage? {
        _ = generation
        if let box = thumbnails.object(forKey: index as NSNumber) { return box.image }
        requestThumbnail(index)
        return nil
    }

    func size(_ index: Int) -> CGSize? {
        _ = generation
        return sizes[index]
    }

    /// 横長 (見開きをスキャンした 1 枚など) のページか。寸法が未知なら縦長とみなす。
    func isWide(_ index: Int) -> Bool {
        guard let s = size(index) else { return false }
        return s.width > s.height
    }

    /// 幅 / 高さ。未知なら一般的なコミックの比率。
    func aspectRatio(_ index: Int) -> CGFloat {
        if let s = size(index), s.height > 0, s.width > 0 { return s.width / s.height }
        return 0.7
    }

    func preload(_ indices: [Int]) {
        for i in indices where images.object(forKey: i as NSNumber) == nil {
            requestImage(i)
        }
    }

    // MARK: - 読み込み

    private func requestImage(_ index: Int) {
        guard !cancelled, index >= 0, index < comic.pageCount, !loadingImages.contains(index) else { return }
        loadingImages.insert(index)
        let page = comic.pages[index]
        Task.detached(priority: .userInitiated) {
            let img = Self.decode(page, maxPixel: Self.displayMaxPixel)
            await MainActor.run { self.finishImage(index, img) }
        }
    }

    private func finishImage(_ index: Int, _ img: CGImage?) {
        loadingImages.remove(index)
        if let img {
            images.setObject(CGImageBox(img), forKey: index as NSNumber, cost: img.bytesPerRow * img.height)
            // 縮小済みでも縦横比は同じなので、未知ならこれを寸法として使う
            if sizes[index] == nil { sizes[index] = CGSize(width: img.width, height: img.height) }
        }
        generation += 1
    }

    private func requestThumbnail(_ index: Int) {
        guard !cancelled, index >= 0, index < comic.pageCount, !loadingThumbnails.contains(index) else { return }
        loadingThumbnails.insert(index)
        let page = comic.pages[index]
        Task.detached(priority: .utility) {
            let img = Self.decode(page, maxPixel: Self.thumbnailMaxPixel)
            await MainActor.run { self.finishThumbnail(index, img) }
        }
    }

    private func finishThumbnail(_ index: Int, _ img: CGImage?) {
        loadingThumbnails.remove(index)
        if let img {
            thumbnails.setObject(CGImageBox(img), forKey: index as NSNumber)
            if sizes[index] == nil { sizes[index] = CGSize(width: img.width, height: img.height) }
        }
        generation += 1
    }

    /// ImageIO で長辺 maxPixel 以下に縮小しながらデコードする (EXIF の回転も反映する)。元が小さければ拡大はしない。
    nonisolated static func decode(_ page: ComicPage, maxPixel: Int) -> CGImage? {
        guard let data = try? page.getData(), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// ヘッダーだけ読んでピクセル寸法を求める (フルデコードはしない)。
    nonisolated static func pixelSize(_ page: ComicPage) -> CGSize? {
        guard let data = try? page.getData(), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // EXIF の回転 (5〜8 は 90°/270°) は幅と高さが入れ替わる
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }

    /// 見開きの組み方 (横長ページの判定) に全ページの寸法が要るので、低優先度で順に調べる。
    private func startSizeScan() {
        let pages = comic.pages
        let unknown = (0..<pages.count).filter { sizes[$0] == nil }
        guard !unknown.isEmpty else { return }
        scanTask = Task.detached(priority: .utility) {
            var batch: [(Int, CGSize)] = []
            for (n, i) in unknown.enumerated() {
                if Task.isCancelled { return }
                if let s = Self.pixelSize(pages[i]) { batch.append((i, s)) }
                if batch.count >= 8 || n == unknown.count - 1 {
                    let b = batch
                    batch = []
                    await MainActor.run { self.mergeSizes(b) }
                }
            }
        }
    }

    private func mergeSizes(_ batch: [(Int, CGSize)]) {
        var changed = false
        for (i, s) in batch where sizes[i] == nil {
            sizes[i] = s
            changed = true
        }
        if changed { generation += 1 }
    }
}
