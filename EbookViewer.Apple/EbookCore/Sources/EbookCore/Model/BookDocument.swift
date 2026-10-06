import Foundation

/// 書籍のファイル形式。
public enum BookFormat: Sendable {
    case epub
    /// 旧形式 (Mobipocket / KF7)。
    case mobi7
    /// KF8 (AZW3、またはハイブリッド .mobi の KF8 部)。
    case kf8
}

/// 書籍側が宣言している組方向。
public enum WritingMode: Sendable {
    case unknown
    case vertical
    case horizontal
}

public struct BookMetadata: Sendable {
    public var title = ""
    public var author = ""
    public var publisher = ""
    public var language = ""
    public var description = ""
    public var identifier = ""

    public init() {}
}

/// 読み順に並ぶ本文ドキュメント 1 件。
public struct SpineItem: Sendable {
    /// 書籍ルートからの相対パス ("/" 区切り、先頭スラッシュなし)。
    public let path: String
    public let mediaType: String
    public let linear: Bool

    public init(path: String, mediaType: String, linear: Bool = true) {
        self.path = path
        self.mediaType = mediaType
        self.linear = linear
    }
}

/// 目次エントリ (ツリー)。
public final class TocEntry: @unchecked Sendable {
    public let title: String
    /// リンク先ドキュメントのパス。リンクを持たない見出しは nil。
    public let path: String?
    public let fragment: String?
    public var children: [TocEntry] = []

    public init(title: String, path: String?, fragment: String?) {
        self.title = title
        self.path = path
        self.fragment = fragment
    }
}

/// 画像・CSS・フォントなどのリソース。本文ドキュメントもここに含まれる。
public final class BookResource: @unchecked Sendable {
    public let path: String
    public let mediaType: String
    private let loader: () throws -> Data
    private var cache: Data?
    private let lock = NSLock()

    public init(path: String, mediaType: String, loader: @escaping () throws -> Data) {
        self.path = path
        self.mediaType = mediaType
        self.loader = loader
    }

    public convenience init(path: String, mediaType: String, data: Data) {
        self.init(path: path, mediaType: mediaType, loader: { data })
        cache = data
    }

    public func getData() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache { return c }
        let d = try loader()
        cache = d
        return d
    }
}

/// 形式に依存しない書籍モデル。ビューアーはこれだけを見て描画する。
public final class BookDocument: @unchecked Sendable {
    public let format: BookFormat
    public let metadata: BookMetadata
    public let spine: [SpineItem]
    public let toc: [TocEntry]
    /// パス ("/" 区切り、先頭スラッシュなし) → リソース。
    public let resources: [String: BookResource]
    public let declaredWritingMode: WritingMode
    public let coverPath: String?

    public init(
        format: BookFormat,
        metadata: BookMetadata,
        spine: [SpineItem],
        toc: [TocEntry],
        resources: [String: BookResource],
        declaredWritingMode: WritingMode,
        coverPath: String?
    ) {
        self.format = format
        self.metadata = metadata
        self.spine = spine
        self.toc = toc
        self.resources = resources
        self.declaredWritingMode = declaredWritingMode
        self.coverPath = coverPath
    }

    public func findResource(_ path: String) -> BookResource? {
        let p = PathUtil.normalize(path)
        if let r = resources[p] { return r }
        // 大文字小文字違いの参照は珍しくないので保険として線形検索する
        for (k, v) in resources where k.caseInsensitiveCompare(p) == .orderedSame {
            return v
        }
        return nil
    }

    public func findSpineIndex(_ path: String) -> Int {
        let p = PathUtil.normalize(path)
        for (i, item) in spine.enumerated() where item.path.caseInsensitiveCompare(p) == .orderedSame {
            return i
        }
        return -1
    }
}

/// 読み込み時のエラー。利用者に見せる文言 (DRM・未対応形式・ファイル無し) はローカライズし、
/// 解析の失敗 (invalidData) は英語の技術的な説明のまま返す。
public enum BookError: Error, LocalizedError, Sendable {
    /// DRM で保護されている。
    case drmProtected
    /// 対応していないファイル形式 (ファイル名)。
    case unsupportedFormat(String)
    /// 対応していない書籍 (任意の理由)。
    case unsupported(String)
    /// ファイルが壊れている。
    case invalidData(String)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .drmProtected:
            return Localized.string("This book is protected by DRM and cannot be opened.")
        case .unsupportedFormat(let name):
            return Localized.format("Unsupported file format: %@", name)
        case .unsupported(let m): return m
        case .invalidData(let m): return m
        case .fileNotFound(let p):
            return Localized.format("File not found: %@", p)
        }
    }

    /// 利用者の操作では解決できない (DRM・未対応形式) エラーか。
    public var isUnsupported: Bool {
        switch self {
        case .drmProtected, .unsupportedFormat, .unsupported: return true
        default: return false
        }
    }
}

/// パッケージ内の Localizable.strings (en / ja) を引く。
enum Localized {
    static let bundle: Bundle = .module

    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }
}
