import XCTest
@testable import EbookCore

/// ComicInfo.xml の解析と、ローダーへの反映 (削除ページ・ブックマーク・読み方向・タイトル)。
final class ComicInfoTests: XCTestCase {
    static let sampleXml = """
    <?xml version="1.0" encoding="utf-8"?>
    <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
      <Title>吾輩は猫である</Title>
      <Series>名作劇場</Series>
      <Number>3</Number>
      <Count>12</Count>
      <Volume>2005</Volume>
      <Summary>猫の話。</Summary>
      <Year>2020</Year>
      <Writer>夏目漱石, 山田太郎</Writer>
      <Penciller>山田太郎</Penciller>
      <Inker> 佐藤花子 </Inker>
      <Publisher>三風屋</Publisher>
      <PageCount>5</PageCount>
      <LanguageISO>ja</LanguageISO>
      <BlackAndWhite>Yes</BlackAndWhite>
      <Manga>YesAndRightToLeft</Manga>
      <AgeRating>Everyone</AgeRating>
      <CommunityRating>4.5</CommunityRating>
      <Pages>
        <Page Image="0" Type="FrontCover" ImageWidth="1200" ImageHeight="1800" />
        <Page Image="1" Bookmark="第一章" />
        <Page Image="2" Type="Deleted" />
        <Page Image="3" DoublePage="true" Bookmark="見開き" />
        <Page Image="4" Type="BackCover" />
      </Pages>
    </ComicInfo>
    """

    func testParseReadsFieldsAndPages() throws {
        let info = try XCTUnwrap(ComicInfo.parse(Data(Self.sampleXml.utf8)))
        XCTAssertEqual(info.title, "吾輩は猫である")
        XCTAssertEqual(info.series, "名作劇場")
        XCTAssertEqual(info.number, "3")
        XCTAssertEqual(info.count, 12)
        XCTAssertEqual(info.volume, 2005)
        XCTAssertEqual(info.year, 2020)
        XCTAssertEqual(info.inker, "佐藤花子")
        XCTAssertEqual(info.publisher, "三風屋")
        XCTAssertEqual(info.languageISO, "ja")
        XCTAssertEqual(info.blackAndWhite, .yes)
        XCTAssertEqual(info.manga, .yesAndRightToLeft)
        XCTAssertEqual(info.readingDirection, .rightToLeft)
        XCTAssertEqual(info.communityRating, 4.5)
        XCTAssertEqual(info.pages.count, 5)
        XCTAssertEqual(info.pages[0].type, .frontCover)
        XCTAssertEqual(info.pages[0].imageWidth, 1200)
        XCTAssertEqual(info.pages[1].bookmark, "第一章")
        XCTAssertEqual(info.pages[1].type, .story)
        XCTAssertEqual(info.pages[2].type, .deleted)
        XCTAssertTrue(info.pages[3].doublePage)
        XCTAssertEqual(info.pagesByImage[4]?.type, .backCover)
    }

    func testDisplayTitleAndCreators() throws {
        let info = try XCTUnwrap(ComicInfo.parse(Data(Self.sampleXml.utf8)))
        XCTAssertEqual(info.displayTitle, "名作劇場 #3 – 吾輩は猫である")
        XCTAssertEqual(info.creators, "夏目漱石, 山田太郎, 佐藤花子")
        XCTAssertEqual(info.publisherLine, "三風屋, 2020")

        var onlyTitle = ComicInfo()
        onlyTitle.title = "Single"
        XCTAssertEqual(onlyTitle.displayTitle, "Single")

        var volumeOnly = ComicInfo()
        volumeOnly.series = "Series"
        volumeOnly.volume = 4
        XCTAssertEqual(volumeOnly.displayTitle, "Series Vol. 4")

        var sameTitle = ComicInfo()
        sameTitle.series = "Same"
        sameTitle.title = "same"
        sameTitle.number = "1"
        XCTAssertEqual(sameTitle.displayTitle, "Same #1")

        XCTAssertNil(ComicInfo().displayTitle)
        XCTAssertEqual(ComicInfo().readingDirection, .unknown)
        var ltr = ComicInfo()
        ltr.manga = .no
        XCTAssertEqual(ltr.readingDirection, .leftToRight)
    }

    func testParseRejectsOtherDocuments() {
        XCTAssertNil(ComicInfo.parse(Data("<Other><Title>x</Title></Other>".utf8)))
        XCTAssertNil(ComicInfo.parse(Data("not xml".utf8)))
    }

    func testLoaderAppliesComicInfoToPages() throws {
        let zip = ComicLoaderTests.makeZip([
            ("ComicInfo.xml", Array(Self.sampleXml.utf8)),
            ("p0.jpg", [0]),
            ("p1.jpg", [1]),
            ("p2.jpg", [2]),
            ("p3.jpg", [3]),
            ("p4.jpg", [4]),
        ])
        let comic = try ComicLoader.load(data: zip, fileName: "vol3.cbz")
        XCTAssertEqual(comic.title, "名作劇場 #3 – 吾輩は猫である")
        XCTAssertEqual(comic.creators, "夏目漱石, 山田太郎, 佐藤花子")
        XCTAssertEqual(comic.readingDirection, .rightToLeft)
        // Deleted のページ (p2) は除かれる
        XCTAssertEqual(comic.pages.map(\.name), ["p0.jpg", "p1.jpg", "p3.jpg", "p4.jpg"])
        XCTAssertTrue(comic.pages[0].isCover)
        XCTAssertTrue(comic.pages[2].isDoublePage)
        XCTAssertTrue(comic.pages[3].isCover)
        // ブックマークは残ったページの添字に付け替えられる
        XCTAssertEqual(comic.bookmarks.map(\.title), ["第一章", "見開き"])
        XCTAssertEqual(comic.bookmarks.map(\.pageIndex), [1, 2])
    }

    func testLoaderPrefersRootComicInfoAndIgnoresResourceForks() throws {
        let nested = "<ComicInfo><Title>Nested</Title></ComicInfo>"
        let root = "<ComicInfo><Title>Root</Title></ComicInfo>"
        let zip = ComicLoaderTests.makeZip([
            ("__MACOSX/._ComicInfo.xml", [0]),
            ("sub/comicinfo.xml", Array(nested.utf8)),
            ("ComicInfo.xml", Array(root.utf8)),
            ("sub/1.jpg", [1]),
        ])
        let comic = try ComicLoader.load(data: zip, fileName: "x.cbz")
        XCTAssertEqual(comic.title, "Root")
        XCTAssertEqual(comic.pages.count, 1)
        XCTAssertNil(comic.pages[0].info)
    }

    func testFolderComicInfoIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comicinfo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("<ComicInfo><Series>Folder Series</Series><Number>7</Number><Manga>No</Manga></ComicInfo>".utf8)
            .write(to: dir.appendingPathComponent("ComicInfo.xml"))
        try Data([1]).write(to: dir.appendingPathComponent("a.png"))
        let comic = try ComicLoader.load(url: dir)
        XCTAssertEqual(comic.title, "Folder Series #7")
        XCTAssertEqual(comic.readingDirection, .leftToRight)
    }
}
