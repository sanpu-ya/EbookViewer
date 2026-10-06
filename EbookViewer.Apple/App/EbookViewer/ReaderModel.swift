import Foundation
import Observation
import EbookCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 目次リストの 1 行。
struct TocItem: Identifiable {
    let id: Int
    let entry: TocEntry
    let title: String
    let depth: Int

    init(id: Int, entry: TocEntry, depth: Int) {
        self.id = id
        self.entry = entry
        self.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "(Untitled)") : entry.title
        self.depth = depth
    }
}

/// WebView 側の操作 (WKWebView のラッパーが実装する)。
@MainActor
protocol WebBridge: AnyObject {
    var currentURL: URL? { get }
    func navigate(to url: URL)
    func reload()
    func evaluate(_ js: String)
    func focus()
}

/// 画面の状態と操作 (開いている本、現在の章・ページ、設定の反映、WebView との連携)。
@MainActor
@Observable
final class ReaderModel: BookContentProvider {
    var settings: ReaderSettings
    let positions: ReadingPositionStore

    private(set) var book: BookDocument?
    var bookURL: URL?
    private(set) var spineIndex = -1
    private(set) var page = 0
    private(set) var pages = 1
    private(set) var tocItems: [TocItem] = []
    var selectedTocId: Int?

    // コミック (操作は ReaderModel+Comic.swift)
    var comic: ComicDocument?
    var comicImages: ComicImageStore?
    var comicPage = 0
    /// 見開きの組み始めページ。「1 ページ進む / 戻る」で設定され、このページから (anchor, anchor+1) と組む。nil なら先頭から。
    var comicPairAnchor: Int?
    /// 表示倍率 (1 = フィット)。保存しない。
    var comicZoom: Double = 1
    /// コミック表示領域の大きさ (見開きの自動判定に使う)。ビューが更新する。
    var comicViewport: CGSize = .zero
    /// フォルダーを開いているとき、ページを後から読めるよう維持しているスコープ付きアクセスの URL。
    @ObservationIgnored var comicScopedURL: URL?

    var isLoading = false
    var loadingText = String(localized: "Loading…")
    var errorMessage: String?
    var statusLeft = String(localized: "No book open")
    var statusRight = ""
    var windowTitle = "EbookViewer"
    var tocOpen: Bool

    @ObservationIgnored weak var web: WebBridge?
    @ObservationIgnored private var pendingInitial = "{\"type\":\"page\",\"page\":0}"
    @ObservationIgnored private var pendingOpen: URL?
    @ObservationIgnored var loading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var readyFallbackTask: Task<Void, Never>?

    init() {
        let s = ReaderSettings.load()
        settings = s
        positions = ReadingPositionStore.load()
        tocOpen = s.tocOpen
    }

    func setTocOpen(_ open: Bool) {
        tocOpen = open
        settings.tocOpen = open
        settings.save()
        if !open { web?.focus() }
    }

    // MARK: - BookContentProvider

    var currentBook: BookDocument? { book }

    func makeViewerOptions() -> ViewerOptions {
        var o = ViewerOptions()
        o.vertical = isVerticalEffective
        o.fontSizePx = settings.fontSizePx
        o.fontFamily = settings.fontFamilyCss
        o.lineHeight = settings.lineHeight
        o.paddingPx = settings.paddingPx
        o.background = settings.themeColors.background
        o.foreground = settings.themeColors.foreground
        o.initialPositionJson = pendingInitial
        return o
    }

    // MARK: - ファイルを開く

    /// WebView の準備ができていなければ準備後に開く。
    func requestOpen(_ url: URL) {
        if web != nil { Task { await openFile(url) } } else { pendingOpen = url }
    }

    /// WebView が用意できたときに呼ぶ。
    func webDidAttach() {
        if let u = pendingOpen {
            pendingOpen = nil
            Task { await openFile(u) }
        } else if book != nil {
            // レイアウト切替 (iPad の Split View など) で WebView が作り直されたら現在位置を再表示する
            reloadCurrent()
        }
    }

    func openRecent(_ recent: RecentFile) {
        Task { await openFile(recent.resolveURL()) }
    }

    func openFile(_ url: URL) async {
        if loading { return }
        if Self.isComicURL(url) {
            await openComic(url)
            return
        }
        guard web != nil else { pendingOpen = url; return }
        loading = true
        showLoading(String(localized: "Loading… \(url.lastPathComponent)"))
        // サンドボックス外のファイル (ピッカー・ドロップ・ブックマーク) はスコープ付きアクセスが必要
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        AppDirectories.trace("open \(url.path) scoped=\(scoped) readable=\(FileManager.default.isReadableFile(atPath: url.path))")
        do {
            savePosition()
            let loaded = try await BookLoader.load(url: url)
            closeComic()
            book = loaded
            bookURL = url
            settings.addRecent(url)
            settings.save()

            let title = loaded.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty ? url.lastPathComponent : loaded.metadata.title
            windowTitle = title + " - EbookViewer"
            buildTocList(loaded)

            let pos = positions.get(url.path)
            let spine = (pos != nil && pos!.spineIndex >= 0 && pos!.spineIndex < loaded.spine.count) ? pos!.spineIndex : Self.firstLinearSpine(loaded)
            let initial = pos != nil ? "{\"type\":\"fraction\",\"value\":\(pos!.fraction)}" : "{\"type\":\"page\",\"page\":0}"
            loading = false
            goToSpine(spine, initial: initial)
        } catch {
            loading = false
            hideLoading()
            AppDirectories.logError("open \(url.path): \(error)")
            if let be = error as? BookError, be.isUnsupported {
                errorMessage = be.localizedDescription
            } else {
                errorMessage = String(localized: "The file could not be opened.") + "\n\n" + error.localizedDescription
            }
        }
    }

    private static func firstLinearSpine(_ book: BookDocument) -> Int {
        book.spine.firstIndex { $0.linear } ?? 0
    }

    /// 本文 (WebView) の表示を閉じる。コミックに切り替えるときに使う。
    func closeBook() {
        guard book != nil else { return }
        readyFallbackTask?.cancel()
        book = nil
        spineIndex = -1
        page = 0
        pages = 1
        tocItems = []
        selectedTocId = nil
        if let blank = URL(string: "about:blank") { web?.navigate(to: blank) }
    }

    var bookTitle: String {
        if let comic { return comic.title }
        guard let book, let bookURL else { return String(localized: "Table of Contents") }
        let t = book.metadata.title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? bookURL.lastPathComponent : t
    }

    var bookAuthor: String {
        if let comic { return comic.creators }
        return book?.metadata.author ?? ""
    }

    // MARK: - ナビゲーション

    private func goToSpine(_ index: Int, initial: String, wrapMessage: String? = nil) {
        guard let book, let web else { return }
        if index < 0 || index >= book.spine.count {
            if let wrapMessage { statusRight = wrapMessage }
            return
        }
        spineIndex = index
        pendingInitial = initial
        page = 0
        pages = 1
        showLoading(String(localized: "Rendering…"))
        updateStatus()
        let url = BookScheme.url(forPath: book.spine[index].path)
        AppDirectories.trace("navigate spine=\(index) url=\(url.absoluteString) initial=\(initial)")
        // ready が来ないままでも表示中のオーバーレイが残り続けないよう保険をかける
        startReadyFallback(seconds: 10)
        if web.currentURL == url {
            web.reload()
        } else {
            web.navigate(to: url)
        }
    }

    private func startReadyFallback(seconds: Double) {
        readyFallbackTask?.cancel()
        readyFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.isLoading else { return }
            AppDirectories.trace("ready fallback fired (no ready message within \(seconds)s)")
            self.hideLoading()
            self.statusRight = String(localized: "The page did not report ready (see trace.log)")
        }
    }

    func reloadCurrent() {
        guard book != nil, spineIndex >= 0 else { return }
        let fraction = pages > 1 ? Double(page) / Double(pages - 1) : 0
        goToSpine(spineIndex, initial: "{\"type\":\"fraction\",\"value\":\(fraction)}")
    }

    func nextPage() {
        if comic != nil { comicNext() } else { web?.evaluate("window.__ev && window.__ev.next()") }
    }

    func prevPage() {
        if comic != nil { comicPrev() } else { web?.evaluate("window.__ev && window.__ev.prev()") }
    }

    /// 本文中のリンク (ebook:// または外部 URL)。
    func followLink(_ href: String) {
        guard book != nil, let url = URL(string: href) else { return }
        guard url.scheme == BookScheme.scheme, url.host?.lowercased() == BookScheme.host else {
            if url.scheme == "http" || url.scheme == "https" { Self.openExternal(url) }
            return
        }
        let path = PathUtil.normalize(url.path)
        let fragment = url.fragment.flatMap { $0.removingPercentEncoding ?? $0 }
        navigate(toPath: path, fragment: fragment.flatMap { $0.isEmpty ? nil : $0 })
    }

    func navigate(toPath path: String?, fragment: String?) {
        guard let book, let web else { return }
        let index = path == nil ? spineIndex : book.findSpineIndex(path!)
        if index < 0 {
            // spine に無いドキュメント (脚注ファイルなど) でも本文リソースなら表示する
            guard let path, let res = book.findResource(path), PathUtil.isHtmlMediaType(res.mediaType) else { return }
            pendingInitial = Self.initialJson(fragment: fragment)
            web.navigate(to: BookScheme.url(forPath: res.path))
            return
        }
        if index == spineIndex, let fragment {
            web.evaluate("window.__ev && window.__ev.gotoAnchor(\(Self.jsonString(fragment)))")
            web.focus()
            return
        }
        goToSpine(index, initial: Self.initialJson(fragment: fragment))
    }

    private static func initialJson(fragment: String?) -> String {
        guard let fragment else { return "{\"type\":\"page\",\"page\":0}" }
        return "{\"type\":\"anchor\",\"id\":\(jsonString(fragment))}"
    }

    static func jsonString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let arr = d.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    static func openExternal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func selectToc(_ item: TocItem) {
        guard let path = item.entry.path else { return }
        navigate(toPath: path, fragment: item.entry.fragment)
        web?.focus()
    }

    // MARK: - WebView からのメッセージ

    func handleWebMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        if type != "page" { AppDirectories.trace("message \(dict)") }
        switch type {
        case "ready":
            page = dict["page"] as? Int ?? 0
            pages = max(1, dict["pages"] as? Int ?? 1)
            crashReloads = 0
            readyFallbackTask?.cancel()
            hideLoading()
            updateStatus()
            scheduleSave()
        case "page":
            page = dict["page"] as? Int ?? 0
            pages = max(1, dict["pages"] as? Int ?? 1)
            updateStatus()
            scheduleSave()
        case "next-chapter":
            goToSpine(spineIndex + 1, initial: "{\"type\":\"page\",\"page\":0}", wrapMessage: String(localized: "This is the last page"))
        case "prev-chapter":
            goToSpine(spineIndex - 1, initial: "{\"type\":\"end\"}", wrapMessage: String(localized: "This is the first page"))
        case "link":
            if let href = dict["href"] as? String { followLink(href) }
        case "key":
            handleWebKey(dict["key"] as? String ?? "", ctrl: dict["ctrl"] as? Bool ?? false)
        case "error":
            statusRight = String(localized: "Script error: \(dict["message"] as? String ?? "")")
        case "tap-center":
            #if !os(macOS)
            tapCenter?()
            #endif
        default:
            break
        }
    }

    /// iOS で画面中央をタップしたときにツールバーを出し入れするためのフック。
    @ObservationIgnored var tapCenter: (() -> Void)?

    private func handleWebKey(_ key: String, ctrl: Bool) {
        if ctrl {
            switch key {
            case "t", "T": setTocOpen(!tocOpen)
            case "o", "O": openRequested?()
            case "+", "=", ";": fontUp()
            case "-": fontDown()
            default: break
            }
            return
        }
        switch key {
        case "Escape": if tocOpen { setTocOpen(false) }
        case "t", "T": setTocOpen(!tocOpen)
        default: break
        }
    }

    /// 「開く」ダイアログを出すためのフック (ビュー側が設定する)。
    @ObservationIgnored var openRequested: (() -> Void)?

    // MARK: - WebView のナビゲーション状態

    func webNavigationStarted(_ url: URL?) {
        AppDirectories.trace("navigation starting \(url?.absoluteString ?? "-")")
    }

    func webNavigationFinished() {
        AppDirectories.trace("navigation finished spine=\(spineIndex)")
        // 本を閉じた後の about:blank では何もしない (コミック表示からフォーカスを奪わない)
        guard book != nil else { return }
        startReadyFallback(seconds: 4)
        web?.focus()
    }

    func webNavigationFailed(_ error: Error) {
        let ns = error as NSError
        AppDirectories.trace("navigation failed domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription) \(ns.userInfo)")
        // 連続ページ送りで前のナビゲーションが中断されたときは次のナビゲーションが続いているので無視する
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return } // frame load interrupted
        hideLoading()
        statusRight = String(localized: "Display error: \(error.localizedDescription)")
    }

    /// WebKit のコンテンツプロセスが落ちたときは本文を出し直す。
    /// 起動直後に毎回落ちる場合 (サンドボックス設定不足など) は無限ループになるので、回数を制限する。
    @ObservationIgnored private var crashReloads = 0
    private static let maxCrashReloads = 2

    func webContentProcessTerminated() {
        crashReloads += 1
        AppDirectories.trace("web content process terminated (attempt \(crashReloads))")
        readyFallbackTask?.cancel()
        hideLoading()
        guard crashReloads <= Self.maxCrashReloads else {
            statusRight = String(localized: "The rendering process kept terminating; gave up reloading")
            errorMessage = String(localized: "The WebKit process that renders the book kept terminating.\nOn macOS the App Sandbox needs the com.apple.security.network.client entitlement (Outgoing Connections). Check Signing & Capabilities in Xcode.")
            return
        }
        statusRight = String(localized: "The rendering process terminated. Reloading…")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.reloadCurrent()
        }
    }

    /// WebView へのファイルドロップや file:// への遷移は本として開く。
    func handleExternalNavigation(_ url: URL) {
        if url.isFileURL {
            if Self.canOpen(url) { Task { await openFile(url) } }
        } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            Self.openExternal(url)
        }
    }

    // MARK: - 表示設定

    var isVerticalEffective: Bool {
        switch settings.writingMode {
        case "vertical": return true
        case "horizontal": return false
        default: break
        }
        guard let book else { return true }
        if book.declaredWritingMode == .vertical { return true }
        if book.declaredWritingMode == .horizontal { return false }
        // 宣言が無ければ日本語の本は縦書きにする
        let lang = book.metadata.language
        if lang.lowercased().hasPrefix("ja") { return true }
        if lang.isEmpty { return Self.containsJapanese(book.metadata.title) || Self.containsJapanese(book.metadata.author) }
        return false
    }

    /// ひらがな・カタカナ・半角カタカナ・CJK 統合漢字 (拡張 A〜H を含む BMP 外も) のいずれかを含むか。
    /// unicodeScalars 単位で見るので、サロゲートペアで表される拡張 B 以降の漢字 (𠮟 など) も 1 文字として判定できる。
    private static func containsJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            switch u.value {
            case 0x3040...0x30FF,   // ひらがな・カタカナ
                 0xFF66...0xFF9F,   // 半角カタカナ
                 0x3400...0x4DBF,   // CJK 拡張 A
                 0x4E00...0x9FFF,   // CJK 統合漢字
                 0xF900...0xFAFF,   // CJK 互換漢字
                 0x20000...0x3134F: // CJK 拡張 B〜G (BMP 外)
                return true
            default:
                return false
            }
        }
    }

    var writingModeLabel: String {
        switch settings.writingMode {
        case "vertical": return String(localized: "Vertical")
        case "horizontal": return String(localized: "Horizontal")
        default: return String(localized: "Auto")
        }
    }

    /// 組方向の選択肢 (値, 表示名)。
    static var writingModes: [(key: String, label: String)] {
        [("auto", String(localized: "Auto")), ("vertical", String(localized: "Vertical")), ("horizontal", String(localized: "Horizontal"))]
    }

    /// 組方向を直接指定する ("auto" / "vertical" / "horizontal")。
    func setWritingMode(_ mode: String) {
        guard Self.writingModes.contains(where: { $0.key == mode }), mode != settings.writingMode else { return }
        settings.writingMode = mode
        settings.save()
        reloadCurrent()
    }

    func cycleWritingMode() {
        switch settings.writingMode {
        case "auto": setWritingMode("vertical")
        case "vertical": setWritingMode("horizontal")
        default: setWritingMode("auto")
        }
    }

    /// ⌘+ / ⌘-。コミックでは拡大率を変える。
    func fontUp() {
        if comic != nil { comicZoomIn(); return }
        settings.fontSizePx = min(48, settings.fontSizePx + 2)
        settings.save()
        reloadCurrent()
    }

    func fontDown() {
        if comic != nil { comicZoomOut(); return }
        settings.fontSizePx = max(10, settings.fontSizePx - 2)
        settings.save()
        reloadCurrent()
    }

    func setTheme(_ theme: String) { settings.theme = theme; settings.save(); reloadCurrent() }
    func setFont(_ key: String) { settings.fontKey = key; settings.save(); reloadCurrent() }
    func setLineHeight(_ lh: Double) { settings.lineHeight = lh; settings.save(); reloadCurrent() }
    func setPadding(_ pad: Int) { settings.paddingPx = pad; settings.save(); reloadCurrent() }

    /// 存在するファイルだけの履歴。
    var existingRecentFiles: [RecentFile] {
        settings.recentFiles.filter { $0.bookmark != nil || FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 目次

    private func buildTocList(_ book: BookDocument) {
        var items: [TocItem] = []
        func add(_ entries: [TocEntry], depth: Int) {
            for e in entries {
                items.append(TocItem(id: items.count, entry: e, depth: depth))
                add(e.children, depth: depth + 1)
            }
        }
        add(book.toc, depth: 0)
        if items.isEmpty {
            // 目次が無い本は spine の各ファイルを並べる
            for (i, s) in book.spine.enumerated() {
                items.append(TocItem(id: i, entry: TocEntry(title: "\(i + 1). " + PathUtil.getFileName(s.path), path: s.path, fragment: nil), depth: 0))
            }
        }
        tocItems = items
        selectedTocId = nil
    }

    // MARK: - 表示更新・保存

    func updateStatus() {
        if comic != nil {
            updateComicStatus()
            return
        }
        guard let book else {
            statusLeft = String(localized: "No book open")
            statusRight = ""
            return
        }
        let author = book.metadata.author.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "  ―  " + book.metadata.author
        let format: String
        switch book.format {
        case .epub: format = "EPUB"
        case .kf8: format = "KF8"
        case .mobi7: format = "MOBI"
        }
        statusLeft = "\(bookTitle)\(author)   [\(format)]  \(isVerticalEffective ? String(localized: "Vertical") : String(localized: "Horizontal"))"
        let chapter = book.spine.count > 1 ? String(localized: "Chapter \(spineIndex + 1)/\(book.spine.count)") + "   " : ""
        statusRight = chapter + String(localized: "Page \(page + 1)/\(pages)")
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.savePosition()
        }
    }

    func savePosition() {
        if comic != nil {
            saveComicPosition()
            return
        }
        guard book != nil, let bookURL, spineIndex >= 0 else { return }
        let fraction = pages > 1 ? Double(page) / Double(pages - 1) : 0
        positions.set(bookURL.path, spineIndex: spineIndex, fraction: fraction)
        positions.save()
    }

    /// 終了・バックグラウンド移行時。
    func persistAll() {
        savePosition()
        positions.save()
        settings.save()
    }

    func showLoading(_ text: String) {
        loadingText = text
        isLoading = true
    }

    func hideLoading() {
        isLoading = false
    }
}
