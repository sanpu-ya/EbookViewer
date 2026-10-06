import XCTest
@testable import EbookCore

/// CBZ / CBR / フォルダーのコミック読み込み。書庫はテスト内で無圧縮 (stored) のものを組み立てる。
final class ComicLoaderTests: XCTestCase {
    /// 無圧縮エントリだけの ZIP を作る (CRC は検証されないので 0 のまま)。
    static func makeZip(_ entries: [(name: String, data: [UInt8])]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16((v >> 16) & 0xFFFF) }
        for e in entries {
            let name = Array(e.name.utf8)
            let offset = out.count
            out += u32(0x04034B50) + u16(20) + u16(0x800) + u16(0) + u16(0) + u16(0)
            out += u32(0) + u32(e.data.count) + u32(e.data.count) + u16(name.count) + u16(0)
            out += name + e.data
            central += u32(0x02014B50) + u16(20) + u16(20) + u16(0x800) + u16(0) + u16(0) + u16(0)
            central += u32(0) + u32(e.data.count) + u32(e.data.count) + u16(name.count) + u16(0) + u16(0)
            central += u16(0) + u16(0) + u32(0) + u32(offset) + name
        }
        let cdOffset = out.count
        out += central
        out += u32(0x06054B50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count)
        out += u32(central.count) + u32(cdOffset) + u16(0)
        return Data(out)
    }

    /// RAR 5.0 形式の無圧縮書庫を組み立てる (署名 + メインヘッダー + ファイルヘッダー群 + 終端ヘッダー)。
    enum Rar5 {
        /// 可変長整数 (7 ビットずつ、下位から。最上位ビットは継続フラグ)。
        static func vint(_ value: UInt64) -> [UInt8] {
            var v = value
            var out: [UInt8] = []
            repeat {
                var b = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { b |= 0x80 }
                out.append(b)
            } while v != 0
            return out
        }

        static func crc32(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                c ^= UInt32(b)
                for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
            }
            return ~c
        }

        /// ヘッダー CRC32 + ヘッダーサイズ + 本体。CRC はサイズフィールド以降を対象にする。
        static func header(_ body: [UInt8]) -> [UInt8] {
            let sized = vint(UInt64(body.count)) + body
            let c = crc32(sized)
            return [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8(c >> 24)] + sized
        }

        static func archive(_ files: [(name: String, data: [UInt8])]) -> Data {
            var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
            out += header([1, 0, 0]) // メインヘッダー: type 1, flags 0, archive flags 0
            for f in files {
                let name = Array(f.name.utf8)
                var body: [UInt8] = [2, 0x02] // ファイルヘッダー: type 2, flags = データ領域あり
                body += vint(UInt64(f.data.count)) // データ領域サイズ
                body += vint(0) // ファイルフラグ (mtime / CRC なし)
                body += vint(UInt64(f.data.count)) // 展開後サイズ
                body += vint(0) // 属性
                body += vint(0) // 圧縮情報: 無圧縮 (method 0)
                body += vint(1) // ホスト OS: Unix
                body += vint(UInt64(name.count)) + name
                out += header(body) + f.data
            }
            out += header([5, 0x04, 0]) // 終端ヘッダー: type 5, flags = 不明なら読み飛ばし可, end flags 0
            return Data(out)
        }
    }

    private func temporaryFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("comic-\(UUID().uuidString).\(ext)")
    }

    func testCbzPagesAreFilteredAndNaturallySorted() throws {
        let zip = Self.makeZip([
            ("010.jpg", [1]),
            ("2.png", [2]),
            ("__MACOSX/._010.jpg", [9]),
            ("sub/1.webp", [3]),
            ("sub/", []),
            ("ComicInfo.xml", [4]),
            (".hidden.jpg", [5]),
        ])
        let comic = try ComicLoader.load(data: zip, fileName: "Vol 01.cbz")
        XCTAssertEqual(comic.format, .cbz)
        XCTAssertEqual(comic.title, "Vol 01")
        XCTAssertEqual(comic.pages.map(\.name), ["2.png", "010.jpg", "sub/1.webp"])
        XCTAssertEqual(try comic.pages[0].getData(), Data([2]))
        XCTAssertEqual(try comic.pages[1].getData(), Data([1]))
        XCTAssertEqual(comic.pages[0].mediaType, "image/png")
        XCTAssertEqual(comic.pages[2].mediaType, "image/webp")
    }

    func testCbzWithoutImagesIsRejected() {
        let zip = Self.makeZip([("readme.txt", [1])])
        XCTAssertThrowsError(try ComicLoader.load(data: zip, fileName: "empty.cbz")) { error in
            XCTAssertTrue((error as? BookError)?.isUnsupported == true)
        }
    }

    func testCbrPagesAreListedAndExtracted() throws {
        let url = temporaryFile("cbr")
        let payload = Array("hello-jpeg".utf8)
        try Self.Rar5.archive([
            ("b/10.jpg", payload),
            ("b/2.jpg", [0xFF, 0xD8, 0xFF]),
            ("1.png", [0x89, 0x50]),
            ("readme.txt", [1, 2, 3]),
        ]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ComicLoader.isSupported(url))
        XCTAssertTrue(ComicLoader.needsPersistentAccess(url))
        let comic = try ComicLoader.load(url: url)
        XCTAssertEqual(comic.format, .cbr)
        XCTAssertEqual(comic.pages.map(\.name), ["1.png", "b/2.jpg", "b/10.jpg"])
        XCTAssertEqual(try comic.pages[2].getData(), Data(payload))
        XCTAssertEqual(try comic.pages[0].getData(), Data([0x89, 0x50]))
        XCTAssertEqual(comic.pages[1].mediaType, "image/jpeg")
    }

    func testCbrWithoutImagesIsRejected() throws {
        let url = temporaryFile("rar")
        try Self.Rar5.archive([("notes.txt", [1])]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ComicLoader.load(url: url)) { error in
            XCTAssertTrue((error as? BookError)?.isUnsupported == true)
        }
    }

    func testCorruptCbrGivesError() throws {
        let url = temporaryFile("cbr")
        try Data([0x52, 0x61, 0x72, 0x21]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ComicLoader.load(url: url)) { error in
            XCTAssertNotNil(error as? BookError)
        }
    }

    func test7zArchiveGivesUnsupportedError() throws {
        let url = temporaryFile("cb7")
        try Data([0x37, 0x7A, 0xBC, 0xAF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ComicLoader.isSupported(url))
        XCTAssertFalse(ComicLoader.needsPersistentAccess(url))
        XCTAssertThrowsError(try ComicLoader.load(url: url)) { error in
            guard let be = error as? BookError else { return XCTFail("BookError expected") }
            XCTAssertTrue(be.isUnsupported)
            XCTAssertTrue(be.localizedDescription.contains(".cb7"))
        }
    }

    func testFolderPagesAreSortedRecursively() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ch2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ch10"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for rel in ["ch10/1.jpg", "ch2/10.jpg", "ch2/9.jpg", "cover.png", "notes.txt", ".DS_Store"] {
            try Data([UInt8(rel.utf8.count)]).write(to: dir.appendingPathComponent(rel))
        }
        XCTAssertTrue(ComicLoader.isSupported(dir))
        XCTAssertTrue(ComicLoader.needsPersistentAccess(dir))
        let comic = try ComicLoader.load(url: dir)
        XCTAssertEqual(comic.format, .folder)
        XCTAssertEqual(comic.pages.map(\.name), ["ch2/9.jpg", "ch2/10.jpg", "ch10/1.jpg", "cover.png"])
        XCTAssertEqual(try comic.pages[3].getData().count, 1)
    }

    func testNaturalOrder() {
        XCTAssertTrue(ComicLoader.naturalOrder("page2.jpg", "page10.jpg"))
        XCTAssertTrue(ComicLoader.naturalOrder("A.jpg", "b.jpg"))
        XCTAssertFalse(ComicLoader.naturalOrder("010.jpg", "2.jpg"))
        XCTAssertTrue(ComicLoader.isImage("x.JPG"))
        XCTAssertFalse(ComicLoader.isImage("x.txt"))
        XCTAssertFalse(ComicLoader.isImage("noext"))
        XCTAssertEqual(ComicLoader.normalizedEntryName("a\\b\\1.jpg"), "a/b/1.jpg")
    }
}
