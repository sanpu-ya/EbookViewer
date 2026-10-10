import Testing
import CoreGraphics
@testable import StoneEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// ルビ (振り仮名) の組版。
@MainActor
struct RubyTests {
    private func makeLabel(
        _ text: String,
        ruby: [STRubyAnnotation],
        size: CGSize = CGSize(width: 400, height: 600),
        direction: STDirection = .tbRl,
        overhang: Bool = true
    ) -> STLabel {
        let label = STLabel(frame: CGRect(origin: .zero, size: size))
        label.isPaged = true
        label.allowsRubyOverhang = overhang
        label.direction = direction
        label.fontSize = 20
        label.lineHeightScale = 1.9
        label.punctuationMode = .stone
        label.setFontNames(["HiraMinProN-W3"], script: .japanese)
        label.text = text
        label.rubyAnnotations = ruby
        label.layoutSubviews()
        return label
    }

    @Test func rubySitsToTheRightOfItsBaseInVerticalWriting() {
        let label = makeLabel("吾輩は猫である", ruby: [STRubyAnnotation(range: 0..<2, text: "わがはい")])
        let runs = label.rubyRuns
        #expect(runs.count == 4)

        // 親文字「吾輩」の右隣に、親文字の半分の大きさで並ぶ
        let base = label.context.runs[0..<2]
        let baseRight = base.map(\.frame.maxX).max()!
        #expect(runs.allSatisfy { abs($0.frame.minX - baseRight) < 0.5 })
        #expect(runs.allSatisfy { abs($0.frame.width - 10) < 1.5 })

        // 親文字の範囲の中央にそろう
        let baseMid = (base.map(\.frame.minY).min()! + base.map(\.frame.maxY).max()!) * 0.5
        let rubyMid = (runs.map(\.frame.minY).min()! + runs.map(\.frame.maxY).max()!) * 0.5
        #expect(abs(baseMid - rubyMid) < 0.5)
    }

    @Test func rubySitsAboveItsBaseInHorizontalWriting() {
        let label = makeLabel(
            "吾輩は猫である", ruby: [STRubyAnnotation(range: 0..<2, text: "わがはい")],
            size: CGSize(width: 600, height: 400), direction: .lrTb)
        let runs = label.rubyRuns
        #expect(runs.count == 4)

        let base = label.context.runs[0..<2]
        let baseTop = base.map(\.frame.minY).min()!
        let rubyBottom = runs.map(\.frame.maxY).max()!
        #expect(abs(rubyBottom - baseTop) < 0.5)

        let baseMid = (base.map(\.frame.minX).min()! + base.map(\.frame.maxX).max()!) * 0.5
        let rubyMid = (runs.map(\.frame.minX).min()! + runs.map(\.frame.maxX).max()!) * 0.5
        #expect(abs(baseMid - rubyMid) < 0.5)
    }

    @Test func rubyIsReservedSoTheFirstLineIsNotClipped() {
        let plain = makeLabel("吾輩は猫である", ruby: [])
        let withRuby = makeLabel("吾輩は猫である", ruby: [STRubyAnnotation(range: 0..<2, text: "わがはい")])
        #expect(plain.rubyExtent == 0)
        #expect(abs(withRuby.rubyExtent - 10) < 0.01)
        // ルビのぶん 1 行あたりの幅が要るので、1 ページに入る行数は減る
        #expect(withRuby.linesPerPage <= plain.linesPerPage)
        // 1 行目のルビが右端の内側に収まっている
        let drawn = withRuby.drawnRubyFrames
        #expect(!drawn.isEmpty)
        #expect(drawn.allSatisfy { $0.maxX <= withRuby.bounds.maxX + 0.5 })
        #expect(drawn.allSatisfy { $0.minX >= 0 })
    }

    @Test func rubyIsSplitWhenItsBaseCrossesALineBreak() {
        // 1 行が 3 文字しか入らない幅にして、親文字 4 文字を行またぎにする
        let label = makeLabel(
            "あいう漢字熟語かきく", ruby: [STRubyAnnotation(range: 3..<7, text: "かんじじゅくご")],
            size: CGSize(width: 400, height: 60))
        let lines = Set(label.context.runs[3..<7].map(\.line))
        #expect(lines.count > 1)
        // ルビも親文字と同じ行に分かれて付く
        let rubyLines = Set(label.rubyRuns.map(\.line))
        #expect(rubyLines == lines)
        // 文字を落としていない
        #expect(label.rubyRuns.count == 7)
    }

    @Test func widensTheBaseToFitALongerRuby() {
        // 親文字 1 文字 (20pt) に 5 文字のルビ (5 * 10 = 50pt) を振る (掛けは切って広げ方だけを見る)
        let label = makeLabel("承る", ruby: [STRubyAnnotation(range: 0..<1, text: "うけたまわ")], overhang: false)
        let base = label.context.runs[0]
        // 親文字の占める長さがルビに合わせて広がる
        #expect(abs(base.frame.height - 50) < 1)
        // 文字そのものは広がった枠の中央に来る (外側の空きは内側の半分 = ここでは前後に 15pt ずつ)
        let glyphTop = base.frame.minY + 15
        #expect(abs(base.position.y - (glyphTop + 20 - label.context.fontManager.descent(fontId: base.fontId, size: 20))) < 0.5)
        // ルビと親文字の長さがそろう
        let ruby = label.rubyRuns
        #expect(abs((ruby.map(\.frame.maxY).max()! - ruby.map(\.frame.minY).min()!) - base.frame.height) < 1)
        #expect(abs(ruby.map(\.frame.minY).min()! - base.frame.minY) < 1)
    }

    @Test func widenedBaseShiftsTheFollowingText() {
        let plain = makeLabel("承る", ruby: [], overhang: false)
        let widened = makeLabel("承る", ruby: [STRubyAnnotation(range: 0..<1, text: "うけたまわ")], overhang: false)
        // 「る」は広がったぶんだけ後ろにずれる
        #expect(abs(widened.context.runs[1].frame.minY - plain.context.runs[1].frame.minY - 30) < 1)
    }

    @Test func doesNotWidenWhenRubyFits() {
        // 2 文字の親文字 (40pt) に 4 文字のルビ (40pt) ならそのまま
        let plain = makeLabel("寝静った", ruby: [])
        let label = makeLabel("寝静った", ruby: [STRubyAnnotation(range: 0..<2, text: "ねしずま")])
        #expect(label.context.runs.map(\.frame.height) == plain.context.runs.map(\.frame.height))
    }

    @Test func widenedBaseIsCountedWhenBreakingLines() {
        // 1 行 60pt (3 文字) の幅に「承る」。親文字が 50pt に広がるので「る」は次の行へ送られる
        let text = "承る"
        let ruby = [STRubyAnnotation(range: 0..<1, text: "うけたまわ")]
        #expect(makeLabel(text, ruby: [], size: CGSize(width: 400, height: 60)).layoutedLineCount == 1)
        let widened = makeLabel(text, ruby: ruby, size: CGSize(width: 400, height: 60), overhang: false)
        #expect(widened.layoutedLineCount == 2)
        #expect(widened.context.runs[1].line == 1)
    }

    // MARK: - ルビの掛け

    @Test func rubyHangsOverAdjacentKana() {
        // 「承」(20pt) に 5 文字のルビ (50pt)。隣の「る」は仮名なので 1 文字ぶん (10pt) 掛けられる
        let label = makeLabel("承る", ruby: [STRubyAnnotation(range: 0..<1, text: "うけたまわ")])
        let base = label.context.runs[0]
        // 掛けたぶんだけ親文字を広げずに済む (50 - 10 = 40)
        #expect(abs(base.frame.height - 40) < 1)
        // ルビは親文字の末尾から 10pt はみ出す
        let ruby = label.rubyRuns
        #expect(abs(ruby.map(\.frame.minY).min()! - base.frame.minY) < 1)
        #expect(abs(ruby.map(\.frame.maxY).max()! - (base.frame.maxY + 10)) < 1)
    }

    @Test func rubyHangsOverKanaOnBothSides() {
        let label = makeLabel("は承る", ruby: [STRubyAnnotation(range: 1..<2, text: "うけたまわ")])
        let base = label.context.runs[1]
        // 前後に 10pt ずつ掛けられるので、広げるのは 10pt だけ
        #expect(abs(base.frame.height - 30) < 1)
        let ruby = label.rubyRuns
        #expect(abs(ruby.map(\.frame.minY).min()! - (base.frame.minY - 10)) < 1)
        #expect(abs(ruby.map(\.frame.maxY).max()! - (base.frame.maxY + 10)) < 1)
    }

    @Test func rubyDoesNotHangOverKanji() {
        // 隣が漢字なら掛けない (JIS X 4051)
        let label = makeLabel("承認", ruby: [STRubyAnnotation(range: 0..<1, text: "うけたまわ")])
        #expect(abs(label.context.runs[0].frame.height - 50) < 1)
    }

    @Test func rubyDoesNotHangOverAnotherRuby() {
        // 隣にもルビが付いていたら掛けない
        let label = makeLabel("承る", ruby: [
            STRubyAnnotation(range: 0..<1, text: "うけたまわ"),
            STRubyAnnotation(range: 1..<2, text: "る"),
        ])
        #expect(abs(label.context.runs[0].frame.height - 50) < 1)
    }

    @Test func rubyDoesNotHangAcrossALineBreak() {
        // 1 行 3 文字。「承」は 2 行目の先頭なので、1 行目の「う」には掛けられない
        let label = makeLabel("あいう承", ruby: [STRubyAnnotation(range: 3..<4, text: "うけたまわ")],
                              size: CGSize(width: 400, height: 60))
        #expect(label.context.runs[3].line != label.context.runs[2].line)
        // 掛けられないので、ルビの長さぶん親文字を広げる
        #expect(abs(label.context.runs[3].frame.height - 50) < 1)
        // ルビは親文字の範囲に収まる
        let ruby = label.rubyRuns
        #expect(abs(ruby.map(\.frame.minY).min()! - label.context.runs[3].frame.minY) < 1)
    }

    @Test func overhangCanBeTurnedOff() {
        let on = makeLabel("承る", ruby: [STRubyAnnotation(range: 0..<1, text: "うけたまわ")])
        let off = makeLabel("承る", ruby: [STRubyAnnotation(range: 0..<1, text: "うけたまわ")], overhang: false)
        #expect(on.context.runs[0].frame.height < off.context.runs[0].frame.height)
    }

    @Test func longRubyStaysInsideTheLine() {
        // 行頭の 1 文字に長いルビを振っても、行の外へはみ出さない
        let label = makeLabel("鬱です", ruby: [STRubyAnnotation(range: 0..<1, text: "うつうつうつ")])
        let runs = label.rubyRuns
        #expect(!runs.isEmpty)
        #expect(runs.map(\.frame.minY).min()! >= -0.5)
        #expect(runs.map(\.frame.maxY).max()! <= label.bounds.height + 0.5)
    }

    @Test func ignoresOutOfRangeAndEmptyAnnotations() {
        let label = makeLabel("短い", ruby: [
            STRubyAnnotation(range: 0..<1, text: ""),            // ルビが空
            STRubyAnnotation(range: 5..<9, text: "はみだし"),      // 親文字が範囲外
            STRubyAnnotation(range: 1..<99, text: "みじ"),        // 末尾が範囲外 (切り詰めて使う)
        ])
        #expect(label.rubyRuns.count == 2)
    }

    @Test func rubyIsDrawnAndAddsInk() {
        let size = CGSize(width: 400, height: 600)
        let text = "吾輩は猫である"
        let plain = render(makeLabel(text, ruby: [], size: size), size: size)
        let withRuby = render(
            makeLabel(text, ruby: [STRubyAnnotation(range: 0..<2, text: "わがはい")], size: size), size: size)
        let plainInk = plain.lazy.filter { $0 > 0 }.count
        let rubyInk = withRuby.lazy.filter { $0 > 0 }.count
        #expect(plainInk > 0)
        // ルビのぶんだけ描かれる量が増える
        #expect(rubyInk > plainInk)
    }

    // MARK: - 二段ルビ

    @Test func secondLevelRubySitsOnTheOppositeSideInVerticalWriting() {
        let label = makeLabel("漢字です", ruby: [
            STRubyAnnotation(range: 0..<2, text: "かんじ"),
            STRubyAnnotation(range: 0..<2, text: "kanji", position: .under),
        ])
        let base = label.context.runs[0..<2]
        let baseLeft = base.map(\.frame.minX).min()!
        let baseRight = base.map(\.frame.maxX).max()!
        let over = label.rubyRuns.filter { $0.frame.minX >= baseRight - 0.5 }
        let under = label.rubyRuns.filter { $0.frame.maxX <= baseLeft + 0.5 }
        // 縦書きでは 1 段目が右、2 段目が左
        #expect(over.count == 3)
        #expect(under.count == 5)
        #expect(over.count + under.count == label.rubyRuns.count)
        #expect(abs(under.map(\.frame.maxX).max()! - baseLeft) < 0.5)
    }

    @Test func secondLevelRubySitsBelowInHorizontalWriting() {
        let label = makeLabel(
            "漢字です",
            ruby: [
                STRubyAnnotation(range: 0..<2, text: "かんじ"),
                STRubyAnnotation(range: 0..<2, text: "kanji", position: .under),
            ],
            size: CGSize(width: 600, height: 400), direction: .lrTb)
        let base = label.context.runs[0..<2]
        let baseTop = base.map(\.frame.minY).min()!
        let baseBottom = base.map(\.frame.maxY).max()!
        let over = label.rubyRuns.filter { $0.frame.maxY <= baseTop + 0.5 }
        let under = label.rubyRuns.filter { $0.frame.minY >= baseBottom - 0.5 }
        #expect(over.count == 3)
        #expect(under.count == 5)
        #expect(over.count + under.count == label.rubyRuns.count)
    }

    @Test func reservesSpaceOnBothSidesForSecondLevelRuby() {
        let oneSided = makeLabel("漢字", ruby: [STRubyAnnotation(range: 0..<2, text: "かんじ")])
        let twoSided = makeLabel("漢字", ruby: [
            STRubyAnnotation(range: 0..<2, text: "かんじ"),
            STRubyAnnotation(range: 0..<2, text: "kanji", position: .under),
        ])
        #expect(abs(oneSided.rubyExtent - 10) < 0.01)
        #expect(abs(twoSided.rubyExtent - 20) < 0.01)
        // 両側に空きが要るぶん、1 ページに入る行数は増えない
        #expect(twoSided.linesPerPage <= oneSided.linesPerPage)
        // どちらのルビも表示領域に収まる
        let drawn = twoSided.drawnRubyFrames
        #expect(drawn.count == 8)
        #expect(drawn.allSatisfy { $0.minX >= -0.5 && $0.maxX <= twoSided.bounds.maxX + 0.5 })
    }

    @Test func secondLevelRubyOnTheLastLineOfAPageIsNotClipped() {
        // 1 行 5 文字で何行も続く本文。ページの最後の行 (縦書きでは左端) に二段ルビを振る
        let text = String(repeating: "あいうえお\n", count: 12)
        // 1 ページの行数は二段ルビのぶんの空きで決まるので、同じ条件の label から求める
        let probe = makeLabel(text, ruby: [
            STRubyAnnotation(range: 0..<2, text: "うえ"),
            STRubyAnnotation(range: 0..<2, text: "した", position: .under),
        ])
        let offset = (probe.linesPerPage - 1) * 6
        let withRuby = makeLabel(text, ruby: [
            STRubyAnnotation(range: offset..<(offset + 2), text: "うえ"),
            STRubyAnnotation(range: offset..<(offset + 2), text: "した", position: .under),
        ])
        // 行数が変わっていないこと (このページの最後の行にルビが載っている) を確かめてから見る
        #expect(withRuby.context.runs[offset].line == withRuby.linesPerPage - 1)
        let drawn = withRuby.drawnRubyFrames
        #expect(drawn.count == 4)
        #expect(drawn.allSatisfy { $0.minX >= -0.5 && $0.maxX <= withRuby.bounds.maxX + 0.5 })
    }

    @Test func widensTheBaseToFitTheLongerOfTheTwoLevels() {
        // 親文字 2 文字 (40pt) に、1 段目 3 文字 (30pt) と 2 段目 7 文字 (70pt)
        let label = makeLabel("漢字", ruby: [
            STRubyAnnotation(range: 0..<2, text: "かんじ"),
            STRubyAnnotation(range: 0..<2, text: "にだんめのるび", position: .under),
        ])
        let base = label.context.runs[0..<2]
        let baseLength = base.map(\.frame.maxY).max()! - base.map(\.frame.minY).min()!
        // 長いほうの 2 段目に合わせて広がる
        #expect(abs(baseLength - 70) < 2)
        // 短いほうの 1 段目は広がった親文字の中央にそろう
        let over = label.rubyRuns.filter { $0.frame.minX >= base.map(\.frame.maxX).max()! - 0.5 }
        let overMid = (over.map(\.frame.minY).min()! + over.map(\.frame.maxY).max()!) * 0.5
        let baseMid = (base.map(\.frame.minY).min()! + base.map(\.frame.maxY).max()!) * 0.5
        #expect(abs(overMid - baseMid) < 0.5)
    }

    @Test func rubyFollowsTheCurrentPage() {
        // 2 ページ目の親文字に付けたルビは 1 ページ目には出ない
        let text = String(repeating: "あいうえおかきくけこ\n", count: 30)
        let offset = text.count - 5
        let label = makeLabel(text, ruby: [STRubyAnnotation(range: offset..<(offset + 2), text: "るび")])
        #expect(label.pageCount > 1)
        label.pageIndex = 0
        #expect(label.drawnRubyFrames.isEmpty)
        label.pageIndex = label.pageCount - 1
        #expect(!label.drawnRubyFrames.isEmpty)
    }

    /// ラベルを bitmap に描いて、各ピクセルの値を返す。
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

extension STLabel {
    /// いま描かれているルビの位置 (ページのずれとルビのぶんの空きを反映したもの)。
    var drawnRubyFrames: [CGRect] {
        drawBuckets.filter(\.isRuby).flatMap(\.frames)
    }
}
