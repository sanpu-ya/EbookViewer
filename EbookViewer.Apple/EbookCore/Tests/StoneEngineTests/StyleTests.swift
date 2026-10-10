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
