#if os(macOS)
import XCTest
import WebKit
@testable import EbookCore

/// WebView 表示のスクリプト (viewer.js) を、実際に WKWebView で組んで確かめる。
///
/// 見本の本をそのまま読み込み、青空文庫の字下げ・字詰め (横組み前提の物理プロパティ) が
/// 縦書きでは論理プロパティへ読み替えられること、横書きでは元に戻ることを見る。
@MainActor
final class ViewerScriptTests: XCTestCase {
    private var webView: WKWebView!

    override func setUp() {
        super.setUp()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 640))
    }

    override func tearDown() {
        webView = nil
        super.tearDown()
    }

    // MARK: - 縦書き

    func testVerticalMovesAozoraIndentToTheInlineStart() async throws {
        try await load(chapter: 0, vertical: true)
        // 「ここから2字下げ、折り返して3字下げ」。縦書きでは行頭 = 上なので margin-top になる
        try await expect(".burasage", "margin-top", "60px")
        try await expect(".burasage", "margin-left", "0px")
        // text-indent はもともと論理プロパティなので、そのまま効く
        try await expect(".burasage", "text-indent", "-20px")
        // ふつうの字下げも同じ
        try await expect(".jisage_3", "margin-top", "60px")
        try await expect(".jisage_3", "margin-left", "0px")
    }

    func testVerticalMovesAozoraLineLengthToTheInlineSize() async throws {
        try await load(chapter: 3, vertical: true)
        // 「ここから十字詰め」。縦書きでは行の長さ = 高さ
        try await expect(".jizume_10", "height", "200px")
        // 字下げと重ねた段は、字下げが上に、字詰めが高さに移る
        try await expect(".jisage_2", "margin-top", "40px")
        try await expect(".jisage_2 .jizume_10", "height", "200px")
    }

    // MARK: - 横書き

    func testHorizontalKeepsTheOriginalPhysicalStyle() async throws {
        try await load(chapter: 0, vertical: false)
        try await expect(".burasage", "margin-left", "60px")
        try await expect(".burasage", "margin-top", "0px")

        try await load(chapter: 3, vertical: false)
        try await expect(".jizume_10", "width", "200px")
    }

    // MARK: - 組方向の切り替え

    func testSwitchingTheWritingModeAppliesAndRestores() async throws {
        try await load(chapter: 0, vertical: true)
        try await expect(".burasage", "margin-top", "60px")

        // 横書きに切り替えると、元の style 属性に戻る
        _ = try await eval("window.__ev.setVertical(false), 1")
        try await expect(".burasage", "margin-left", "60px")
        try await expect(".burasage", "margin-top", "0px")

        // 縦書きに戻すと、また読み替わる
        _ = try await eval("window.__ev.setVertical(true), 1")
        try await expect(".burasage", "margin-top", "60px")
        try await expect(".burasage", "margin-left", "0px")
    }

    // MARK: - 本文の読み込み

    /// 見本の本の n 章目に、本の CSS とビューアーの CSS / JS を埋め込んだ 1 枚の HTML。
    ///
    /// アプリは独自スキームで配信するが、テストでは 1 枚にまとめて読み込む
    /// (確かめたいのは配信のしくみではなく viewer.js の組版なので)。
    private static func page(chapter: Int, vertical: Bool) throws -> String {
        let url = Bundle.module.url(
            forResource: "annotations.epub", withExtension: nil, subdirectory: "Samples")!
        let book = try BookLoader.load(url: url)
        let item = book.spine[chapter]
        let html = String(decoding: try XCTUnwrap(book.findResource(item.path)).getData(), as: UTF8.self)
        let cssPath = item.path.split(separator: "/").dropLast().joined(separator: "/") + "/style/aozora.css"
        let aozora = String(decoding: try XCTUnwrap(book.findResource(cssPath)).getData(), as: UTF8.self)
        let viewerCss = String(decoding: try XCTUnwrap(ContentPreparer.asset(named: "viewer.css")), as: UTF8.self)
        let viewerJs = String(decoding: try XCTUnwrap(ContentPreparer.asset(named: "viewer.js")), as: UTF8.self)
        let head = """
            <style>\(aozora)</style>
            <style>\(viewerCss)</style>
            <style>body { font-size: 20px; line-height: 1.9; }</style>
            <script>window.__EV_SETTINGS__ = \
            {"vertical": \(vertical), "padding": 36, "initial": {"type":"page","page":0}};</script>
            <script>\(viewerJs)</script>
            """
        return html.replacingOccurrences(of: "</head>", with: head + "</head>")
    }

    private func load(chapter: Int, vertical: Bool) async throws {
        webView.loadHTMLString(try Self.page(chapter: chapter, vertical: vertical), baseURL: nil)
        for _ in 0..<200 {
            let ready = try? await eval("document.readyState === 'complete' && !!window.__ev") as? Bool
            if ready == true {
                // onReady は load でも呼ばれるので、1 回分待ってから見る
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("viewer.js が動き出さなかった")
    }

    @discardableResult
    private func eval(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    /// セレクターに当たる最初の要素の、組み終わったあとのスタイルを確かめる。
    /// XCTAssertEqual の autoclosure は await できないので、値を取ってから比べる。
    private func expect(
        _ selector: String, _ property: String, _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await style(selector, property)
        XCTAssertEqual(actual, expected, "\(selector) の \(property)", file: file, line: line)
    }

    /// セレクターに当たる最初の要素の、組み終わったあとのスタイル。
    private func style(_ selector: String, _ property: String) async throws -> String {
        let js = "String(getComputedStyle(document.querySelector('\(selector)'))"
            + ".getPropertyValue('\(property)'))"
        return try await eval(js) as? String ?? ""
    }
}
#endif
