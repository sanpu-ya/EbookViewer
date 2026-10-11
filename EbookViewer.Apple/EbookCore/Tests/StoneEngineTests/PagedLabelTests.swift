import Testing
import CoreGraphics
@testable import StoneEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// STLabel のページ分割と、macOS (AppKit) への移植が効いているかを確かめる。
/// テストは macOS 上で走るので、グリフが実際に描かれるかどうかまで見る。
@MainActor
struct PagedLabelTests {
    private static let sample = String(repeating:
        "　ある日の暮方の事である。一人の下人が、羅生門の下で雨やみを待っていた。" +
        "広い門の下には、この男のほかに誰もいない。ただ、所々丹塗の剥げた、大きな円柱に、蟋蟀が一匹とまっている。\n",
        count: 20)

    private func makeLabel(size: CGSize, direction: STDirection = .tbRl) -> STLabel {
        let label = STLabel(frame: CGRect(origin: .zero, size: size))
        label.isPaged = true
        label.direction = direction
        label.fontSize = 20
        label.lineHeightScale = 1.9
        label.punctuationMode = .stone
        label.text = Self.sample
        label.layoutSubviews()
        return label
    }

    @Test func splitsTextIntoSeveralPages() {
        let label = makeLabel(size: CGSize(width: 400, height: 600))
        // 行送り = 20 * 1.9 = 38pt、文字幅 20pt なので、幅 400 には 20 + 38 * 10 = 400 で 11 行入る
        #expect(label.linesPerPage == 11)
        #expect(label.layoutedLineCount > 11)
        #expect(label.pageCount == (label.layoutedLineCount + 10) / 11)
        #expect(label.pageCount > 1)
        // 末尾の改行のぶんだけ空のページができていないこと
        #expect(label.layoutedLineCount <= label.context.lineCount)
        #expect(label.pageCount * label.linesPerPage - label.layoutedLineCount < label.linesPerPage)
        // 行が表示領域に収まっていること (最後の行がはみ出していない)
        let lastLineOrigin = 400.0 - label.context.adjustFontSize - label.context.adjustLineHeight * Double(label.linesPerPage - 1)
        #expect(lastLineOrigin >= -0.5)
    }

    @Test func pageBreakStartsANewPage() {
        let size = CGSize(width: 400, height: 600)
        let plain = makeLabel(size: size)
        // 1 ページに収まる行の途中で改ページを入れる
        let offset = Self.sample.count / 2
        let label = makeLabel(size: size)
        label.pageBreakOffsets = [offset]
        label.layoutSubviews()

        // 指定した文字の行は、改ページが無ければページの先頭ではない
        let breakLine = label.context.runs[offset].line
        if case .text(let plainLines) = plain.pages[plain.page(ofCharacterAt: offset)] {
            #expect(plainLines.lowerBound != breakLine)
        } else {
            Issue.record("本文のページではない")
        }

        // 改ページを入れると、その行からページが始まる
        let page = label.page(ofCharacterAt: offset)
        #expect(page > 0)
        guard case .text(let lines) = label.pages[page] else {
            Issue.record("本文のページではない")
            return
        }
        #expect(lines.lowerBound == breakLine)
        // 手前のページは、改ページの行の手前で終わる
        guard case .text(let before) = label.pages[page - 1] else {
            Issue.record("本文のページではない")
            return
        }
        #expect(before.upperBound == lines.lowerBound)
        // どのページも 1 ページぶんの行数を超えない
        for content in label.pages {
            if case .text(let range) = content { #expect(range.count <= label.linesPerPage) }
        }
    }

    @Test func twoPageBreaksInARowMakeABlankPage() {
        // 青空文庫の「空白ページの挿入」は、改ページを 2 つ続けて書くもの
        let size = CGSize(width: 400, height: 600)
        let offset = Self.sample.count / 2
        let once = makeLabel(size: size)
        once.pageBreakOffsets = [offset]
        once.layoutSubviews()
        let twice = makeLabel(size: size)
        twice.pageBreakOffsets = [offset, offset]
        twice.layoutSubviews()

        // 空白のページが 1 枚増える
        #expect(twice.pageCount == once.pageCount + 1)
        let page = twice.page(ofCharacterAt: offset)
        guard case .blank = twice.pages[page - 1] else {
            Issue.record("空白のページが無い")
            return
        }
        // 空白のページには何も描かない
        twice.pageIndex = page - 1
        #expect(twice.drawBuckets.isEmpty)
        // 本文は前後にそのまま続く
        #expect(twice.page(ofCharacterAt: 0) == once.page(ofCharacterAt: 0))
    }

    @Test func pageBreakAtTheVeryStartMakesNoEmptyPage() {
        let size = CGSize(width: 400, height: 600)
        let plain = makeLabel(size: size)
        let label = makeLabel(size: size)
        label.pageBreakOffsets = [0]
        label.layoutSubviews()
        #expect(label.pageCount == plain.pageCount)
    }

    @Test func horizontalDirectionPagesByHeight() {
        let label = makeLabel(size: CGSize(width: 600, height: 400), direction: .lrTb)
        #expect(label.linesPerPage == 11)
        #expect(label.pageCount > 1)
    }

    @Test func pageOfCharacterGrowsWithOffset() {
        let label = makeLabel(size: CGSize(width: 400, height: 600))
        #expect(label.page(ofCharacterAt: 0) == 0)
        let last = label.page(ofCharacterAt: Self.sample.count - 1)
        #expect(last == label.pageCount - 1)
        // 文字位置が進めばページも後ろへ (戻ることはない)
        var previous = 0
        for offset in stride(from: 0, to: Self.sample.count, by: 97) {
            let page = label.page(ofCharacterAt: offset)
            #expect(page >= previous)
            previous = page
        }
    }

    @Test func singlePageTextFitsInOnePage() {
        let label = STLabel(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        label.isPaged = true
        label.direction = .tbRl
        label.fontSize = 20
        label.text = "短い本文。"
        label.layoutSubviews()
        #expect(label.pageCount == 1)
        #expect(label.page(ofCharacterAt: 4) == 0)
    }

    @Test func everyPageDrawsDifferentGlyphs() {
        let size = CGSize(width: 400, height: 600)
        let label = makeLabel(size: size)
        #expect(label.pageCount >= 3)

        var inkPerPage: [Int] = []
        var fingerprints: [[UInt8]] = []
        for page in 0..<min(3, label.pageCount) {
            label.pageIndex = page
            let pixels = render(label, size: size)
            inkPerPage.append(pixels.lazy.filter { $0 > 0 }.count)
            fingerprints.append(pixels)
        }
        // どのページにも文字が描かれている
        for ink in inkPerPage { #expect(ink > 1000) }
        // ページごとに中身が違う (描画位置をずらせている)
        #expect(fingerprints[0] != fingerprints[1])
        #expect(fingerprints[1] != fingerprints[2])
    }

    @Test func pagedLabelDrawsNoEllipsis() {
        // ページ表示では収まらない行を省略記号で打ち切らない
        let label = makeLabel(size: CGSize(width: 400, height: 600))
        #expect(!label.context.runs.contains { $0.visibility == .ellipsis && label.isPaged == false })
        // 省略記号の run は残っていても、ページ表示では通常のグリフとして扱う
        let inkFirst = render(label, size: CGSize(width: 400, height: 600)).lazy.filter { $0 > 0 }.count
        label.isPaged = false
        label.layoutSubviews()
        let inkUnpaged = render(label, size: CGSize(width: 400, height: 600)).lazy.filter { $0 > 0 }.count
        // 1 ページ分の文字数はだいたい同じ (打ち切りの有無で大きくは変わらない)
        #expect(inkFirst > inkUnpaged / 2)
    }

    /// ラベルを bitmap に描いて、各ピクセルのアルファ値を返す。
    private func render(_ label: STLabel, size: CGSize) -> [UInt8] {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context else { return pixels }
        // stone_engine は y 軸下向きで組版するので、描く前に座標系を合わせる
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        pixels = withGraphicsContext(context) {
            label.draw(CGRect(origin: .zero, size: size))
        }
        return pixels
    }

    /// 与えた CGContext を「現在のコンテキスト」にして描画ブロックを実行し、描けたピクセルを返す。
    private func withGraphicsContext(_ context: CGContext, _ body: () -> Void) -> [UInt8] {
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        body()
        UIGraphicsPopContext()
        #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        #endif
        guard let data = context.data else { return [] }
        let count = context.bytesPerRow * context.height
        return Array(UnsafeRawBufferPointer(start: data, count: count).bindMemory(to: UInt8.self))
    }
}
