import XCTest
@testable import EbookCore

final class LoaderTests: XCTestCase {
    static func sample(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Samples")!
    }

    static func firstSpineText(_ book: BookDocument) throws -> String {
        let item = book.spine[0]
        let res = try XCTUnwrap(book.findResource(item.path))
        return String(decoding: try res.getData(), as: UTF8.self)
    }

    func testEpubLoadsMetadataSpineAndText() throws {
        let book = try BookLoader.load(url: Self.sample("kikai.epub"))
        XCTAssertEqual(book.format, .epub)
        XCTAssertEqual(book.metadata.title, "機械")
        XCTAssertEqual(book.metadata.author, "横光利一")
        XCTAssertEqual(book.spine.count, 1)
        XCTAssertTrue(try Self.firstSpineText(book).contains("初めの間は私は私の家の主人が狂人ではないのか"))
        XCTAssertFalse(book.toc.isEmpty)
    }

    func testVerticalEpubDeclaresVerticalWritingMode() throws {
        let book = try BookLoader.load(url: Self.sample("kikai_vertical.epub"))
        XCTAssertEqual(book.declaredWritingMode, .vertical)
        XCTAssertFalse(book.spine.isEmpty)
        XCTAssertTrue(try Self.firstSpineText(book).contains("初めの間は私は私の家の主人"))
    }

    func testHybridMobiPrefersKf8Part() throws {
        let book = try BookLoader.load(url: Self.sample("kikai.mobi"))
        XCTAssertEqual(book.format, .kf8)
        XCTAssertEqual(book.metadata.title, "機械")
        XCTAssertFalse(book.spine.isEmpty)
        let text = try Self.firstSpineText(book)
        XCTAssertTrue(text.contains("初めの間は私は私の家の主人が狂人ではないのか"))
        XCTAssertFalse(text.contains("kindle:"))
    }

    func testMobi7PartCanBeReadDirectly() throws {
        let data = try Data(contentsOf: Self.sample("kikai.mobi"))
        // KF8 部があるので通常は KF8 が選ばれる。MOBI7 ビルダーを直接検証する
        let db = try PalmDatabase.parse(data)
        let header = try MobiHeader.parse(db.record(0))
        let end = Int(header.exthUInt32(121) ?? UInt32(db.recordCount))
        let mobi7 = try Mobi7Builder(db: db, header: header, headerRecord: 0, resourceBase: Int(header.firstResourceIndex), resourceEnd: end).build()
        XCTAssertEqual(mobi7.format, .mobi7)
        let text = try Self.firstSpineText(mobi7)
        XCTAssertTrue(text.contains("初めの間は私は私の家の主人が狂人ではないのか"))
        XCTAssertFalse(text.contains("filepos="))
        XCTAssertFalse(text.contains("<mbp:"))
        XCTAssertEqual(mobi7.metadata.title, "機械")
    }

    func testKf8TocLabelsComeFromCncx() throws {
        let mobi = try BookLoader.load(url: Self.sample("kikai.mobi"))
        XCTAssertFalse(mobi.toc.isEmpty)
        for t in mobi.toc {
            XCTAssertNil(Int(t.title), "目次ラベルが CNCX から取れていない: " + t.title)
        }
        XCTAssertTrue(mobi.toc.contains { $0.title == "開始" && $0.path == mobi.spine[0].path && $0.fragment != nil })

        let azw3 = try BookLoader.load(url: Self.sample("kikai.azw3"))
        XCTAssertTrue(azw3.toc.contains { $0.title == "機械" && $0.path == azw3.spine[0].path })
        // 目次のリンク先 id が本文に存在する
        let text = try Self.firstSpineText(azw3)
        for t in azw3.toc where t.fragment != nil {
            XCTAssertTrue(text.contains("id=\"" + t.fragment! + "\""), "id が無い: " + t.fragment!)
        }
    }

    func testAzw3LoadsAsKf8() throws {
        let book = try BookLoader.load(url: Self.sample("kikai.azw3"))
        XCTAssertEqual(book.format, .kf8)
        XCTAssertEqual(book.metadata.title, "機械")
        XCTAssertFalse(book.spine.isEmpty)
        let text = try Self.firstSpineText(book)
        XCTAssertTrue(text.contains("初めの間は私は私の家の主人"))
        XCTAssertFalse(text.contains("kindle:"))
    }

    func testContentPreparerInjectsViewerAssets() throws {
        let book = try BookLoader.load(url: Self.sample("kikai.epub"))
        let item = book.spine[0]
        let res = try XCTUnwrap(book.findResource(item.path))
        let (body, contentType) = ContentPreparer.prepare(try res.getData(), mediaType: item.mediaType, options: ViewerOptions())
        let html = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(html.contains("__viewer__/viewer.js"))
        XCTAssertTrue(html.contains("__EV_SETTINGS__"))
        XCTAssertFalse(html.lowercased().contains("jquery"))
        XCTAssertTrue(contentType.contains("charset=utf-8"))
        XCTAssertNotNil(ContentPreparer.asset(named: "viewer.js"))
        XCTAssertNotNil(ContentPreparer.asset(named: "viewer.css"))
    }

    func testXhtmlIsServedAsXhtmlWhenWellFormed() throws {
        let book = try BookLoader.load(url: Self.sample("kigan.epub"))
        let item = book.spine[1]
        let res = try XCTUnwrap(book.findResource(item.path))
        let (body, contentType) = ContentPreparer.prepare(try res.getData(), mediaType: item.mediaType, options: ViewerOptions())
        XCTAssertTrue(contentType.hasPrefix("application/xhtml+xml"), contentType)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("<![CDATA["))
    }

    func testNamedEntitiesAreConvertedToNumeric() {
        XCTAssertEqual(ContentPreparer.replaceNamedEntities("a&nbsp;b &amp; &hearts; &unknown;"), "a&#160;b &amp; &#9829; &unknown;")
    }

    func testDecodeTextHonorsCharsetDeclaration() {
        // "機械" の Shift_JIS は 8B40 8A42。Linux の Foundation は Shift_JIS を扱えないので文字の検証は Apple 上のみ
        var sjis = Array("<html><head><meta charset=\"Shift_JIS\"></head><body>".utf8)
        sjis += [0x8B, 0x40, 0x8A, 0x42]
        sjis += Array("</body></html>".utf8)
        let text = ContentPreparer.decodeText(sjis)
        #if canImport(Darwin)
        XCTAssertTrue(text.contains("機械"))
        XCTAssertTrue(text.contains("charset=\"utf-8\""), text)
        #endif
        XCTAssertTrue(text.contains("<body>"))

        // CP1252 は自前実装なのでどの環境でも動く
        var cp = Array("<?xml version=\"1.0\" encoding=\"windows-1252\"?><p>".utf8)
        cp += [0x93, 0x41, 0x94] // “A”
        cp += Array("</p>".utf8)
        let t2 = ContentPreparer.decodeText(cp)
        XCTAssertTrue(t2.contains("\u{201C}A\u{201D}"), t2)
        XCTAssertTrue(t2.contains("encoding=\"utf-8\""), t2)
    }

    func testPathUtilResolvesRelativeReferences() {
        XCTAssertEqual(PathUtil.resolve(basePath: "OEBPS/text/ch1.xhtml", href: "../images/a.png"), "OEBPS/images/a.png")
        XCTAssertEqual(PathUtil.makeRelative(from: "Text/part0000.xhtml", to: "Images/image00001.jpg"), "../Images/image00001.jpg")
        XCTAssertEqual(PathUtil.normalize("./x/../a%20b.xhtml#frag"), "a b.xhtml")
    }

    func testPalmDocDecompressRoundtripOfKnownSequence() {
        // "hello hello" を PalmDOC 圧縮した形: リテラル + 距離 6 / 長さ 5 の参照
        let compressed: [UInt8] = [0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x80, UInt8(((6 << 3) | 2) & 0xFF)]
        let result = PalmDocDecompressor.decompress(compressed)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "hello hello")
    }

    func testSha1MatchesKnownVector() {
        let h = SHA1.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(h, "a9993e364706816aba3e25717850c26c9cd0d89d")
    }
}
