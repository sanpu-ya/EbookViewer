import Foundation

/// コミックのコンテナ形式。
public enum ComicFormat: Sendable {
    /// ZIP 書庫 (.cbz / .zip)。
    case cbz
    /// RAR 書庫 (.cbr / .rar)。
    case cbr
    /// 画像ファイルの入ったフォルダー。
    case folder
    /// PDF (ページの描画はアプリ側が PDFKit で行う)。
    case pdf
}

/// ページ画像のピクセル寸法。
public struct ComicPageSize: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// ComicInfo.xml の Bookmark から作る目次項目。
public struct ComicBookmark: Sendable, Equatable {
    public let title: String
    /// ComicDocument.pages の添字。
    public let pageIndex: Int

    public init(title: String, pageIndex: Int) {
        self.title = title
        self.pageIndex = pageIndex
    }
}

/// コミックの 1 ページ (画像 1 枚)。
/// データは要求のたびに loader から取り出す。デコード済み画像のキャッシュは表示側が持つので、ここでは保持しない。
public final class ComicPage: @unchecked Sendable {
    /// 書庫内のパス、またはフォルダーからの相対パス。
    public let name: String
    public let mediaType: String
    /// 読み込み前から分かっている寸法 (PDF など)。不明なら nil で、表示側がヘッダーを読んで求める。
    public let knownSize: ComicPageSize?
    /// ComicInfo.xml の Pages にこのページの記述があればその内容。
    public let info: ComicInfo.PageInfo?
    private let loader: () throws -> Data

    public init(name: String, mediaType: String, knownSize: ComicPageSize? = nil, info: ComicInfo.PageInfo? = nil,
                loader: @escaping () throws -> Data) {
        self.name = name
        self.mediaType = mediaType
        self.knownSize = knownSize
        self.info = info
        self.loader = loader
    }

    public func getData() throws -> Data {
        try loader()
    }

    /// ComicInfo で見開き (DoublePage) と宣言されているページ。単独で表示する。
    public var isDoublePage: Bool { info?.doublePage == true }

    /// 表紙 (FrontCover / BackCover)。
    public var isCover: Bool { info?.type == .frontCover || info?.type == .backCover }
}

/// 形式に依存しないコミックのモデル。ページは読み順に並ぶ。
public final class ComicDocument: @unchecked Sendable {
    public let format: ComicFormat
    /// 表示名。ComicInfo があればシリーズ・巻数・タイトルから、無ければファイル名から。
    public let title: String
    public let pages: [ComicPage]
    /// 書庫内の ComicInfo.xml。無ければ nil。
    public let info: ComicInfo?
    /// ComicInfo の Bookmark (ページ順)。
    public let bookmarks: [ComicBookmark]

    public var pageCount: Int { pages.count }

    public init(format: ComicFormat, title: String, pages: [ComicPage], info: ComicInfo? = nil, bookmarks: [ComicBookmark] = []) {
        self.format = format
        self.title = title
        self.pages = pages
        self.info = info
        self.bookmarks = bookmarks
    }

    /// ComicInfo の Manga 要素による読み方向。
    public var readingDirection: ComicReadingDirection { info?.readingDirection ?? .unknown }

    /// 作者 (ComicInfo の Writer / Penciller など)。
    public var creators: String { info?.creators ?? "" }
}
