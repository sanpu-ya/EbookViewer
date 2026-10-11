import Testing
import CoreText
import CoreGraphics
@testable import StoneEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 文字ごとの書体の選び方 (STFontManager)。
@MainActor
struct FontTests {
    private func makeLabel(
        _ text: String, japanese: [String], latin: [String], emoji: [String] = ["AppleColorEmoji"]
    ) -> STLabel {
        let label = STLabel(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        label.isPaged = true
        label.direction = .tbRl
        label.fontSize = 20
        label.setFontNames(japanese, script: .japanese)
        label.setFontNames(latin, script: .latin)
        label.setFontNames(emoji, script: .emoji)
        label.text = text
        label.layoutSubviews()
        return label
    }

    private func fontName(_ label: STLabel, _ index: Int) -> String {
        label.context.fontManager.fontName(fontId: label.context.runs[index].fontId)
    }

    @Test func skipsAFontThatIsNotInstalled() {
        // CTFontCreateWithName は名前が見つからないと黙って別のフォントを返すので、
        // 「入っている」と思い込むと、別の書体のグリフ番号を使って違う字が出てしまう
        #expect(!STFontManager.hasGlyph(char: "A", fontName: "ThisFontIsNotInstalled-Regular"))
        let label = makeLabel(
            "A", japanese: ["HiraMinProN-W3"], latin: ["ThisFontIsNotInstalled-Regular", "HelveticaNeue"])
        #expect(fontName(label, 0) == "HelveticaNeue")
        #expect(label.context.runs[0].glyph > 0)
    }

    @Test func fallsBackToAnotherScriptWhenTheFontHasNoGlyph() {
        // ラテン文字の書体しか指定されていなくても、日本語の書体から探して描ける
        let label = makeLabel("あ", japanese: ["HelveticaNeue"], latin: ["HelveticaNeue"])
        #expect(label.context.runs[0].glyph > 0)
        #expect(fontName(label, 0) != "HelveticaNeue")
    }

    @Test func findsAFontForSymbolsOutsideTheScriptTable() {
        // ♡ や ♪ は文字種の表に無く、どの書体にも無いことがある。
        // そのときはシステムに探してもらう
        let label = makeLabel(
            "♡♪", japanese: ["HelveticaNeue"], latin: ["HelveticaNeue"], emoji: ["HelveticaNeue"])
        #expect(label.context.runs[0].glyph > 0)
        #expect(label.context.runs[1].glyph > 0)
        // 記号は縦書きで倒さず正立させる
        #expect(!label.context.isClockwise(run: label.context.runs[0]))
    }

    @Test func keepsUsingTheRequestedFontWhenItHasTheGlyph() {
        // 入っている書体はそのまま使う (勝手に乗り換えない)
        let label = makeLabel("あA", japanese: ["HiraMinProN-W3"], latin: ["HelveticaNeue"])
        #expect(fontName(label, 0) == "HiraMinProN-W3")
        #expect(fontName(label, 1) == "HelveticaNeue")
    }

    @Test func variationSelectorsTakeNoSpaceAndAreNotDrawn() {
        // 異体字セレクタは、単語で区切ると親字と離れた run になる。字幅を持たせると
        // 空白に見えてしまうので、場所を取らず何も描かないこと
        let fonts = ["HiraMinProN-W3"]
        let plain = makeLabel("葛辻邉", japanese: fonts, latin: fonts)
        let ivs = makeLabel("葛\u{E0100}辻\u{E0100}邉\u{E0101}", japanese: fonts, latin: fonts)
        // 行の長さが変わらない
        #expect(ivs.context.runs.last!.frame.maxY == plain.context.runs.last!.frame.maxY)
        // 字形選択子そのものは描かない
        #expect(ivs.drawBuckets.reduce(0) { $0 + $1.glyphs.count }
            == plain.drawBuckets.reduce(0) { $0 + $1.glyphs.count })
        // 親字はそのまま出る
        #expect(ivs.context.runs[0].glyph == plain.context.runs[0].glyph)
    }

    @Test func readsGlyphsForCharactersOutsideTheBasicPlane() {
        // サロゲートペア (UTF-16 で 2 つ) でも、1 つめのグリフを見る
        #expect(STFontManager.hasGlyph(char: "𠮟", fontName: "HiraMinProN-W3"))
    }
}
