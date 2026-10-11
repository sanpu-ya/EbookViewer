import Testing
import CoreText
import CoreGraphics
@testable import StoneEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 強調表示 (太字・斜体・圏点)。
@MainActor
struct StyleTests {
    private func makeLabel(
        _ text: String,
        styles: [STStyleAnnotation] = [],
        lines: [STLineAnnotation] = [],
        tateChuYoko: [Range<Int>] = [],
        orientations: [STOrientationAnnotation] = [],
        sizes: [STSizeAnnotation] = [],
        shifts: [STShiftAnnotation] = [],
        indents: [STIndentAnnotation] = [],
        warichu: [Range<Int>] = [],
        boxes: [STBoxAnnotation] = [],
        horizontal: [Range<Int>] = [],
        emphasis: [STEmphasisAnnotation] = [],
        ruby: [STRubyAnnotation] = [],
        size: CGSize = CGSize(width: 400, height: 600),
        direction: STDirection = .tbRl
    ) -> STLabel {
        let label = STLabel(frame: CGRect(origin: .zero, size: size))
        label.isPaged = true
        label.direction = direction
        label.fontSize = 20
        label.lineHeightScale = 1.9
        label.punctuationMode = .stone
        label.setFontNames(["HiraMinProN-W3"], script: .japanese)
        label.setFontNames(["HelveticaNeue"], script: .latin)
        label.text = text
        label.styleAnnotations = styles
        label.lineAnnotations = lines
        label.tateChuYokoRanges = tateChuYoko
        label.orientationAnnotations = orientations
        label.sizeAnnotations = sizes
        label.shiftAnnotations = shifts
        label.indentAnnotations = indents
        label.warichuRanges = warichu
        label.boxAnnotations = boxes
        label.horizontalRanges = horizontal
        label.emphasisAnnotations = emphasis
        label.rubyAnnotations = ruby
        label.layoutSubviews()
        return label
    }

    /// まとまりごとに使われているフォントの PostScript 名。
    private func fontNames(_ label: STLabel) -> [String] {
        label.drawBuckets.map { CTFontCopyPostScriptName($0.ctFont) as String }
    }

    // MARK: - 太字・斜体

    @Test func boldUsesAHeavierFace() {
        let plain = makeLabel("ふつうの文字")
        #expect(fontNames(plain) == ["HiraMinProN-W3"])

        let bold = makeLabel("太い文字", styles: [STStyleAnnotation(range: 0..<2, style: .bold)])
        // 太字の部分だけ別のまとまりになり、W6 が使われる
        #expect(Set(fontNames(bold)) == ["HiraMinProN-W3", "HiraMinProN-W6"])
        #expect(bold.context.runs[0].style == .bold)
        #expect(bold.context.runs[2].style == [])
    }

    @Test func sharingAFontBetweenScriptsKeepsJapaneseUpright() {
        // 和欧で書体をそろえるため、同じフォントを日本語とラテン文字の両方に指定することがある。
        // このとき日本語の文字がラテン文字あつかいになって、縦書きで横に倒れてはいけない
        let label = STLabel(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        label.isPaged = true
        label.direction = .tbRl
        label.fontSize = 20
        label.setFontNames(["HiraMinProN-W3", "YuMincho-Medium"], script: .japanese)
        label.setFontNames(["HiraMinProN-W3", "Times-Roman"], script: .latin)
        label.text = "あA"
        label.layoutSubviews()
        let japanese = label.context.runs[0]
        #expect(label.context.fontManager.script(fontId: japanese.fontId) == .japanese)
        #expect(!label.context.isClockwise(run: japanese))
        // ラテン文字のほうは縦書きで倒す
        let latin = label.context.runs[1]
        #expect(label.context.fontManager.script(fontId: latin.fontId) == .latin)
        #expect(label.context.isClockwise(run: latin))
    }

    @Test func italicUsesASlantedFaceForLatin() {
        let label = makeLabel("ab", styles: [STStyleAnnotation(range: 0..<2, style: .italic)])
        #expect(fontNames(label) == ["HelveticaNeue-Italic"])
    }

    @Test func italicFallsBackToUprightForJapanese() {
        // 日本語フォントには斜体が無いので、字面は変わらない
        let label = makeLabel("日本語", styles: [STStyleAnnotation(range: 0..<3, style: .italic)])
        #expect(fontNames(label) == ["HiraMinProN-W3"])
    }

    @Test func overlappingStylesAreCombined() {
        let label = makeLabel("abcd", styles: [
            STStyleAnnotation(range: 0..<3, style: .bold),
            STStyleAnnotation(range: 2..<4, style: .italic),
        ])
        #expect(label.context.runs.map(\.style) == [.bold, .bold, [.bold, .italic], .italic])
        #expect(fontNames(label).contains("HelveticaNeue-BoldItalic"))
    }

    @Test func boldChangesTheAdvanceSoLinesBreakAccordingly() {
        // 太字は字幅が変わるので、組み直しに反映される
        let plain = makeLabel("abcdefghij")
        let bold = makeLabel("abcdefghij", styles: [STStyleAnnotation(range: 0..<10, style: .bold)])
        let plainWidth = plain.context.runs.reduce(CGFloat.zero) { $0 + $1.advance.width }
        let boldWidth = bold.context.runs.reduce(CGFloat.zero) { $0 + $1.advance.width }
        #expect(boldWidth > plainWidth)
    }

    @Test func styleOutsideTheTextIsIgnored() {
        let label = makeLabel("短い", styles: [
            STStyleAnnotation(range: 5..<9, style: .bold),
            STStyleAnnotation(range: 1..<99, style: .bold),
        ])
        #expect(label.context.runs.map(\.style) == [[], .bold])
    }

    // MARK: - 下線

    @Test func underlineDoesNotChangeTheFace() {
        // 下線は字面を変えないので、同じフォントのまとまりのまま
        let label = makeLabel("下線つき", lines: [STLineAnnotation(range: 0..<2)])
        #expect(fontNames(label) == ["HiraMinProN-W3"])
        #expect(label.lineAnnotations.count == 1)
    }

    @Test func underlineIsDrawnBesideTheCharactersInVerticalWriting() {
        let size = CGSize(width: 200, height: 200)
        let plain = render(makeLabel("下線つき", size: size), size: size)
        let underlined = render(
            makeLabel("下線つき", lines: [STLineAnnotation(range: 0..<2)], size: size),
            size: size)
        // 線のぶんだけ墨が増える
        #expect(underlined.lazy.filter { $0 > 0 }.count > plain.lazy.filter { $0 > 0 }.count)

        // 縦書きでは文字の右側に、親文字 2 文字ぶんの長さで引かれる
        let label = makeLabel("下線つき", lines: [STLineAnnotation(range: 0..<2)], size: size)
        let base = label.context.runs[0..<2]
        let column = Int(base.map(\.frame.maxX).max()! - label.rubyExtent + label.lineThickness)
        var rows: [Int] = []
        let width = Int(size.width)
        for y in 0..<Int(size.height) where underlined[(y * width + column) * 4 + 3] > 0 {
            rows.append(y)
        }
        #expect(rows.first.map { abs(Double($0) - base.map(\.frame.minY).min()!) < 2 } == true)
        #expect(rows.last.map { abs(Double($0) - base.map(\.frame.maxY).max()!) < 2 } == true)
    }

    @Test func underlineIsDrawnBelowTheCharactersInHorizontalWriting() {
        let size = CGSize(width: 200, height: 200)
        let label = makeLabel(
            "下線つき", lines: [STLineAnnotation(range: 0..<2)],
            size: size, direction: .lrTb)
        let pixels = render(label, size: size)
        let width = Int(size.width)
        let base = label.context.runs[0..<2]
        // 親文字のすぐ下の行に、親文字の幅ぶんの線がある
        let row = Int(base.map(\.frame.maxY).max()! + label.lineThickness * 1.5)
        let inked = (0..<width).filter { pixels[(row * width + $0) * 4 + 3] > 0 }
        #expect(!inked.isEmpty)
        #expect(abs(Double(inked.first!) - base.map(\.frame.minX).min()!) < 2)
        #expect(abs(Double(inked.last!) - base.map(\.frame.maxX).max()!) < 2)
    }

    @Test func underlineReservesSpaceSoItIsNotClipped() {
        let plain = makeLabel("下線")
        let underlined = makeLabel("下線", lines: [STLineAnnotation(range: 0..<2)])
        #expect(plain.rubyExtent == 0)
        #expect(underlined.rubyExtent > 0)
        // ルビがあるときは、ルビのぶんの空きで足りるので増えない
        let withRuby = makeLabel(
            "下線",
            lines: [STLineAnnotation(range: 0..<2)],
            ruby: [STRubyAnnotation(range: 0..<2, text: "かせん")])
        #expect(abs(withRuby.rubyExtent - 10) < 0.01)
    }

    @Test func underlineIsBrokenPerLine() {
        // 1 行 3 文字の幅で 6 文字に下線を引くと、行ごとに分かれる
        let label = makeLabel(
            "あいうえおか", lines: [STLineAnnotation(range: 0..<6)],
            size: CGSize(width: 200, height: 60))
        #expect(Set(label.context.runs.map(\.line)).count == 2)
        // 行をまたいでも、描かれる線は行ごとに収まっている (高さが 1 行ぶんを超えない)
        let size = CGSize(width: 200, height: 60)
        let pixels = render(label, size: size)
        let width = Int(size.width)
        var inkRows = 0
        for y in 0..<Int(size.height) {
            if (0..<width).contains(where: { pixels[(y * width + $0) * 4 + 3] > 0 }) { inkRows += 1 }
        }
        #expect(inkRows <= Int(size.height))
    }

    @Test func lineStylesAllDrawSomething() {
        // 二重線・点線・破線・波線が、実線と違う見た目で引かれる
        let size = CGSize(width: 200, height: 200)
        var inks: [STLineStyle: Int] = [:]
        for style in STLineStyle.allCases {
            let label = makeLabel(
                "下線つき", lines: [STLineAnnotation(range: 0..<4, style: style)], size: size)
            inks[style] = render(label, size: size).lazy.filter { $0 > 0 }.count
        }
        let plain = render(makeLabel("下線つき", size: size), size: size).lazy.filter { $0 > 0 }.count
        for style in STLineStyle.allCases {
            #expect(inks[style]! > plain)
        }
        // 点線・破線は実線より墨が少なく、二重線は多い
        #expect(inks[.dotted]! < inks[.solid]!)
        #expect(inks[.dashed]! < inks[.solid]!)
        #expect(inks[.double]! > inks[.solid]!)
    }

    @Test func overlineIsDrawnOnTheOppositeSide() {
        let size = CGSize(width: 200, height: 200)
        let label = makeLabel(
            "下線つき", lines: [STLineAnnotation(range: 0..<2, style: .solid, position: .overline)], size: size)
        let pixels = render(label, size: size)
        let width = Int(size.width)
        let base = label.context.runs[0..<2]
        // 縦書きでは左傍線。親文字のすぐ左に墨があり、右には無い
        let left = Int(base.map(\.frame.minX).min()!)
        let right = Int(base.map(\.frame.maxX).max()!)
        func hasInk(_ columns: Range<Int>) -> Bool {
            columns.contains { column in
                column >= 0 && column < width
                    && (0..<Int(size.height)).contains { pixels[($0 * width + column) * 4 + 3] > 0 }
            }
        }
        #expect(hasInk((left - 5)..<left))
        #expect(!hasInk(right..<min(width, right + 5)))
    }

    @Test func strikethroughIsDrawnOverTheCharacters() {
        let size = CGSize(width: 200, height: 200)
        let label = makeLabel(
            "消す", lines: [STLineAnnotation(range: 0..<2, style: .solid, position: .strikethrough)], size: size)
        // 取り消し線は文字に重なるので、行の脇に空きは要らない
        #expect(label.rubyExtent == 0)
        let pixels = render(label, size: size)
        #expect(pixels.lazy.filter { $0 > 0 }.count
            > render(makeLabel("消す", size: size), size: size).lazy.filter { $0 > 0 }.count)
    }

    @Test func emphasisOnTheUnderSideStaysThere() {
        // 青空文庫の「左に傍点」
        let label = makeLabel("大事", emphasis: [STEmphasisAnnotation(range: 0..<2, position: .under)])
        let base = label.context.runs[0..<2]
        #expect(label.rubyRuns.allSatisfy { $0.frame.maxX <= base.map(\.frame.minX).min()! + 0.5 })
    }

    // MARK: - 罫囲み

    @Test func boxSurroundsTheCharacters() {
        let size = CGSize(width: 200, height: 200)
        let label = makeLabel("前囲み後", boxes: [STBoxAnnotation(range: 1..<3)], size: size)
        let pixels = render(label, size: size)
        let width = Int(size.width)

        /// その行 (文字が進む向きの範囲) に墨がある x の幅。
        func inkWidth(rows: Range<Int>) -> Int {
            var minX = width
            var maxX = -1
            for row in rows where row >= 0 && row < Int(size.height) {
                for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 0 {
                    minX = min(minX, column)
                    maxX = max(maxX, column)
                }
            }
            return maxX < minX ? 0 : maxX - minX + 1
        }

        // 囲んだ文字のところは、罫のぶんだけ文字より横に広がる
        let boxed = label.context.runs[1].frame
        let plain = label.context.runs[3].frame
        let boxedWidth = inkWidth(rows: Int(boxed.minY + 3)..<Int(boxed.maxY - 3))
        // 囲みの罫は文字の前後にも少しはみ出すので、そこを避けて見る
        let plainWidth = inkWidth(rows: Int(plain.minY + 8)..<Int(plain.maxY - 2))
        #expect(boxedWidth > plainWidth + 4)
        // 囲みの外にある文字は、文字の幅のまま
        #expect(plainWidth <= Int(plain.width) + 2)
    }

    @Test func boxAcrossLinesIsSplitPerLine() {
        // 1 行に 4〜5 文字しか入らない高さ。10 文字を囲むと何行かにまたがる
        let size = CGSize(width: 200, height: 100)
        let label = makeLabel(
            "あいうえおかきくけこ", boxes: [STBoxAnnotation(range: 0..<10)], size: size)
        #expect(label.layoutedLineCount > 1)
        // 1 つの枠でまとめず、行ごとに 1 つずつ囲む
        let rects = label.boxRects(of: label.boxAnnotations[0])
        #expect(rects.count == label.layoutedLineCount)
        // 縦書きなので行ごとに横へずれ、枠どうしは重ならない
        let sorted = rects.sorted { $0.minX < $1.minX }
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            #expect(left.maxX <= right.minX)
        }
        // どの枠も、その行の文字より外側にある
        for rect in rects {
            let inside = label.context.runs.filter { rect.insetBy(dx: 2, dy: 2).intersects($0.frame) }
            #expect(!inside.isEmpty)
            #expect(inside.allSatisfy { rect.contains($0.frame) })
        }
    }

    @Test func boxOnOneLineStaysASingleFrame() {
        let label = makeLabel("前囲み後", boxes: [STBoxAnnotation(range: 1..<3)])
        #expect(label.boxRects(of: label.boxAnnotations[0]).count == 1)
    }

    @Test func boxReservesSpaceOnBothSides() {
        let plain = makeLabel("囲み")
        let boxed = makeLabel("囲み", boxes: [STBoxAnnotation(range: 0..<2)])
        #expect(plain.rubyExtent == 0)
        #expect(boxed.rubyExtent > 0)
        // 1 ページに入る行数は増えない
        #expect(boxed.linesPerPage <= plain.linesPerPage)
    }

    @Test func boxStylesDrawDifferently() {
        let size = CGSize(width: 200, height: 200)
        var inks: [STLineStyle: Int] = [:]
        for style in [STLineStyle.solid, .dashed, .dotted, .double] {
            let label = makeLabel("囲み", boxes: [STBoxAnnotation(range: 0..<2, style: style)], size: size)
            inks[style] = render(label, size: size).lazy.filter { $0 > 0 }.count
        }
        let plain = render(makeLabel("囲み", size: size), size: size).lazy.filter { $0 > 0 }.count
        for (_, ink) in inks { #expect(ink > plain) }
        #expect(inks[.dashed]! < inks[.solid]!)
        #expect(inks[.double]! > inks[.solid]!)
    }

    // MARK: - 割り注

    @Test func warichuStacksTheTextInTwoRows() {
        // 「注」4 文字を割り注にすると、前 2 文字と後ろ 2 文字が 2 行に並ぶ
        let label = makeLabel("前わりちゅう後", warichu: [1..<5])
        let runs = (1..<5).map { label.context.runs[$0] }
        // 半分の大きさになる
        #expect(runs.allSatisfy { abs($0.fontSize - 10) < 0.5 })
        // 1 行目 (右) と 2 行目 (左) に 2 文字ずつ
        let right = runs.filter { $0.frame.minX > runs.map(\.frame.minX).min()! + 0.5 }
        let left = runs.filter { $0.frame.minX <= runs.map(\.frame.minX).min()! + 0.5 }
        #expect(right.count == 2)
        #expect(left.count == 2)
        // 2 行は本文 1 文字ぶんの幅に収まる
        let base = label.context.runs[0].frame
        #expect(runs.map(\.frame.minX).min()! >= base.minX - 0.5)
        #expect(runs.map(\.frame.maxX).max()! <= base.maxX + 0.5)
        // どちらの行も同じ位置から始まる
        #expect(abs(right.map(\.frame.minY).min()! - left.map(\.frame.minY).min()!) < 0.5)
    }

    @Test func warichuTakesHalfTheRoomAlongTheLine() {
        // 4 文字の割り注は、2 行に積むので本文 2 文字ぶんの長さで済む
        let plain = makeLabel("前わりちゅう後")
        let label = makeLabel("前わりちゅう後", warichu: [1..<5])
        let after = label.context.runs[5]
        #expect(abs(after.frame.minY - (label.context.runs[0].frame.maxY + 20)) < 1)
        // ふつうに組むより後ろの文字が前に来る
        #expect(after.frame.minY < plain.context.runs[5].frame.minY)
    }

    @Test func warichuWithAnOddCountPutsTheExtraOnTheFirstRow() {
        let label = makeLabel("前わりちゅ後", warichu: [1..<4])
        let runs = (1..<4).map { label.context.runs[$0] }
        let minX = runs.map(\.frame.minX).min()!
        #expect(runs.filter { $0.frame.minX > minX + 0.5 }.count == 2)
        #expect(runs.filter { $0.frame.minX <= minX + 0.5 }.count == 1)
    }

    @Test func warichuIsLeftAloneWhenItCrossesALineBreak() {
        // 行をまたぐと読み順が崩れるので積まない
        let size = CGSize(width: 400, height: 40)
        let label = makeLabel("あいうえお", warichu: [0..<5], size: size)
        #expect(Set(label.context.runs.map(\.line)).count > 1)
        // すべて同じ位置 (行の幅の中央) に並んだまま
        let xs = Set(label.context.runs.map { ($0.frame.minX * 10).rounded() })
        #expect(xs.count == Set(label.context.runs.map(\.line)).count)
    }

    // MARK: - 縦組み中の横組み

    /// 縦組みの本文に、横組みのブロックを 1 つ挟んだもの。
    private func makeHorizontalSample(
        direction: STDirection = .tbRl, size: CGSize = CGSize(width: 300, height: 300)
    ) -> (label: STLabel, block: Range<Int>) {
        let before = "たてぐみのほんぶん。\n"
        let block = "よこぐみのぶろっく。\n"
        let after = "またたてぐみにもどる。"
        let range = before.count..<(before.count + block.count - 1)
        let label = makeLabel(
            before + block + after, horizontal: [range], size: size, direction: direction)
        return (label, range)
    }

    @Test func horizontalBlockTakesAPageOfItsOwn() {
        let (label, range) = makeHorizontalSample()
        #expect(label.horizontalBlockRanges == [range])
        // 横組みのブロックは別の STLabel に横書きで組まれる
        let block = try! #require(label.horizontalLabels.first)
        #expect(block.text == "よこぐみのぶろっく。")
        #expect(block.direction == .lrTb)
        // ブロックだけのページができる
        let index = try! #require(label.pages.firstIndex(of: .horizontal(block: 0, page: 0)))
        #expect(index > 0)
        #expect(index < label.pageCount - 1)
    }

    @Test func horizontalBlockIsNotDrawnWithTheVerticalText() {
        let (label, range) = makeHorizontalSample()
        // 縦組みのページには、ブロックの文字は出ない
        for page in 0..<label.pageCount {
            label.pageIndex = page
            guard case .text(let lines) = label.pages[page] else {
                // 横組みのページでは親は何も描かない (子ビューが描く)
                #expect(label.drawBuckets.isEmpty)
                continue
            }
            for offset in range {
                #expect(!lines.contains(label.context.runs[offset].line))
            }
        }
    }

    @Test func horizontalBlockLeadsToItsOwnPage() {
        let (label, range) = makeHorizontalSample()
        let index = try! #require(label.pages.firstIndex(of: .horizontal(block: 0, page: 0)))
        // ブロックの中の文字は、そのブロックのページとして引ける
        #expect(label.page(ofCharacterAt: range.lowerBound) == index)
        #expect(label.page(ofCharacterAt: range.upperBound - 1) == index)
        // 前後の本文は縦組みのページのまま
        #expect(label.page(ofCharacterAt: 0) < index)
        #expect(label.page(ofCharacterAt: range.upperBound + 1) > index)
    }

    @Test func horizontalBlockDoesNothingInHorizontalText() {
        // 横書き表示では本文全体が横組みなので、ブロックを分ける必要が無い
        let (label, _) = makeHorizontalSample(direction: .lrTb)
        #expect(label.horizontalLabels.isEmpty)
        #expect(!label.pages.contains { if case .horizontal = $0 { return true } else { return false } })
    }

    // MARK: - 上付き・下付き

    @Test func superscriptMovesTheSmallCharacterToTheSideOfTheLine() {
        // 縦書きでは上付きが行の右、下付きが行の左。文字は 20pt、小文字は 12pt なので
        // 枠の中央にそろえたところから左右へ 4pt ずつ動く
        let small = [STSizeAnnotation(range: 1..<2, scale: 0.6)]
        let centered = makeLabel("あいう", sizes: small)
        let up = makeLabel(
            "あいう", sizes: small, shifts: [STShiftAnnotation(range: 1..<2, side: .over)])
        let down = makeLabel(
            "あいう", sizes: small, shifts: [STShiftAnnotation(range: 1..<2, side: .under)])
        #expect(abs(up.context.runs[1].frame.minX - (centered.context.runs[1].frame.minX + 4)) < 0.5)
        #expect(abs(down.context.runs[1].frame.minX - (centered.context.runs[1].frame.minX - 4)) < 0.5)
        // ふつうの大きさの文字の枠からははみ出さない
        #expect(up.context.runs[1].frame.maxX <= up.context.runs[0].frame.maxX + 0.5)
        #expect(down.context.runs[1].frame.minX >= down.context.runs[0].frame.minX - 0.5)
    }

    @Test func superscriptIsRaisedInHorizontalText() {
        // 横書きでは上付きが上、下付きが下
        let small = [STSizeAnnotation(range: 1..<2, scale: 0.6)]
        let base = makeLabel("あいう", sizes: small, direction: .lrTb)
        let up = makeLabel(
            "あいう", sizes: small, shifts: [STShiftAnnotation(range: 1..<2, side: .over)],
            direction: .lrTb)
        let down = makeLabel(
            "あいう", sizes: small, shifts: [STShiftAnnotation(range: 1..<2, side: .under)],
            direction: .lrTb)
        // ベースラインが小さくしたぶんの半分 (4pt) だけ上下する
        #expect(abs(up.context.runs[1].frame.minY - (base.context.runs[1].frame.minY - 4)) < 0.5)
        #expect(abs(down.context.runs[1].frame.minY - (base.context.runs[1].frame.minY + 4)) < 0.5)
        // 上付きはふつうの大きさの文字の上端より上には出ない
        #expect(up.context.runs[1].frame.minY >= up.context.runs[0].frame.minY - 0.5)
    }

    @Test func superscriptDoesNotMoveFullSizeCharacters() {
        // 小さくしていない文字は、寄せ先が無いので動かない
        let plain = makeLabel("あいう")
        let shifted = makeLabel("あいう", shifts: [STShiftAnnotation(range: 1..<2, side: .over)])
        #expect(plain.context.runs[1].frame == shifted.context.runs[1].frame)
    }

    // MARK: - 字下げ・地付き

    @Test func indentMovesTheStartOfTheLine() {
        let plain = makeLabel("あいうえお")
        let indented = makeLabel("あいうえお", indents: [STIndentAnnotation(range: 0..<5, head: 3)])
        // 縦書きなので行の始まり (上) に 3 文字ぶん空く
        #expect(abs(plain.context.runs[0].frame.minY - 0) < 0.5)
        #expect(abs(indented.context.runs[0].frame.minY - 60) < 0.5)
    }

    @Test func indentAppliesToEveryLineOfTheBlock() {
        // 1 行 5 文字ぶんの高さ。3 字下げすると 1 行 2 文字になり、どの行も同じ位置から始まる
        let size = CGSize(width: 400, height: 100)
        let label = makeLabel(
            "あいうえおかきく", indents: [STIndentAnnotation(range: 0..<8, head: 3)], size: size)
        #expect(label.layoutedLineCount > 1)
        for line in 0..<label.layoutedLineCount {
            let first = label.context.runs.first { $0.line == line }!
            #expect(abs(first.frame.minY - 60) < 0.5)
        }
    }

    @Test func indentOnlyAppliesWhereItIsAsked() {
        // 2 段落目だけ字下げする
        let text = "あい\nうえ"
        let label = makeLabel(text, indents: [STIndentAnnotation(range: 3..<5, head: 2)])
        #expect(abs(label.context.runs[0].frame.minY - 0) < 0.5)
        #expect(abs(label.context.runs[3].frame.minY - 40) < 0.5)
    }

    @Test func hangingIndentOnlyMovesTheWrappedLines() {
        // 「ここから1字下げ、折り返して3字下げ」。1 行 5 文字ぶんの高さ
        let size = CGSize(width: 400, height: 100)
        let label = makeLabel(
            "あいうえおかきくけこ",
            indents: [STIndentAnnotation(range: 0..<10, head: 1, hanging: 3)], size: size)
        #expect(label.layoutedLineCount > 1)
        // 1 行目は 1 字下げ、折り返した行は 3 字下げ
        #expect(abs(label.context.runs[0].frame.minY - 20) < 0.5)
        for line in 1..<label.layoutedLineCount {
            let first = label.context.runs.first { $0.line == line }!
            #expect(abs(first.frame.minY - 60) < 0.5)
        }
    }

    @Test func hangingIndentStartsEveryParagraphAtTheHeadIndent() {
        // 折り返しではなく改行で始まる行は、1 行目と同じ字下げになる
        let label = makeLabel(
            "あい\nうえ", indents: [STIndentAnnotation(range: 0..<5, head: 1, hanging: 3)])
        #expect(abs(label.context.runs[0].frame.minY - 20) < 0.5)
        #expect(abs(label.context.runs[3].frame.minY - 20) < 0.5)
    }

    @Test func lineLengthShortensTheLine() {
        // 字詰め: 1 行に入る文字数を決める。1 行 10 文字ぶんの高さに 4 字詰めを指定する
        let size = CGSize(width: 400, height: 200)
        let text = "あいうえおかきくけこさしすせそ"
        let plain = makeLabel(text, size: size)
        #expect(plain.layoutedLineCount == 2)
        let packed = makeLabel(
            text, indents: [STIndentAnnotation(range: 0..<text.count, length: 4)], size: size)
        // どの行も 4 文字までで折り返す
        for line in 0..<packed.layoutedLineCount {
            let runs = packed.context.runs.filter { $0.line == line }
            #expect(runs.count <= 4)
            #expect(runs.last!.frame.maxY <= 80.5)
        }
        #expect(packed.layoutedLineCount == 4)
    }

    @Test func lineLengthIsMeasuredFromTheIndent() {
        // 字下げと組み合わせると、字下げのあとから字詰めのぶんを数える。
        // 2 字下げ + 3 字詰めなら、どの行も 2 文字目から 4 文字目までに収まる
        let size = CGSize(width: 400, height: 200)
        let text = "あいうえおかきくけこ"
        let label = makeLabel(
            text, indents: [STIndentAnnotation(range: 0..<text.count, head: 2, length: 3)], size: size)
        #expect(label.layoutedLineCount > 1)
        var reachesTheEnd = false
        for line in 0..<label.layoutedLineCount {
            let runs = label.context.runs.filter { $0.line == line }
            #expect(abs(runs.first!.frame.minY - 40) < 0.5)
            #expect(runs.last!.frame.maxY <= 100.5)
            if runs.last!.frame.maxY > 99.5 { reachesTheEnd = true }
        }
        // 短くしすぎてもいない
        #expect(reachesTheEnd)
    }

    @Test func lineLengthDoesNotReachBeyondTheView() {
        // 表示領域より長い字詰めを指定しても、表示領域からははみ出さない
        let size = CGSize(width: 400, height: 100)
        let text = "あいうえおかきくけこ"
        let plain = makeLabel(text, size: size)
        let wide = makeLabel(
            text, indents: [STIndentAnnotation(range: 0..<text.count, length: 40)], size: size)
        #expect(wide.layoutedLineCount == plain.layoutedLineCount)
    }

    @Test func centeredLinesAreCenteredInTheColumn() {
        // text-align: center。縦書きなので行の中で上下の中央にそろう
        let size = CGSize(width: 400, height: 200)
        let plain = makeLabel("題名", size: size)
        let centered = makeLabel(
            "題名", indents: [STIndentAnnotation(range: 0..<2, centered: true)], size: size)
        #expect(abs(plain.context.runs[0].frame.minY - 0) < 0.5)
        // 2 文字 = 40pt なので (200 - 40) / 2 = 80pt ずれる
        #expect(abs(centered.context.runs[0].frame.minY - 80) < 0.5)
        #expect(abs(centered.context.runs[1].frame.maxY - 120) < 0.5)
    }

    @Test func trailingAlignmentPushesTheLineToTheEnd() {
        // 地付き: 行の終わりにそろえる
        let size = CGSize(width: 400, height: 200)
        let label = makeLabel("署名", indents: [STIndentAnnotation(range: 0..<2, tail: 0)], size: size)
        #expect(abs(label.context.runs[1].frame.maxY - 200) < 0.5)
    }

    @Test func trailingAlignmentCanLeaveAGap() {
        // 地から 2 字上げ
        let size = CGSize(width: 400, height: 200)
        let label = makeLabel("署名", indents: [STIndentAnnotation(range: 0..<2, tail: 2)], size: size)
        #expect(abs(label.context.runs[1].frame.maxY - 160) < 0.5)
    }

    @Test func trailingLinesWrapBeforeTheGap() {
        // 地寄せの行は、空けるぶんだけ早く折り返す
        let size = CGSize(width: 400, height: 100)
        let plain = makeLabel("あいうえお", size: size)
        #expect(plain.layoutedLineCount == 1)
        let tailed = makeLabel("あいうえお", indents: [STIndentAnnotation(range: 0..<5, tail: 2)], size: size)
        #expect(tailed.layoutedLineCount == 2)
    }

    // MARK: - 文字の大きさ

    @Test func biggerCharactersTakeMoreRoomAlongTheLine() {
        let plain = makeLabel("あいうえお")
        let bigger = makeLabel("あいうえお", sizes: [STSizeAnnotation(range: 1..<3, scale: 1.5)])
        // 指定した文字だけ大きくなる
        #expect(abs(bigger.context.runs[1].fontSize - 30) < 0.5)
        #expect(abs(bigger.context.runs[0].fontSize - 20) < 0.5)
        #expect(abs(bigger.context.runs[1].frame.height - 30) < 0.5)
        // 後ろの文字はそのぶん先へずれる
        #expect(abs(bigger.context.runs[3].frame.minY - (plain.context.runs[3].frame.minY + 20)) < 0.5)
    }

    @Test func smallerCharactersAreCenteredInTheColumn() {
        let label = makeLabel("あいう", sizes: [STSizeAnnotation(range: 1..<2, scale: 0.5)])
        let full = label.context.runs[0].frame
        let small = label.context.runs[1].frame
        #expect(abs(small.height - 10) < 0.5)
        // 縦書きでは、小さい文字は 1 文字ぶんの枠の中央に来る
        #expect(abs(small.midX - full.midX) < 0.5)
        #expect(small.minX > full.minX)
    }

    @Test func sizeChangesLineBreaking() {
        // 1 行 5 文字ぶんの高さ。1 文字を 2 倍にすると 1 文字ぶん早く折り返す
        let size = CGSize(width: 400, height: 100)
        let plain = makeLabel("あいうえお", size: size)
        #expect(plain.layoutedLineCount == 1)
        let bigger = makeLabel("あいうえお", sizes: [STSizeAnnotation(range: 0..<1, scale: 2)], size: size)
        #expect(bigger.layoutedLineCount == 2)
    }

    @Test func sizeIsCappedToTheLineHeight() {
        // 行送りより大きくすると隣の行とぶつかるので、頭打ちにする (行送り 1.9 倍)
        let label = makeLabel("大", sizes: [STSizeAnnotation(range: 0..<1, scale: 5)])
        #expect(abs(label.context.runs[0].fontSize - 20 * 1.9) < 0.5)
    }

    @Test func biggerCharactersUseABiggerFontWhenDrawn() {
        let label = makeLabel("あいう", sizes: [STSizeAnnotation(range: 1..<2, scale: 1.5)])
        let sizes = Set(label.drawBuckets.map { CTFontGetSize($0.ctFont) })
        #expect(sizes.count == 2)
        #expect(sizes.contains { abs($0 - 30) < 0.5 })
    }

    // MARK: - 縦中横

    @Test func tateChuYokoPutsCharactersUprightSideBySide() {
        // 欧文の 2 文字は、ふつうは 90 度回転して縦に並ぶ
        let plain = makeLabel("昭和ab年")
        #expect(plain.context.isClockwise(run: plain.context.runs[2]))
        // 縦中横にすると回転せず、2 文字が同じ高さに並ぶ
        let tcy = makeLabel("昭和ab年", tateChuYoko: [2..<4])
        #expect(!tcy.context.isClockwise(run: tcy.context.runs[2]))
        #expect(abs(tcy.context.runs[2].frame.minY - tcy.context.runs[3].frame.minY) < 0.5)
        // 次の文字は 1 文字ぶんだけ先に来る
        #expect(abs(tcy.context.runs[4].frame.minY - (tcy.context.runs[2].frame.minY + 20)) < 0.5)
        // そのぶん行は短くなる
        #expect(tcy.context.runs[4].frame.minY < plain.context.runs[4].frame.minY)
    }

    @Test func twoDigitNumbersAreAlreadyUprightWithoutTheAnnotation() {
        // 2 桁の数字はエンジンが自動で縦中横にする (注記が無くても同じ)
        let label = makeLabel("昭和30年")
        #expect(label.context.isTateChuYoko(run: label.context.runs[2]))
    }

    @Test func digitsInsideALatinWordStayWithTheLatin() {
        // 欧文の語や式の中の数字を正立させると、隣の欧文だけが倒れてちぐはぐになる。
        // H2O の 2、x2 の 2 は、まわりの欧文と同じく倒す
        let label = makeLabel("H2O と x2 と 30年")
        #expect(!label.context.isTateChuYoko(run: label.context.runs[1]))
        #expect(label.context.isClockwise(run: label.context.runs[1]))
        #expect(!label.context.isTateChuYoko(run: label.context.runs[7]))
        // 日本語の文の中の数字は、これまでどおり縦中横にする
        #expect(label.context.isTateChuYoko(run: label.context.runs[11]))
    }

    @Test func tooLongTateChuYokoIsLeftAsItIs() {
        // 1 文字ぶんに収まらない長さは、横に並べると隣の行にはみ出すのでそのままにする
        let label = makeLabel("昭和1000年", tateChuYoko: [2..<6])
        #expect(!label.context.isTateChuYoko(run: label.context.runs[2]))
        #expect(label.context.isClockwise(run: label.context.runs[2]))
    }

    @Test func tateChuYokoDoesNothingInHorizontalWriting() {
        let label = makeLabel(
            "昭和30年", tateChuYoko: [2..<4], size: CGSize(width: 400, height: 300), direction: .lrTb)
        #expect(!label.context.isTateChuYoko(run: label.context.runs[2]))
    }

    // MARK: - 文字の向き

    @Test func uprightKeepsLatinStandingInVerticalText() {
        // 欧文はふつう縦組みで倒れるが、upright を指定すると正立する
        let plain = makeLabel("あAい")
        #expect(plain.context.isClockwise(run: plain.context.runs[1]))
        let upright = makeLabel(
            "あAい", orientations: [STOrientationAnnotation(range: 1..<2, orientation: .upright)])
        #expect(!upright.context.isClockwise(run: upright.context.runs[1]))
    }

    @Test func uprightCentersANarrowGlyphInTheLine() {
        // 半角の文字でも 1 文字ぶんの枠の中央にそろえる
        let label = makeLabel(
            "あAい", orientations: [STOrientationAnnotation(range: 1..<2, orientation: .upright)])
        let cell = label.context.runs[0].frame
        let narrow = label.context.runs[1].frame
        #expect(narrow.width < cell.width)
        #expect(abs(narrow.midX - cell.midX) < 0.5)
    }

    @Test func sidewaysLaysJapaneseDown() {
        // 和文はふつう正立するが、sideways を指定すると倒れる
        let plain = makeLabel("「あ」")
        #expect(!plain.context.isClockwise(run: plain.context.runs[0]))
        let sideways = makeLabel(
            "「あ」", orientations: [STOrientationAnnotation(range: 0..<1, orientation: .sideways)])
        #expect(sideways.context.isClockwise(run: sideways.context.runs[0]))
        // 倒すときは縦書き用の字形 (﹁) に替えない
        #expect(sideways.context.runs[0].glyph != plain.context.runs[0].glyph)
    }

    @Test func orientationDoesNothingInHorizontalWriting() {
        let label = makeLabel(
            "あAい", orientations: [STOrientationAnnotation(range: 0..<1, orientation: .sideways)],
            size: CGSize(width: 400, height: 300), direction: .lrTb)
        #expect(!label.context.isClockwise(run: label.context.runs[0]))
    }

    // MARK: - 圏点

    @Test func emphasisPutsAMarkOnEveryCharacter() {
        let label = makeLabel("とても大事です", emphasis: [STEmphasisAnnotation(range: 2..<4)])
        // 「大」「事」に 1 つずつ
        #expect(label.rubyRuns.count == 2)
        let base = label.context.runs[2..<4]
        // 縦書きなので親文字の右、1 文字ずつの中央にそろう
        #expect(label.rubyRuns.allSatisfy { $0.frame.minX >= base.map(\.frame.maxX).max()! - 0.5 })
        for (mark, baseRun) in zip(label.rubyRuns, base) {
            #expect(abs(mark.frame.midY - baseRun.frame.midY) < 0.5)
        }
    }

    @Test func emphasisDoesNotWidenTheBase() {
        let plain = makeLabel("大事")
        let marked = makeLabel("大事", emphasis: [STEmphasisAnnotation(range: 0..<2)])
        #expect(marked.context.runs.map(\.frame.height) == plain.context.runs.map(\.frame.height))
    }

    @Test func emphasisMovesToTheOtherSideWhenThereIsRubyOverIt() {
        let label = makeLabel(
            "漢字",
            emphasis: [STEmphasisAnnotation(range: 0..<2)],
            ruby: [STRubyAnnotation(range: 0..<2, text: "かんじ")])
        let base = label.context.runs[0..<2]
        let right = label.rubyRuns.filter { $0.frame.minX >= base.map(\.frame.maxX).max()! - 0.5 }
        let left = label.rubyRuns.filter { $0.frame.maxX <= base.map(\.frame.minX).min()! + 0.5 }
        // ルビは右のまま、圏点は左へ逃げる
        #expect(right.count == 3)
        #expect(left.count == 2)
    }

    @Test func emphasisReservesSpaceLikeRuby() {
        let plain = makeLabel("大事")
        let marked = makeLabel("大事", emphasis: [STEmphasisAnnotation(range: 0..<2)])
        #expect(plain.rubyExtent == 0)
        #expect(abs(marked.rubyExtent - 10) < 0.01)
        #expect(marked.drawnRubyFrames.allSatisfy { $0.maxX <= marked.bounds.maxX + 0.5 })
    }

    @Test func emphasisInkIsCenteredOnEachCharacter() {
        // 枠ではなく、実際に描かれた墨が親文字の中心に来ているかを見る
        let size = CGSize(width: 120, height: 120)
        let label = makeLabel("大事", emphasis: [STEmphasisAnnotation(range: 0..<2)], size: size)
        label.fontSize = 40
        label.layoutSubviews()
        let pixels = render(label, size: size)
        let width = Int(size.width)

        // 圏点が描かれている帯 (親文字の右) だけを見る
        let band = label.drawnRubyFrames.reduce(CGRect.null) { $0.union($1) }
        for run in label.context.runs {
            var sum = 0.0
            var weight = 0.0
            for y in Int(run.frame.minY)..<Int(run.frame.maxY) {
                for x in Int(band.minX)..<Int(band.maxX.rounded(.up)) {
                    let alpha = Double(pixels[(y * width + x) * 4 + 3])
                    sum += alpha * Double(y)
                    weight += alpha
                }
            }
            #expect(weight > 0)
            #expect(abs(sum / weight - run.frame.midY) < 1)
        }
    }

    @Test func emphasisIsDrawnAndAddsInk() {
        let size = CGSize(width: 400, height: 600)
        let plain = render(makeLabel("大事な話", size: size), size: size)
        let marked = render(makeLabel("大事な話", emphasis: [STEmphasisAnnotation(range: 0..<2)], size: size), size: size)
        #expect(marked.lazy.filter { $0 > 0 }.count > plain.lazy.filter { $0 > 0 }.count)
    }

    private func render(_ label: STLabel, size: CGSize) -> [UInt8] {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context else { return pixels }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        label.draw(CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        label.draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        #endif
        guard let data = context.data else { return [] }
        return Array(UnsafeRawBufferPointer(start: data, count: context.bytesPerRow * context.height)
            .bindMemory(to: UInt8.self))
    }
}
