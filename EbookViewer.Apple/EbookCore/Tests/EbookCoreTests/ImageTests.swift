import XCTest
@testable import EbookCore

/// 挿絵入りの本 (青空文庫『奇巌城』図版 4 枚) で画像参照が解決されることを確認する。
final class ImageTests: XCTestCase {
    static func flatten(_ entries: [TocEntry]) -> [TocEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }

    static let imgSrcRegex = Rx(#"<img\b[^>]*\ssrc\s*=\s*["']([^"']+)["']"#, .caseInsensitive)

    /// spine の全ドキュメントから img の src を集め、それぞれが画像リソースとして存在することを検証する。
    static func assertAllImagesResolve(_ book: BookDocument) throws -> Int {
        var count = 0
        for item in book.spine {
            let res = try XCTUnwrap(book.findResource(item.path))
            let html = String(decoding: try res.getData(), as: UTF8.self)
            XCTAssertFalse(html.contains("kindle:"))
            XCTAssertFalse(html.lowercased().contains("recindex"))
            for m in imgSrcRegex.matches(in: html) {
                let src = m.group(1)
                XCTAssertFalse(src.lowercased().hasPrefix("data:"))
                let path = PathUtil.resolve(basePath: item.path, href: src)
                let img = book.findResource(path)
                XCTAssertNotNil(img, "画像が見つからない: \(src) (in \(item.path)) → \(path)")
                guard let img else { continue }
                XCTAssertTrue(img.mediaType.hasPrefix("image/"))
                XCTAssertTrue(try img.getData().count > 100, "画像データが空: " + path)
                count += 1
            }
        }
        return count
    }

    func testEpub3VerticalWithImagesResolvesAllImages() throws {
        let book = try BookLoader.load(url: LoaderTests.sample("kigan.epub"))
        XCTAssertEqual(book.declaredWritingMode, .vertical)
        XCTAssertTrue(book.spine.count >= 4)
        let images = try Self.assertAllImagesResolve(book)
        XCTAssertTrue(images >= 4, "img が \(images) 個しか無い")
        let cover = try XCTUnwrap(book.coverPath)
        XCTAssertTrue(try XCTUnwrap(book.findResource(cover)).mediaType.hasPrefix("image/"))
        // 目次が複数ファイルにまたがっている
        let flat = Self.flatten(book.toc)
        XCTAssertTrue(flat.count >= 3)
        for t in flat {
            XCTAssertTrue(t.path != nil && book.findSpineIndex(t.path!) >= 0, "spine に無い目次リンク: \(t.path ?? "nil")")
        }
        XCTAssertTrue(Set(flat.compactMap { $0.path }).count >= 2)
        XCTAssertTrue(flat.contains { $0.fragment != nil })
    }

    func testKf8WithImagesResolvesEmbedsAndCover() throws {
        let book = try BookLoader.load(url: LoaderTests.sample("kigan.mobi"))
        XCTAssertEqual(book.format, .kf8)
        let images = try Self.assertAllImagesResolve(book)
        XCTAssertTrue(images >= 4, "img が \(images) 個しか無い")
        XCTAssertTrue(book.resources.values.filter { $0.mediaType.hasPrefix("image/") }.count >= 4)
        XCTAssertNotNil(book.coverPath)
        // CSS フローが取り出され、本文から参照されている
        let css = book.resources.values.filter { $0.mediaType == "text/css" }
        XCTAssertFalse(css.isEmpty)
        let first = String(decoding: try XCTUnwrap(book.findResource(book.spine[0].path)).getData(), as: UTF8.self)
        XCTAssertTrue(first.contains("flow"))
        XCTAssertFalse(first.contains("kindle:flow"))
    }

    func testMobi7PartWithImagesResolvesRecindex() throws {
        let data = try Data(contentsOf: LoaderTests.sample("kigan.mobi"))
        let db = try PalmDatabase.parse(data)
        let header = try MobiHeader.parse(db.record(0))
        let end = Int(header.exthUInt32(121) ?? UInt32(db.recordCount))
        let book = try Mobi7Builder(db: db, header: header, headerRecord: 0, resourceBase: Int(header.firstResourceIndex), resourceEnd: end).build()
        XCTAssertEqual(book.format, .mobi7)
        let images = try Self.assertAllImagesResolve(book)
        XCTAssertTrue(images >= 4, "img が \(images) 個しか無い")
        XCTAssertNotNil(book.coverPath)
        // 目次 (NCX) の filepos アンカーが本文に存在する
        XCTAssertFalse(book.toc.isEmpty)
        let html = String(decoding: try XCTUnwrap(book.findResource(book.spine[0].path)).getData(), as: UTF8.self)
        for t in book.toc where t.fragment != nil {
            XCTAssertTrue(html.contains("id=\"" + t.fragment! + "\""))
        }
    }
}
