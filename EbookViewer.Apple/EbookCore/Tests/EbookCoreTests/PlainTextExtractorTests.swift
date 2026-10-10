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

    @Test func keepsRubyBaseInTextAndTakesTheReadingOut() {
        let r = extract("<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>です</p>")
        #expect(r.text == "漢字です")
        #expect(r.ruby == [RubyAnnotation(range: 0..<2, text: "かんじ")])
    }

    @Test func pairsEachBaseWithItsOwnReading() {
        // <rb> で親文字が区切られている形
        let r = extract("<p><ruby><rb>漢</rb><rt>かん</rt><rb>字</rb><rt>じ</rt></ruby>だ</p>")
        #expect(r.text == "漢字だ")
        #expect(r.ruby == [
            RubyAnnotation(range: 0..<1, text: "かん"),
            RubyAnnotation(range: 1..<2, text: "じ"),
        ])
    }

    @Test func pairsReadingsWithoutRbTags() {
        // <rb> を使わず <rt> で区切る形
        let r = extract("<ruby>東<rt>とう</rt>京<rt>きょう</rt></ruby>")
        #expect(r.text == "東京")
        #expect(r.ruby == [
            RubyAnnotation(range: 0..<1, text: "とう"),
            RubyAnnotation(range: 1..<2, text: "きょう"),
        ])
    }

    @Test func rubyPositionsFollowTheSurroundingText() {
        let r = extract("<p>その<ruby>機械<rt>きかい</rt></ruby>は</p><p><ruby>私<rt>わたし</rt></ruby>の</p>")
        #expect(r.text == "その機械は\n私の")
        #expect(r.ruby == [
            RubyAnnotation(range: 2..<4, text: "きかい"),
            RubyAnnotation(range: 6..<7, text: "わたし"),
        ])
        // 親文字の範囲が本文のその位置と合っている
        let base = Array(r.text)
        #expect(String(base[2..<4]) == "機械")
        #expect(String(base[6..<7]) == "私")
    }

    @Test func dropsEmptyReadings() {
        #expect(extract("<ruby>字<rt> </rt></ruby>").ruby.isEmpty)
        #expect(extract("<ruby><rt>よみ</rt></ruby>").ruby.isEmpty)
    }

    @Test func takesSecondLevelRubyFromRtc() {
        // <rtc> の注記は親文字の反対側に置く
        let r = extract("<ruby>漢字<rt>かんじ</rt><rtc>kanji</rtc></ruby>")
        #expect(r.text == "漢字")
        #expect(r.ruby == [
            RubyAnnotation(range: 0..<2, text: "かんじ"),
            RubyAnnotation(range: 0..<2, text: "kanji", position: .under),
        ])
    }

    @Test func secondLevelWithOneReadingSpansTheWholeBase() {
        // 1 段目は 1 文字ずつ、2 段目はまとめて 1 つ
        let r = extract("""
        <ruby><rb>旧</rb><rb>金</rb><rb>山</rb>\
        <rt>jiù</rt><rt>jīn</rt><rt>shān</rt>\
        <rtc><rt>San Francisco</rt></rtc></ruby>
        """)
        #expect(r.text == "旧金山")
        #expect(r.ruby == [
            RubyAnnotation(range: 0..<1, text: "jiù"),
            RubyAnnotation(range: 1..<2, text: "jīn"),
            RubyAnnotation(range: 2..<3, text: "shān"),
            RubyAnnotation(range: 0..<3, text: "San Francisco", position: .under),
        ])
    }

    @Test func secondLevelWithSeveralReadingsFollowsTheFirstLevelSplit() {
        let r = extract("""
        <ruby>東<rt>とう</rt>京<rt>きょう</rt>\
        <rtc><rt>tō</rt><rt>kyō</rt></rtc></ruby>
        """)
        #expect(r.text == "東京")
        #expect(r.ruby == [
            RubyAnnotation(range: 0..<1, text: "とう"),
            RubyAnnotation(range: 1..<2, text: "きょう"),
            RubyAnnotation(range: 0..<1, text: "tō", position: .under),
            RubyAnnotation(range: 1..<2, text: "kyō", position: .under),
        ])
    }

    @Test func dropsThirdLevelRubyAndKeepsRtcTextOutOfTheBody() {
        // 置き場所が無い 3 段目は捨てる。<rtc> の中身が本文に混ざらないことも確かめる
        let r = extract("<p><ruby>漢<rt>かん</rt><rtc>kan</rtc><rtc>KAN</rtc></ruby>字</p>")
        #expect(r.text == "漢字")
        #expect(r.ruby == [
            RubyAnnotation(range: 0..<1, text: "かん"),
            RubyAnnotation(range: 0..<1, text: "kan", position: .under),
        ])
    }

    @Test func decodesEntitiesInsideRubyReading() {
        let r = extract("<ruby>…<rt>&#12390;&#12435;</rt></ruby>")
        #expect(r.ruby == [RubyAnnotation(range: 0..<1, text: "てん")])
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

    // MARK: - 強調表示

    @Test func takesBoldFromStrongAndB() {
        let r = extract("<p>これは<strong>重要</strong>で<b>太字</b>です</p>")
        #expect(r.text == "これは重要で太字です")
        #expect(r.styles == [
            StyleAnnotation(range: 3..<5, style: .bold),
            StyleAnnotation(range: 6..<8, style: .bold),
        ])
        #expect(r.emphasis.isEmpty)
    }

    @Test func japaneseEmUsesEmphasisMarksInsteadOfItalic() {
        // 日本語には斜体が無いので圏点にする
        let r = extract("<p>これは<em>大事</em>です</p>")
        #expect(r.text == "これは大事です")
        #expect(r.emphasis == [EmphasisAnnotation(range: 3..<5, mark: "\u{FE45}")])
        #expect(r.styles.isEmpty)
    }

    @Test func latinEmUsesItalic() {
        let r = extract("<p>This is <em>very</em> important</p>")
        #expect(r.styles == [StyleAnnotation(range: 8..<12, style: .italic)])
        #expect(r.emphasis.isEmpty)
    }

    @Test func takesEmphasisMarksFromClassNames() {
        // 青空文庫からの変換でよくある形
        let r = extract("<p><em class=\"sesame_dot\">傍点</em>と<span class=\"em-maru\">丸</span></p>")
        #expect(r.text == "傍点と丸")
        #expect(r.emphasis == [
            EmphasisAnnotation(range: 0..<2, mark: "\u{FE45}"),
            EmphasisAnnotation(range: 3..<4, mark: "\u{25CF}"),
        ])
    }

    @Test func nestedEmphasisKeepsBothRanges() {
        let r = extract("<p><strong>太い<em>そして大事</em></strong></p>")
        #expect(r.text == "太いそして大事")
        #expect(r.styles == [StyleAnnotation(range: 0..<7, style: .bold)])
        #expect(r.emphasis == [EmphasisAnnotation(range: 2..<7, mark: "\u{FE45}")])
    }

    @Test func ignoresEmptyEmphasis() {
        #expect(extract("<p><strong></strong>本文</p>").styles.isEmpty)
        #expect(extract("<p>本文<em></em></p>").emphasis.isEmpty)
        // 対応する開きタグが無い閉じタグでも落ちない
        #expect(extract("<p>本文</strong></p>").text == "本文")
    }

    @Test func takesUnderlineFromUAndIns() {
        let r = extract("<p>ここに<u>下線</u>と<ins>追記</ins></p>")
        #expect(r.text == "ここに下線と追記")
        #expect(r.lines == [
            LineAnnotation(range: 3..<5, style: .solid, position: .underline),
            LineAnnotation(range: 6..<8, style: .solid, position: .underline),
        ])
        #expect(r.styles.isEmpty)
    }

    @Test func takesStrikethroughFromSAndClass() {
        #expect(extract("<p><s>消し</s></p>").lines
            == [LineAnnotation(range: 0..<2, style: .solid, position: .strikethrough)])
        #expect(extract("<p><span class=\"dbl_strike\">消し</span></p>").lines
            == [LineAnnotation(range: 0..<2, style: .double, position: .strikethrough)])
    }

    @Test func takesAozoraLineStyles() {
        // 青空文庫の注記から変換された傍線 (右) と左傍線
        let cases: [(String, LineStyle, LinePosition)] = [
            ("underline_solid", .solid, .underline),
            ("underline_double", .double, .underline),
            ("underline_dotted", .dotted, .underline),
            ("underline_dashed", .dashed, .underline),
            ("underline_wave", .wave, .underline),
            ("overline_solid", .solid, .overline),
            ("overline_wave", .wave, .overline),
        ]
        for (className, style, position) in cases {
            let r = extract("<p><span class=\"\(className)\">線</span></p>")
            #expect(r.lines == [LineAnnotation(range: 0..<1, style: style, position: position)])
        }
    }

    @Test func takesAozoraEmphasisMarks() {
        // 青空文庫の傍点の種類
        let cases: [(String, String)] = [
            ("sesame_dot", "\u{FE45}"),
            ("white_sesame_dot", "\u{FE46}"),
            ("black_circle", "\u{25CF}"),
            ("white_circle", "\u{25CB}"),
            ("black_up-pointing_triangle", "\u{25B2}"),
            ("white_up-pointing_triangle", "\u{25B3}"),
            ("bullseye", "\u{25CE}"),
            ("fisheye", "\u{25C9}"),
            ("saltire", "\u{00D7}"),
        ]
        for (className, mark) in cases {
            let r = extract("<p><em class=\"\(className)\">点</em></p>")
            #expect(r.emphasis == [EmphasisAnnotation(range: 0..<1, mark: mark, position: .over)])
        }
    }

    @Test func emphasisAfterGoesOnTheOtherSide() {
        // 「左に傍点」は _after が付く
        let r = extract("<p><em class=\"sesame_dot_after\">点</em></p>")
        #expect(r.emphasis == [EmphasisAnnotation(range: 0..<1, mark: "\u{FE45}", position: .under)])
    }

    @Test func takesBoldAndItalicFromAozoraClasses() {
        #expect(extract("<p><span class=\"futoji\">太</span></p>").styles
            == [StyleAnnotation(range: 0..<1, style: .bold)])
        #expect(extract("<p><span class=\"shatai\">斜</span></p>").styles
            == [StyleAnnotation(range: 0..<1, style: .italic)])
    }

    @Test func readsSeveralClassesOnOneElement() {
        let r = extract("<p><span class=\"futoji underline_wave\">両方</span></p>")
        #expect(r.styles == [StyleAnnotation(range: 0..<2, style: .bold)])
        #expect(r.lines == [LineAnnotation(range: 0..<2, style: .wave, position: .underline)])
    }

    @Test func underlineCombinesWithBold() {
        let r = extract("<p><strong><u>太い下線</u></strong></p>")
        #expect(r.lines == [LineAnnotation(range: 0..<4, style: .solid, position: .underline)])
        #expect(r.styles == [StyleAnnotation(range: 0..<4, style: .bold)])
    }

    @Test func takesFontSizeFromAozoraClasses() {
        #expect(extract("<p><span class=\"dai2\">大</span></p>").sizes
            == [SizeAnnotation(range: 0..<1, scale: 1.4)])
        #expect(extract("<p><span class=\"sho1\">小</span></p>").sizes
            == [SizeAnnotation(range: 0..<1, scale: 0.9)])
        #expect(extract("<p><span class=\"font3\">大</span></p>").sizes
            == [SizeAnnotation(range: 0..<1, scale: 1.3)])
        #expect(extract("<p><span class=\"font-4\">小</span></p>").sizes
            == [SizeAnnotation(range: 0..<1, scale: 0.7)])
    }

    @Test func takesFontSizeFromInlineStyle() {
        #expect(extract("<p><span style=\"font-size: 140%\">大</span></p>").sizes
            == [SizeAnnotation(range: 0..<1, scale: 1.4)])
        #expect(extract("<p><span style=\"font-size:1.5em\">大</span></p>").sizes
            == [SizeAnnotation(range: 0..<1, scale: 1.5)])
        // 単位の無い指定は読まない
        #expect(extract("<p><span style=\"font-size: 12\">?</span></p>").sizes.isEmpty)
    }

    @Test func headingsGetABiggerSize() {
        let r = extract("<h3>大見出し</h3><p>本文</p>")
        #expect(r.text == "大見出し\n\n本文")
        #expect(r.sizes == [SizeAnnotation(range: 0..<4, scale: 1.4)])
    }

    @Test func headingStyleWinsOverTheDefaultSize() {
        let r = extract("<h3 style=\"font-size: 200%\">見出し</h3>")
        #expect(r.sizes == [SizeAnnotation(range: 0..<3, scale: 2.0)])
    }

    @Test func takesIndentFromAozoraClasses() {
        #expect(extract("<div class=\"jisage_3\">字下げ</div>").indents
            == [IndentAnnotation(range: 0..<3, head: 3)])
        #expect(extract("<div class=\"jisage\">字下げ</div>").indents
            == [IndentAnnotation(range: 0..<3, head: 1)])
        #expect(extract("<div class=\"chitsuki_0\">地付き</div>").indents
            == [IndentAnnotation(range: 0..<3, head: 0, tail: 0)])
        #expect(extract("<div class=\"chitsuki_2\">地寄せ</div>").indents
            == [IndentAnnotation(range: 0..<3, head: 0, tail: 2)])
    }

    @Test func takesIndentFromMarginStyle() {
        // 青空文庫の HTML は class と style の両方を持つことが多い
        #expect(extract("<div class=\"jisage_3\" style=\"margin-left: 3em\">字下げ</div>").indents
            == [IndentAnnotation(range: 0..<3, head: 3)])
        // 縦書きは margin-right
        #expect(extract("<div style=\"margin-right: 2em\">字下げ</div>").indents
            == [IndentAnnotation(range: 0..<3, head: 2)])
    }

    @Test func indentCoversTheWholeBlock() {
        let r = extract("<p>本文</p><div class=\"jisage_2\">引用の一行目\n引用の二行目</div><p>本文</p>")
        #expect(r.indents.count == 1)
        let indent = r.indents[0]
        let chars = Array(r.text)
        #expect(String(chars[indent.range]).hasPrefix("引用"))
        #expect(indent.head == 2)
    }

    @Test func takesTateChuYokoFromClass() {
        let r = extract("<p>昭和<span class=\"tcy\">30</span>年</p>")
        #expect(r.text == "昭和30年")
        #expect(r.tateChuYoko == [2..<4])
    }

    @Test func emphasisRangesFollowTheSurroundingText() {
        let r = extract("<p>前</p><p>中<strong>太字</strong>後</p>")
        #expect(r.text == "前\n中太字後")
        #expect(r.styles == [StyleAnnotation(range: 3..<5, style: .bold)])
        let chars = Array(r.text)
        #expect(String(chars[3..<5]) == "太字")
    }

    @Test func takesImagesOutWithTheirPosition() {
        // 本文には置き場所の 1 文字 (全角空白) だけが入る
        let r = extract("<p>前<img src=\"a.png\" alt=\"図1\"/>後</p>")
        #expect(r.text == "前\u{3000}後")
        #expect(r.images == [ImageAnnotation(offset: 1, source: "a.png", alt: "図1", isBlock: false)])
    }

    @Test func imageAloneInABlockIsAnIllustration() {
        // 段落に 1 つだけの画像は挿絵、本文に挟まれた画像は行内の画像
        let r = extract("<p>本文</p><div><img src=\"plate.png\"/></div><p>あ<img src=\"gaiji.png\"/>い</p>")
        #expect(r.text == "本文\n\u{3000}\nあ\u{3000}い")
        #expect(r.images.map(\.isBlock) == [true, false])
        #expect(r.images.map(\.source) == ["plate.png", "gaiji.png"])
        let chars = Array(r.text)
        #expect(chars[r.images[0].offset] == "\u{3000}")
        #expect(chars[r.images[1].offset] == "\u{3000}")
    }

    @Test func takesImageSourceFromSvgHref() {
        let r = extract("<div><image xlink:href=\"cover.jpg\"/></div>")
        #expect(r.images.map(\.source) == ["cover.jpg"])
    }

    @Test func ignoresImagesWithoutASource() {
        #expect(extract("<p>本文<img alt=\"なし\"/></p>").images.isEmpty)
        #expect(extract("<p>本文<img alt=\"なし\"/></p>").text == "本文")
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
