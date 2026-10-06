import XCTest
@testable import EbookCore

/// サロゲートペア (BMP 外の文字: 𠮟 U+20B9F, 😀 U+1F600, 𝔄 U+1D504 など) が処理の途中で壊れないことを確認する。
final class SurrogateTests: XCTestCase {
    let astral = "𠮟る😀𝔄"

    func testNamedEntityAboveBMP() {
        // &Afr; = U+1D504 (BMP 外) → 数値参照は 1 つのコードポイントになる (サロゲート 2 つに割れない)
        XCTAssertEqual(ContentPreparer.replaceNamedEntities("a&Afr;b"), "a&#120068;b")
        // 複数コードポイントの実体
        XCTAssertEqual(ContentPreparer.replaceNamedEntities("&nvlt;"), "&#60;&#8402;")
        // 既存の BMP 外文字はそのまま
        XCTAssertEqual(ContentPreparer.replaceNamedEntities(astral + "&copy;"), astral + "&#169;")
    }

    func testRegexReplaceKeepsAstralChars() {
        let rx = Rx("b+")
        let s = astral + "abbbc" + astral
        XCTAssertEqual(rx.replace(s, with: "X"), astral + "aXc" + astral)
        XCTAssertEqual(rx.replace(s) { m in String(m.value.count) }, astral + "a3c" + astral)
        // "." は UTF-16 コード単位ではなくコードポイント単位でマッチする
        XCTAssertEqual(Rx(".").matches(in: "𠮟a").count, 2)
        XCTAssertEqual(Rx(".").replace("😀", with: "x"), "x")
    }

    func testInjectionBeforeHeadEndWithAstralTitle() {
        let html = "<html><head><title>\(astral)</title></head><body>\(astral)</body></html>"
        let out = ContentPreparer.prepare(Data(html.utf8), mediaType: "application/xhtml+xml", options: ViewerOptions())
        let text = String(decoding: out.body, as: UTF8.self)
        XCTAssertTrue(text.contains("<title>\(astral)</title>"))
        XCTAssertTrue(text.contains("<body>\(astral)</body>"))
        XCTAssertFalse(text.contains("\u{FFFD}"))
    }

    func testUTF16DecodeSurrogatePair() {
        var le: [UInt8] = []
        for u in "a\(astral)".utf16 { le.append(UInt8(u & 0xFF)); le.append(UInt8(u >> 8)) }
        XCTAssertEqual(TextEncoding.utf16LE.decode(le), "a" + astral)
        XCTAssertEqual(ContentPreparer.decodeText([0xFF, 0xFE] + le), "a" + astral)
        var be: [UInt8] = []
        for u in astral.utf16 { be.append(UInt8(u >> 8)); be.append(UInt8(u & 0xFF)) }
        XCTAssertEqual(ContentPreparer.decodeText([0xFE, 0xFF] + be), astral)
    }

    func testPathAndFragmentWithAstral() {
        XCTAssertEqual(PathUtil.normalize("/OPS/\(astral).xhtml"), "OPS/\(astral).xhtml")
        let encoded = "OPS/" + (astral.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + ".xhtml"
        XCTAssertEqual(PathUtil.normalize(encoded), "OPS/\(astral).xhtml")
    }

    func testXmlWellFormedWithAstralAndNumericRefs() {
        XCTAssertTrue(ContentPreparer.isWellFormedXml("<a>\(astral)&#x20B9F;&#134047;</a>"))
        // サロゲートのコードポイントを直接数値参照にしたものは XML として不正
        XCTAssertFalse(ContentPreparer.isWellFormedXml("<a>&#xD842;&#xDF9F;</a>"))
    }
}
