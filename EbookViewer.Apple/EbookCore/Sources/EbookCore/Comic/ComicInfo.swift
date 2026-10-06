import Foundation

/// コミックの読み方向 (ComicInfo の Manga 要素から)。
public enum ComicReadingDirection: Sendable {
    case unknown
    case leftToRight
    case rightToLeft
}

/// 書庫内の ComicInfo.xml (https://github.com/anansi-project/comicinfo、スキーマ v2.0 / v2.1) のメタデータ。
/// 要素名は大文字小文字を区別せず、名前空間は無視して読む。
public struct ComicInfo: Sendable, Equatable {
    public enum YesNo: String, Sendable {
        case unknown = "Unknown"
        case no = "No"
        case yes = "Yes"
    }

    public enum MangaMode: String, Sendable {
        case unknown = "Unknown"
        case no = "No"
        case yes = "Yes"
        /// マンガで、右から左へ読む。
        case yesAndRightToLeft = "YesAndRightToLeft"
    }

    public enum PageType: String, Sendable {
        case frontCover = "FrontCover"
        case innerCover = "InnerCover"
        case roundup = "Roundup"
        case story = "Story"
        case advertisement = "Advertisement"
        case editorial = "Editorial"
        case letters = "Letters"
        case preview = "Preview"
        case backCover = "BackCover"
        case other = "Other"
        /// 表示しないページ。
        case deleted = "Deleted"
    }

    /// Pages/Page 要素。Image は書庫内の画像をファイル名順に並べたときの 0 始まりの番号。
    public struct PageInfo: Sendable, Equatable {
        public var image: Int
        public var type: PageType = .story
        public var doublePage = false
        public var bookmark = ""
        public var key = ""
        public var imageWidth = -1
        public var imageHeight = -1

        public init(image: Int, type: PageType = .story, doublePage: Bool = false, bookmark: String = "") {
            self.image = image
            self.type = type
            self.doublePage = doublePage
            self.bookmark = bookmark
        }
    }

    public var title = ""
    public var series = ""
    public var number = ""
    public var count: Int?
    public var volume: Int?
    public var alternateSeries = ""
    public var alternateNumber = ""
    public var alternateCount: Int?
    public var summary = ""
    public var notes = ""
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var writer = ""
    public var penciller = ""
    public var inker = ""
    public var colorist = ""
    public var letterer = ""
    public var coverArtist = ""
    public var editor = ""
    public var translator = ""
    public var publisher = ""
    public var imprint = ""
    public var genre = ""
    public var tags = ""
    public var web = ""
    public var pageCount: Int?
    public var languageISO = ""
    public var format = ""
    public var blackAndWhite: YesNo = .unknown
    public var manga: MangaMode = .unknown
    public var characters = ""
    public var teams = ""
    public var locations = ""
    public var scanInformation = ""
    public var storyArc = ""
    public var storyArcNumber = ""
    public var seriesGroup = ""
    public var ageRating = ""
    public var communityRating: Double?
    public var mainCharacterOrTeam = ""
    public var review = ""
    public var gtin = ""
    public var pages: [PageInfo] = []

    public init() {}

    // MARK: - 解析

    /// ルート要素が ComicInfo でなければ nil。
    public static func parse(_ data: Data) -> ComicInfo? {
        guard let root = XMLDocumentLite.parse(data), root.name.caseInsensitiveCompare("ComicInfo") == .orderedSame else { return nil }
        var info = ComicInfo()
        func text(_ name: String) -> String {
            root.children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func int(_ name: String) -> Int? { Int(text(name)) }

        info.title = text("Title")
        info.series = text("Series")
        info.number = text("Number")
        info.count = int("Count")
        info.volume = int("Volume")
        info.alternateSeries = text("AlternateSeries")
        info.alternateNumber = text("AlternateNumber")
        info.alternateCount = int("AlternateCount")
        info.summary = text("Summary")
        info.notes = text("Notes")
        info.year = int("Year")
        info.month = int("Month")
        info.day = int("Day")
        info.writer = text("Writer")
        info.penciller = text("Penciller")
        info.inker = text("Inker")
        info.colorist = text("Colorist")
        info.letterer = text("Letterer")
        info.coverArtist = text("CoverArtist")
        info.editor = text("Editor")
        info.translator = text("Translator")
        info.publisher = text("Publisher")
        info.imprint = text("Imprint")
        info.genre = text("Genre")
        info.tags = text("Tags")
        info.web = text("Web")
        info.pageCount = int("PageCount")
        info.languageISO = text("LanguageISO")
        info.format = text("Format")
        info.blackAndWhite = YesNo(rawValue: text("BlackAndWhite")) ?? .unknown
        info.manga = MangaMode(rawValue: text("Manga")) ?? .unknown
        info.characters = text("Characters")
        info.teams = text("Teams")
        info.locations = text("Locations")
        info.scanInformation = text("ScanInformation")
        info.storyArc = text("StoryArc")
        info.storyArcNumber = text("StoryArcNumber")
        info.seriesGroup = text("SeriesGroup")
        info.ageRating = text("AgeRating")
        info.communityRating = Double(text("CommunityRating"))
        info.mainCharacterOrTeam = text("MainCharacterOrTeam")
        info.review = text("Review")
        info.gtin = text("GTIN")

        if let pagesNode = root.children.first(where: { $0.name.caseInsensitiveCompare("Pages") == .orderedSame }) {
            for p in pagesNode.children where p.name.caseInsensitiveCompare("Page") == .orderedSame {
                guard let image = p.attr("Image").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else { continue }
                var page = PageInfo(image: image)
                if let t = p.attr("Type"), let type = PageType(rawValue: t.trimmingCharacters(in: .whitespaces)) { page.type = type }
                if let d = p.attr("DoublePage") { page.doublePage = Self.bool(d) }
                page.bookmark = (p.attr("Bookmark") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                page.key = p.attr("Key") ?? ""
                page.imageWidth = p.attr("ImageWidth").flatMap { Int($0) } ?? -1
                page.imageHeight = p.attr("ImageHeight").flatMap { Int($0) } ?? -1
                info.pages.append(page)
            }
        }
        return info
    }

    private static func bool(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespaces).lowercased()
        return v == "true" || v == "1" || v == "yes"
    }

    // MARK: - 表示用

    /// シリーズ・巻数・タイトルから表示名を組み立てる ("Series #3 – Title")。どれも無ければ nil。
    public var displayTitle: String? {
        let s = series.trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        let n = number.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return t.isEmpty ? nil : t }
        var out = s
        if !n.isEmpty {
            out += " #" + n
        } else if let volume {
            out += " Vol. \(volume)"
        }
        if !t.isEmpty && t.caseInsensitiveCompare(s) != .orderedSame { out += " – " + t }
        return out
    }

    /// 作者行。Writer → Penciller → Inker → CoverArtist の順に、重複を除いて並べる。
    public var creators: String {
        var seen: [String] = []
        for field in [writer, penciller, inker, coverArtist] {
            for raw in field.split(separator: ",") {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !seen.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                seen.append(name)
            }
        }
        return seen.joined(separator: ", ")
    }

    /// 出版社と年 ("Publisher, 2020")。
    public var publisherLine: String {
        var parts: [String] = []
        let p = publisher.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { parts.append(p) }
        if let year { parts.append(String(year)) }
        return parts.joined(separator: ", ")
    }

    /// Manga 要素から読み方向を決める。Yes (右→左でないマンガ) と No は左→右、Unknown は不明。
    public var readingDirection: ComicReadingDirection {
        switch manga {
        case .yesAndRightToLeft: return .rightToLeft
        case .yes, .no: return .leftToRight
        case .unknown: return .unknown
        }
    }

    /// Image 番号 → ページ情報。
    public var pagesByImage: [Int: PageInfo] {
        var out: [Int: PageInfo] = [:]
        for p in pages where out[p.image] == nil { out[p.image] = p }
        return out
    }
}
