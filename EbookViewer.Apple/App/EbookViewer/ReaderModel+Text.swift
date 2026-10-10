import Foundation
import CoreGraphics
import ImageIO
import EbookCore

/// 本文と、そこに差し込む画像。
struct BookText {
    var content: ExtractedText
    /// 本文中の位置 → 画像。読めなかった画像は入らない。
    var images: [Int: CGImage] = [:]
}

/// stone_engine (STLabel) で本文を表示する経路。
/// WebView 経路と違って本文ドキュメントは HTML としてではなくプレーンテキストとして渡すので、
/// ここで XHTML からテキストとアンカー (目次のリンク先) の位置、画像を取り出す。
extension ReaderModel {
    /// spine の index 番目の章を STLabel に表示する。
    func showSpineAsText(_ index: Int, initial: InitialPosition) {
        guard let book, index >= 0, index < book.spine.count else { return }
        showText(path: book.spine[index].path, initial: initial, spine: index)
    }

    /// 本文ドキュメント 1 件を STLabel に表示する。
    /// - Parameter spine: 表示し終えたときに章が変わっていないかを確かめるための spine 番号 (spine 外のファイルなら nil)。
    func showText(path: String, initial: InitialPosition, spine: Int? = nil) {
        guard let book, let text else { return }
        textLoadTask?.cancel()
        // 取り出しは本文の長さに比例して時間がかかるので、メインスレッドから外す
        textLoadTask = Task { [weak self] in
            let loaded = await Self.loadText(book: book, path: path)
            guard !Task.isCancelled, let self else { return }
            // 待っている間にページを送られていたら捨てる
            if let spine, self.spineIndex != spine { return }
            guard self.usesStoneEngine else { return }
            if loaded.content.text.isEmpty {
                AppDirectories.trace("stone: no text in \(path)")
            }
            text.show(loaded, initial: initial)
            text.focus()
        }
    }

    private static func loadText(book: BookDocument, path: String) async -> BookText {
        let content = await extractText(book: book, path: path)
        guard !content.images.isEmpty else { return BookText(content: content) }
        let images = await Task.detached(priority: .userInitiated) {
            var images: [Int: CGImage] = [:]
            for annotation in content.images {
                // パスは本文ドキュメントからの相対
                let resolved = PathUtil.resolve(basePath: path, href: annotation.source)
                guard let resource = book.findResource(resolved), let data = try? resource.getData() else {
                    AppDirectories.trace("stone: image not found \(annotation.source) (\(resolved))")
                    continue
                }
                guard let image = decodeImage(data) else {
                    AppDirectories.trace("stone: image could not be decoded \(resolved)")
                    continue
                }
                images[annotation.offset] = image
            }
            return images
        }.value
        return BookText(content: content, images: images)
    }

    /// 画面に出す以上には大きくしないでデコードする (1 ページぶんの挿絵でも 2048px あれば足りる)。
    private nonisolated static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func extractText(book: BookDocument, path: String) async -> ExtractedText {
        await Task.detached(priority: .userInitiated) {
            guard let resource = book.findResource(path) else {
                AppDirectories.trace("stone: resource not found \(path)")
                return ExtractedText(text: "", anchors: [:])
            }
            do {
                let data = try resource.getData()
                return PlainTextExtractor.extract(data, mediaType: resource.mediaType)
            } catch {
                AppDirectories.logError("stone: read \(path): \(error)")
                return ExtractedText(text: "", anchors: [:])
            }
        }.value
    }
}
