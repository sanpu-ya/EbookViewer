import Foundation
import EbookCore

/// コミック (CBZ / 画像フォルダー / PDF) の表示状態と操作。
extension ReaderModel {
    var isComic: Bool { comic != nil }
    var hasContent: Bool { book != nil || comic != nil }

    /// 読み方向・配置・拡大方法の選択肢 (値, 表示名)。
    static var comicDirections: [(key: String, label: String)] {
        [("auto", String(localized: "Auto (ComicInfo)")), ("rtl", String(localized: "Right to Left (Manga)")), ("ltr", String(localized: "Left to Right"))]
    }
    static var comicLayouts: [(key: String, label: String)] {
        [("auto", String(localized: "Auto")), ("single", String(localized: "Single Page")),
         ("double", String(localized: "Two Pages")), ("webtoon", String(localized: "Vertical Scroll (Webtoon)"))]
    }
    static var comicFits: [(key: String, label: String)] {
        [("page", String(localized: "Fit Page")), ("width", String(localized: "Fit Width")), ("height", String(localized: "Fit Height"))]
    }
    static var comicBackgrounds: [(key: String, label: String)] {
        [("black", String(localized: "Black")), ("white", String(localized: "White")), ("theme", String(localized: "Theme Color"))]
    }

    /// PDF、または ComicLoader が扱える書庫・フォルダーか。
    nonisolated static func isComicURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf" || ComicLoader.isSupported(url)
    }

    /// 本 (EPUB / MOBI) かコミックとして開けるか。ドロップや「このアプリで開く」の判定に使う (バックグラウンドからも呼べる)。
    nonisolated static func canOpen(_ url: URL) -> Bool {
        BookLoader.isSupported(url) || isComicURL(url)
    }

    // MARK: - 開く / 閉じる

    func openComic(_ url: URL) async {
        loading = true
        showLoading(String(localized: "Loading… \(url.lastPathComponent)"))
        let scoped = url.startAccessingSecurityScopedResource()
        var keepScope = false
        defer { if scoped && !keepScope { url.stopAccessingSecurityScopedResource() } }
        AppDirectories.trace("open comic \(url.path) scoped=\(scoped)")
        do {
            savePosition()
            let keepAccess = ComicLoader.needsPersistentAccess(url)
            let loaded: ComicDocument = try await Task.detached(priority: .userInitiated) {
                if url.pathExtension.lowercased() == "pdf" { return try PdfComicLoader.load(url: url) }
                return try ComicLoader.load(url: url)
            }.value
            closeComic()
            closeBook()
            comic = loaded
            bookURL = url
            comicImages = ComicImageStore(comic: loaded)
            // フォルダーと RAR はページを後から読むので、表示している間はスコープ付きアクセスを維持する
            if keepAccess && scoped {
                keepScope = true
                comicScopedURL = url
            }
            settings.addRecent(url)
            settings.save()
            windowTitle = loaded.title + " - EbookViewer"
            comicZoom = 1
            comicPage = 0
            loading = false
            hideLoading()
            let pos = positions.get(url.path)
            comicPairAnchor = pos?.comicAnchor.flatMap { $0 > 0 && $0 < loaded.pageCount ? $0 : nil }
            setComicPage(pos?.spineIndex ?? 0)
        } catch {
            loading = false
            hideLoading()
            AppDirectories.logError("open comic \(url.path): \(error)")
            if let be = error as? BookError, be.isUnsupported {
                errorMessage = be.localizedDescription
            } else {
                errorMessage = String(localized: "The file could not be opened.") + "\n\n" + error.localizedDescription
            }
        }
    }

    /// コミックの表示を閉じる。本に切り替えるときや別のコミックを開くときに使う。
    func closeComic() {
        comicImages?.cancel()
        comicImages = nil
        comic = nil
        if let u = comicScopedURL {
            u.stopAccessingSecurityScopedResource()
            comicScopedURL = nil
        }
    }

    // MARK: - 見開きの組み立て

    /// 読み方向。"auto" では ComicInfo の Manga に従い、宣言が無ければ右開き (日本のマンガ向けの既定)。
    var comicReadsRightToLeft: Bool {
        switch settings.comicDirection {
        case "ltr": return false
        case "rtl": return true
        default: return comic?.readingDirection != .leftToRight
        }
    }

    /// 設定が "auto" のときは表示領域が横長なら見開きにする。
    var effectiveComicLayout: String {
        switch settings.comicLayout {
        case "single", "double", "webtoon": return settings.comicLayout
        default: return comicViewport.width > comicViewport.height * 1.15 ? "double" : "single"
        }
    }

    var comicIsWebtoon: Bool { effectiveComicLayout == "webtoon" }

    /// 見開きにせず単独で表示するページか。
    /// ComicInfo で DoublePage とされたページ、横長の画像、(設定により) 先頭ページと ComicInfo の表紙 (FrontCover / BackCover)。
    func comicPageStandsAlone(_ i: Int) -> Bool {
        guard let comic, i >= 0, i < comic.pageCount else { return true }
        let page = comic.pages[i]
        if page.isDoublePage { return true }
        if settings.comicCoverAlone && (i == 0 || page.isCover) { return true }
        return comicImages?.isWide(i) ?? false
    }

    /// ページ i から始まる見開き (読み順)。組み始めページ (comicPairAnchor) をまたぐ組み合わせは作らない。
    func comicSpread(startingAt i: Int) -> [Int] {
        guard let comic else { return [i] }
        guard effectiveComicLayout == "double", i + 1 < comic.pageCount else { return [i] }
        if let anchor = comicPairAnchor, i < anchor, i + 1 >= anchor { return [i] }
        if comicPageStandsAlone(i) || comicPageStandsAlone(i + 1) { return [i] }
        return [i, i + 1]
    }

    /// 見開きの組み合わせを 1 ページ分ずらす (forward なら次のページから組み直す)。
    /// 例: [2,3] を表示中に進むと [3,4]、戻ると [1,2] になる。単ページ・縦スクロールでは通常のページ送り。
    func comicShiftOnePage(forward: Bool) {
        guard let comic else { return }
        guard effectiveComicLayout == "double" else {
            forward ? comicNext() : comicPrev()
            return
        }
        let start = currentComicSpread.first ?? comicPage
        let target = forward ? start + 1 : start - 1
        guard target >= 0, target < comic.pageCount else {
            statusRight = forward ? String(localized: "This is the last page") : String(localized: "This is the first page")
            return
        }
        comicPairAnchor = target
        setComicPage(target)
    }

    /// ページ p を含む見開き。先頭から組んでいくので、横長ページの後ろで組み合わせがずれても追従する。
    func comicSpread(containing p: Int) -> [Int] {
        guard let comic else { return [p] }
        var i = 0
        while i < comic.pageCount {
            let s = comicSpread(startingAt: i)
            if s.contains(p) { return s }
            i += s.count
        }
        return [p]
    }

    var currentComicSpread: [Int] { comicSpread(containing: comicPage) }

    /// 現在の見開きを画面上の並び (左→右) にしたもの。右開きなら後のページが左に来る。
    var currentComicSpreadDisplayOrder: [Int] {
        let s = currentComicSpread
        return comicReadsRightToLeft ? s.reversed() : s
    }

    // MARK: - ナビゲーション

    /// ページを移動する。見開きの途中を指定されたら見開きの先頭に揃える (縦スクロール中は指定のまま)。
    func setComicPage(_ index: Int, fromScroll: Bool = false) {
        guard let comic, comic.pageCount > 0 else { return }
        let clamped = min(max(0, index), comic.pageCount - 1)
        comicPage = fromScroll ? clamped : (comicSpread(containing: clamped).first ?? clamped)
        updateStatus()
        scheduleSave()
        preloadComicPages()
    }

    func goToComicPage(_ index: Int) { setComicPage(index) }

    func comicNext() {
        guard let comic else { return }
        let next = (currentComicSpread.last ?? comicPage) + 1
        if next < comic.pageCount {
            setComicPage(next)
        } else {
            statusRight = String(localized: "This is the last page")
        }
    }

    func comicPrev() {
        guard comic != nil else { return }
        let prev = (currentComicSpread.first ?? comicPage) - 1
        if prev >= 0 {
            setComicPage(prev)
        } else {
            statusRight = String(localized: "This is the first page")
        }
    }

    func comicFirstPage() { setComicPage(0) }
    func comicLastPage() { if let comic { setComicPage(comic.pageCount - 1) } }

    /// 現在の見開きと前後数ページを先に読んでおく。
    private func preloadComicPages() {
        guard let comic, let store = comicImages else { return }
        let s = currentComicSpread
        let first = s.first ?? comicPage
        let last = s.last ?? comicPage
        var order = s
        if last + 1 < comic.pageCount { order += Array((last + 1)...min(comic.pageCount - 1, last + 4)) }
        if first > 0 { order += Array(max(0, first - 2)..<first).reversed() }
        store.preload(order)
    }

    // MARK: - 表示設定

    func setComicDirection(_ direction: String) {
        guard direction != settings.comicDirection else { return }
        settings.comicDirection = direction
        settings.save()
        updateStatus()
    }

    func toggleComicDirection() {
        setComicDirection(comicReadsRightToLeft ? "ltr" : "rtl")
    }

    func setComicLayout(_ layout: String) {
        guard layout != settings.comicLayout else { return }
        settings.comicLayout = layout
        settings.save()
        comicZoom = 1
        setComicPage(comicPage)
    }

    func setComicFit(_ fit: String) {
        guard fit != settings.comicFit else { return }
        settings.comicFit = fit
        settings.save()
        comicZoom = 1
    }

    func setComicCoverAlone(_ on: Bool) {
        guard on != settings.comicCoverAlone else { return }
        settings.comicCoverAlone = on
        settings.save()
        setComicPage(comicPage)
    }

    func setComicInvert(_ on: Bool) { settings.comicInvert = on; settings.save() }
    func setComicGrayscale(_ on: Bool) { settings.comicGrayscale = on; settings.save() }
    func setComicBackground(_ key: String) { settings.comicBackground = key; settings.save() }

    func comicZoomIn() { comicZoom = min(5, comicZoom * 1.25) }
    func comicZoomOut() { comicZoom = max(1, comicZoom / 1.25) }
    func comicZoomReset() { comicZoom = 1 }

    var comicBackgroundColorHex: String {
        switch settings.comicBackground {
        case "white": return "#ffffff"
        case "theme": return settings.themeColors.background
        default: return "#000000"
        }
    }

    // MARK: - 状態表示・保存

    func updateComicStatus() {
        guard let comic else { return }
        let format: String
        switch comic.format {
        case .cbz: format = "CBZ"
        case .cbr: format = "CBR"
        case .folder: format = String(localized: "Folder")
        case .pdf: format = "PDF"
        }
        let direction = comicReadsRightToLeft ? String(localized: "Right to Left") : String(localized: "Left to Right")
        statusLeft = "\(comic.title)   [\(format)]  \(direction)"
        let s = currentComicSpread
        if s.count > 1, let a = s.first, let b = s.last {
            statusRight = String(localized: "Pages \(a + 1)–\(b + 1)/\(comic.pageCount)")
        } else {
            statusRight = String(localized: "Page \(comicPage + 1)/\(comic.pageCount)")
        }
    }

    func saveComicPosition() {
        guard comic != nil, let bookURL else { return }
        positions.set(bookURL.path, spineIndex: comicPage, fraction: 0, comicAnchor: comicPairAnchor)
        positions.save()
    }
}
