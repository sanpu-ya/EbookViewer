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

/// STLabel 側の操作 (BookTextView のコーディネーターが実装する)。
@MainActor
protocol TextBridge: AnyObject {
    /// 本文を差し替え、初期位置のページを表示する。
    func show(_ text: BookText, initial: InitialPosition)
    /// 本文を消す (読書位置は通知しない)。
    func clear()
    func next()
    func prev()
    func goTo(page: Int)
    /// 章内のアンカー (`#fragment`) の位置へ移動する。
    func goTo(anchor: String)
    func focus()
}

/// 章を開いたときの初期表示位置。
enum InitialPosition: Equatable {
    case page(Int)
    case end
    case anchor(String)
    /// 章全体に対する位置 (0...1)。読書位置の復元に使う。
    case fraction(Double)

    /// viewer.js に渡す JSON。
    var json: String {
        switch self {
        case .page(let p): return "{\"type\":\"page\",\"page\":\(p)}"
        case .end: return "{\"type\":\"end\"}"
        case .anchor(let id): return "{\"type\":\"anchor\",\"id\":\(ReaderModel.jsonString(id))}"
        case .fraction(let v): return "{\"type\":\"fraction\",\"value\":\(v)}"
        }
    }
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
    @ObservationIgnored weak var text: TextBridge?
    @ObservationIgnored private var pendingInitial = InitialPosition.page(0)
    @ObservationIgnored private var pendingOpen: URL?
    @ObservationIgnored var loading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var readyFallbackTask: Task<Void, Never>?
    /// 本文テキストの取り出し (STLabel 表示) を行っているタスク。
    @ObservationIgnored var textLoadTask: Task<Void, Never>?

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
        o.initialPositionJson = pendingInitial.json
        return o
    }

    // MARK: - 表示エンジン

    /// 本文を stone_engine (STLabel) で組むか。false なら WKWebView で HTML を描く。
    var usesStoneEngine: Bool { settings.textEngine != "web" }

    /// 本文の表示エンジンの選択肢 (値, 表示名)。
    static var textEngines: [(key: String, label: String)] {
        [("stone", String(localized: "stone_engine (Japanese typesetting)")), ("web", String(localized: "WebView (HTML)"))]
    }

    /// 本文を表示するビューが用意できているか。
    private var isRendererAttached: Bool { usesStoneEngine ? text != nil : web != nil }

    func setTextEngine(_ engine: String) {
        guard Self.textEngines.contains(where: { $0.key == engine }), engine != settings.textEngine else { return }
        savePosition()
        settings.textEngine = engine
        settings.save()
        // ビューが入れ替わると attach 時に現在位置が出し直される。
        // 同じビューが残る場合 (切り替え前後で同じエンジン) に備えて、ここでも出し直しておく
        if book != nil, isRendererAttached { reloadCurrent() }
    }

    func toggleTextEngine() {
        setTextEngine(usesStoneEngine ? "web" : "stone")
    }

    // MARK: - ファイルを開く

    /// 本文を表示するビューの準備ができていなければ準備後に開く。
    func requestOpen(_ url: URL) {
        if isRendererAttached { Task { await openFile(url) } } else { pendingOpen = url }
    }

    /// WebView が用意できたときに呼ぶ。
    func webDidAttach() {
        rendererDidAttach()
    }

    /// STLabel の表示が用意できたときに呼ぶ。
    func textDidAttach() {
        rendererDidAttach()
    }

    private func rendererDidAttach() {
        if let u = pendingOpen {
            pendingOpen = nil
            Task { await openFile(u) }
        } else if book != nil {
            // レイアウト切替 (iPad の Split View など) やエンジンの切り替えでビューが作り直されたら現在位置を再表示する
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
        guard isRendererAttached else { pendingOpen = url; return }
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
            let initial = pos != nil ? InitialPosition.fraction(pos!.fraction) : .page(0)
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

    /// 本文の表示を閉じる。コミックに切り替えるときに使う。
    func closeBook() {
        guard book != nil else { return }
        readyFallbackTask?.cancel()
        textLoadTask?.cancel()
        text?.clear()
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

    private func goToSpine(_ index: Int, initial: InitialPosition, wrapMessage: String? = nil) {
        guard let book else { return }
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
        if usesStoneEngine {
            showSpineAsText(index, initial: initial)
            return
        }
        guard let web else { return }
        let url = BookScheme.url(forPath: book.spine[index].path)
        AppDirectories.trace("navigate spine=\(index) url=\(url.absoluteString) initial=\(initial.json)")
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
        goToSpine(spineIndex, initial: .fraction(fraction))
    }

    func nextPage() {
        if comic != nil { comicNext() }
        else if usesStoneEngine { text?.next() }
        else { web?.evaluate("window.__ev && window.__ev.next()") }
    }

    func prevPage() {
        if comic != nil { comicPrev() }
        else if usesStoneEngine { text?.prev() }
        else { web?.evaluate("window.__ev && window.__ev.prev()") }
    }

    /// 章の先頭 / 末尾へ (Home / End)。
    func firstPageOfChapter() {
        if usesStoneEngine { text?.goTo(page: 0) } else { web?.evaluate("window.__ev && window.__ev.goto(0)") }
    }

    func lastPageOfChapter() {
        if usesStoneEngine { text?.goTo(page: pages - 1) } else { web?.evaluate("window.__ev && window.__ev.gotoEnd()") }
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
        guard let book else { return }
        let index = path == nil ? spineIndex : book.findSpineIndex(path!)
        if index < 0 {
            // spine に無いドキュメント (脚注ファイルなど) でも本文リソースなら表示する
            guard let path, let res = book.findResource(path), PathUtil.isHtmlMediaType(res.mediaType) else { return }
            pendingInitial = Self.initialPosition(fragment: fragment)
            if usesStoneEngine {
                showText(path: res.path, initial: pendingInitial)
            } else {
                web?.navigate(to: BookScheme.url(forPath: res.path))
            }
            return
        }
        if index == spineIndex, let fragment {
            if usesStoneEngine {
                text?.goTo(anchor: fragment)
                text?.focus()
            } else {
                web?.evaluate("window.__ev && window.__ev.gotoAnchor(\(Self.jsonString(fragment)))")
                web?.focus()
            }
            return
        }
        goToSpine(index, initial: Self.initialPosition(fragment: fragment))
    }

    private static func initialPosition(fragment: String?) -> InitialPosition {
        guard let fragment else { return .page(0) }
        return .anchor(fragment)
    }

    /// JSON の文字列リテラル (前後の `"` を含む)。InitialPosition からも使うので isolation を外している。
    nonisolated static func jsonString(_ s: String) -> String {
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
            crashReloads = 0
            contentReady(page: dict["page"] as? Int ?? 0, pages: dict["pages"] as? Int ?? 1)
        case "page":
            contentPageChanged(page: dict["page"] as? Int ?? 0, pages: dict["pages"] as? Int ?? 1)
        case "next-chapter":
            contentWantsNextChapter()
        case "prev-chapter":
            contentWantsPrevChapter()
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

    // MARK: - 本文表示からの通知 (WebView / STLabel 共通)

    /// 章の表示が整ったとき。
    func contentReady(page: Int, pages: Int) {
        self.page = page
        self.pages = max(1, pages)
        readyFallbackTask?.cancel()
        hideLoading()
        updateStatus()
        scheduleSave()
    }

    /// 章の中でページが変わったとき (表示領域が変わってページ数が変わったときも)。
    func contentPageChanged(page: Int, pages: Int) {
        self.page = page
        self.pages = max(1, pages)
        updateStatus()
        scheduleSave()
    }

    /// 章の末尾でさらに進もうとしたとき。
    func contentWantsNextChapter() {
        goToSpine(spineIndex + 1, initial: .page(0), wrapMessage: String(localized: "This is the last page"))
    }

    /// 章の先頭でさらに戻ろうとしたとき。
    func contentWantsPrevChapter() {
        goToSpine(spineIndex - 1, initial: .end, wrapMessage: String(localized: "This is the first page"))
    }

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
        let engine = usesStoneEngine ? "stone" : "WebView"
        statusLeft = "\(bookTitle)\(author)   [\(format)]  \(isVerticalEffective ? String(localized: "Vertical") : String(localized: "Horizontal"))  \(engine)"
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
