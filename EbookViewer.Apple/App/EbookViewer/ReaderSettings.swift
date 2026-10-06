import Foundation

/// 設定・読書位置の保存先 (Application Support/EbookViewer)。
enum AppDirectories {
    static let data: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("EbookViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 未処理エラーの記録。
    static func logError(_ message: String) {
        append("[\(Date())] \(message)\n\n", to: "error.log")
    }

    private static let traceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 動作解析用のトレース (Application Support/EbookViewer/trace.log)。ナビゲーションやリソース要求の時刻を記録する。
    static func trace(_ message: String) {
        append(traceFormatter.string(from: Date()) + " " + message + "\n", to: "trace.log")
    }

    private static let logLock = NSLock()

    private static func append(_ text: String, to name: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let url = data.appendingPathComponent(name)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

/// 最近開いたファイル。サンドボックス外のファイルへ再アクセスできるようブックマークも持つ。
struct RecentFile: Codable, Equatable, Identifiable {
    var path: String
    var bookmark: Data?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// ブックマークから URL を復元する (失敗したらパスから)。
    /// サンドボックスでは、この URL に対して startAccessingSecurityScopedResource() を呼ばないと読めない。
    func resolveURL() -> URL {
        if let bookmark {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            do {
                let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
                AppDirectories.trace("recent resolved \(url.path) stale=\(stale)")
                return url
            } catch {
                AppDirectories.trace("recent bookmark resolve failed \(path): \(error)")
            }
        } else {
            AppDirectories.trace("recent has no bookmark \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    /// ブックマークを作る。呼び出し側で url へのスコープ付きアクセスを開始しておくこと。
    static func make(from url: URL) -> RecentFile {
        #if os(macOS)
        // entitlements は user-selected.read-only なので、読み取り専用のスコープでないと
        // "Could not open() the item" (NSCocoaErrorDomain 256) で作成に失敗する
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        do {
            let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            return RecentFile(path: url.path, bookmark: bookmark)
        } catch {
            AppDirectories.trace("bookmark creation failed \(url.path): \(error)")
            return RecentFile(path: url.path, bookmark: nil)
        }
    }
}

/// 表示設定。Application Support/EbookViewer/settings.json に保存する。
struct ReaderSettings: Codable {
    /// "auto" / "vertical" / "horizontal"
    var writingMode = "auto"
    var fontSizePx: Double = 20
    /// "mincho" / "gothic"
    var fontKey = "mincho"
    var lineHeight: Double = 1.9
    /// "light" / "sepia" / "dark"
    var theme = "light"
    var paddingPx = 36
    var tocOpen = false
    var recentFiles: [RecentFile] = []

    private static var fileURL: URL { AppDirectories.data.appendingPathComponent("settings.json") }

    var fontFamilyCss: String {
        switch fontKey {
        case "gothic":
            return "\"Hiragino Sans\", \"Hiragino Kaku Gothic ProN\", \"YuGothic\", \"BIZ UDGothic\", \"Noto Sans JP\", sans-serif"
        default:
            return "\"Hiragino Mincho ProN\", \"YuMincho\", \"Hiragino Mincho Pro\", \"BIZ UDMincho\", \"Noto Serif JP\", serif"
        }
    }

    var themeColors: (background: String, foreground: String) {
        switch theme {
        case "sepia": return ("#f4ecd8", "#3b2f1e")
        case "dark": return ("#1e1e1e", "#d8d8d8")
        default: return ("#fdfdf8", "#1a1a1a")
        }
    }

    mutating func addRecent(_ url: URL) {
        let old = recentFiles.first { $0.path.caseInsensitiveCompare(url.path) == .orderedSame }
        recentFiles.removeAll { $0.path.caseInsensitiveCompare(url.path) == .orderedSame }
        var entry = RecentFile.make(from: url)
        // 新しいブックマークが作れなかったときは、以前のものを捨てない
        if entry.bookmark == nil, let oldBookmark = old?.bookmark { entry.bookmark = oldBookmark }
        recentFiles.insert(entry, at: 0)
        if recentFiles.count > 12 { recentFiles.removeLast(recentFiles.count - 12) }
    }

    static func load() -> ReaderSettings {
        // 壊れた設定は既定値で上書きする
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(ReaderSettings.self, from: data) else { return ReaderSettings() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 保存失敗は致命的ではない
        try? enc.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

/// ファイルごとの読書位置。
struct ReadingPosition: Codable {
    var spineIndex: Int
    var fraction: Double
    var updatedAt: Date
}

final class ReadingPositionStore {
    private static var fileURL: URL { AppDirectories.data.appendingPathComponent("positions.json") }
    private var positions: [String: ReadingPosition]

    private init(_ positions: [String: ReadingPosition]) {
        self.positions = positions
    }

    static func load() -> ReadingPositionStore {
        if let data = try? Data(contentsOf: fileURL),
           let d = try? JSONDecoder().decode([String: ReadingPosition].self, from: data) {
            return ReadingPositionStore(d)
        }
        return ReadingPositionStore([:])
    }

    private static func key(_ path: String) -> String { path.lowercased() }

    func get(_ path: String) -> ReadingPosition? {
        positions[Self.key(path)]
    }

    func set(_ path: String, spineIndex: Int, fraction: Double) {
        positions[Self.key(path)] = ReadingPosition(spineIndex: spineIndex, fraction: fraction, updatedAt: Date())
    }

    func save() {
        // 古いものから削って肥大化を防ぐ
        if positions.count > 500 {
            let victims = positions.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(positions.count - 500)
            for (k, _) in victims { positions.removeValue(forKey: k) }
        }
        try? JSONEncoder().encode(positions).write(to: Self.fileURL, options: .atomic)
    }
}
