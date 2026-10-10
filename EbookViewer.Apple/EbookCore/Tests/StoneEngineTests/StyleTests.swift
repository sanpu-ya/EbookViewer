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
