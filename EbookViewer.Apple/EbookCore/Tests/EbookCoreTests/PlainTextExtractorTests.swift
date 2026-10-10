import Testing
import Foundation
@testable import EbookCore

/// STLabel 表示用のプレーンテキスト抽出。
struct PlainTextExtractorTests {
    private func extract(_ html: String) -> ExtractedText {
        PlainTextExtractor.extract(html: html)
    }

    @Test func stripsTagsAndKeepsBlockBreaks() {
        let r = extract("<html><body><p>一行目</p><p>二行目</p></body></html>")
        #expect(r.text == "一行目\n二行目")
    }

    @Test func dropsHeadScriptAndStyle() {
        let html = """
        <html><head><title>題名</title><style>p { color: red }</style></head>
        <body><script>var a = 1;</script><p>本文</p></body></html>
        """
        #expect(extract(html).text == "本文")
    }

    @Test func keepsRubyBaseAndDropsReading() {
        let r = extract("<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>です</p>")
        #expect(r.text == "漢字です")
    }

    @Test func brMakesOneNewlineHeadingMakesBlankLine() {
        #expect(extract("<p>上<br/>下</p>").text == "上\n下")
        #expect(extract("<p>前</p><h1>見出し</h1><p>後</p>").text == "前\n\n見出し\n\n後")
    }

    @Test func collapsesSpacesButKeepsIdeographicSpace() {
        #expect(extract("<p>a   b\tc</p>").text == "a b c")
        // 段落の字下げに使う全角スペースは残す
        #expect(extract("<p>　ある日の事である。</p>").text == "　ある日の事である。")
    }

    @Test func dropsSourceLineBreakBetweenWideCharacters() {
        // 全角文字に挟まれた原文の改行は空白にしない (CSS の segment break transformation rules と同じ)
        let r = extract("<p>ある日の暮方の事である。\n一人の下人が、</p>")
        #expect(r.text == "ある日の暮方の事である。一人の下人が、")
        // 欧文の間では空白にする
        #expect(extract("<p>one\ntwo</p>").text == "one two")
    }

    @Test func collapsesCrlfLineEndings() {
        // CRLF は Swift では 1 つの Character なので、畳み込みから漏れると本文に改行が残ってしまう
        let r = extract("<div>\r\n<h1>機械</h1>\r\n<h2>横光利一</h2>\r\n<br />\r\n</div>\r\n<div>\r\n　初めの間は\r\n</div>")
        #expect(r.text == "機械\n\n横光利一\n\n　初めの間は")
        #expect(extract("<p>a\r\nb</p>").text == "a b")
    }

    @Test func decodesEntities() {
        #expect(extract("<p>&lt;a&gt; &amp; &#x3042;&#12356;&hellip;</p>").text == "<a> & あい…")
    }

    @Test func replacesImageWithPlaceholder() {
        #expect(extract("<p>前<img src=\"a.png\" alt=\"図1\"/>後</p>").text == "前\n［図1］\n後")
        let noAlt = extract("<p><img src=\"a.png\"/></p>").text
        #expect(noAlt.hasPrefix("［") && noAlt.hasSuffix("］"))
    }

    @Test func recordsAnchorPositions() {
        let r = extract("<p>あいうえお</p><p id=\"c2\">かきくけこ</p>")
        #expect(r.text == "あいうえお\nかきくけこ")
        // "か" は 6 文字目 (改行を 1 文字として数える)
        #expect(r.anchors["c2"] == 6)
    }

    @Test func anchorOnInlineElementPointsAtItsText() {
        let r = extract("<p>あい<a name=\"x\">うえ</a>お</p>")
        #expect(r.anchors["x"] == 2)
    }

    @Test func handlesCommentsCdataAndDoctype() {
        let html = "<!DOCTYPE html><!-- メモ --><p>本文<![CDATA[そのまま]]></p>"
        #expect(extract(html).text == "本文そのまま")
    }

    @Test func survivesUnclosedTags() {
        // 整形式でなくても落ちない
        #expect(extract("<p>あ<b>い</p>").text == "あい")
        #expect(extract("1 < 2 だ").text == "1 < 2 だ")
    }

    @Test func preKeepsWhitespace() {
        #expect(extract("<pre>a  b\nc</pre>").text == "a  b\nc")
    }
}
