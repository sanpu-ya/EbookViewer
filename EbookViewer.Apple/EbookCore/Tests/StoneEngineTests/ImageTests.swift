import Testing
import CoreGraphics
@testable import StoneEngine
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 本文に差し込む画像。
@MainActor
struct ImageTests {
    /// 指定の大きさの、真っ黒な画像。
    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeLabel(
        _ text: String,
        images: [STImageAnnotation] = [],
        size: CGSize = CGSize(width: 400, height: 600),
        direction: STDirection = .tbRl
    ) -> STLabel {
        let label = STLabel(frame: CGRect(origin: .zero, size: size))
        label.isPaged = true
        label.direction = direction
        label.fontSize = 20
        label.lineHeightScale = 1.9
        label.setFontNames(["HiraMinProN-W3"], script: .japanese)
        label.text = text
        label.imageAnnotations = images
        label.layoutSubviews()
        return label
    }

    // MARK: - 挿絵 (1 ページを使う画像)

    @Test func illustrationTakesAPageOfItsOwn() {
        // 「本文\n[画像]\n本文」。画像の行は 1 ページまるごと使う
        let text = "あいうえお\n\u{3000}\nかきくけこ"
        let label = makeLabel(text, images: [
            STImageAnnotation(offset: 6, image: makeImage(width: 100, height: 200), isBlock: true),
        ])
        #expect(label.pageCount == 3)
        #expect(label.pages == [.text(0..<1), .image(0), .text(2..<3)])
        // 画像の位置からそのページが引ける
        #expect(label.page(ofCharacterAt: 6) == 1)
        #expect(label.page(ofCharacterAt: 0) == 0)
        #expect(label.page(ofCharacterAt: 8) == 2)
    }

    @Test func illustrationFillsThePageKeepingItsAspectRatio() {
        let size = CGSize(width: 400, height: 600)
        let label = makeLabel("あ\n\u{3000}\nい", images: [
            STImageAnnotation(offset: 2, image: makeImage(width: 100, height: 200), isBlock: true),
        ], size: size)
        label.pageIndex = 1
        let pixels = render(label, size: size)
        let width = Int(size.width)
        // 縦長の画像なので、高さいっぱい・幅は半分 (200 x 600) で中央に入る
        var minX = width, maxX = 0, minY = Int(size.height), maxY = 0
        for y in 0..<Int(size.height) {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // 縦長 (1:2) の画像なので、高さいっぱいの 300 x 600 で中央に入る
        #expect(abs(maxX - minX - 300) < 3)
        #expect(abs(maxY - minY - 600) < 3)
        #expect(abs(minX - 50) < 3)
    }

    @Test func textPagesSkipTheIllustrationLine() {
        // 挿絵のページには本文を描かない
        let size = CGSize(width: 400, height: 600)
        let label = makeLabel("あいうえお\n\u{3000}\nかきくけこ", images: [
            STImageAnnotation(offset: 6, image: makeImage(width: 10, height: 10), isBlock: true),
        ], size: size)
        label.pageIndex = 0
        let firstPage = label.drawBuckets.flatMap(\.glyphs).count
        label.pageIndex = 2
        let lastPage = label.drawBuckets.flatMap(\.glyphs).count
        label.pageIndex = 1
        let imagePage = label.drawBuckets.flatMap(\.glyphs).count
        // 本文のページには、それぞれの行の 5 文字が描かれる (1 ページ目は行末の改行の run も含む)
        #expect(firstPage >= 5)
        #expect(lastPage == 5)
        // 挿絵のページには本文を描かない
        #expect(imagePage == 0)
    }

    @Test func severalIllustrationsEachTakeAPage() {
        let image = makeImage(width: 50, height: 50)
        let label = makeLabel("\u{3000}\n\u{3000}\n本文", images: [
            STImageAnnotation(offset: 0, image: image, isBlock: true),
            STImageAnnotation(offset: 2, image: image, isBlock: true),
        ])
        #expect(label.pages == [.image(0), .image(1), .text(2..<3)])
    }

    // MARK: - 行の中に収める画像

    @Test func inlineImageWidensItsCellToTheImageShape() {
        // 横長 (2:1) の画像を縦書きの行に入れると、行の中で 1 文字の半分の長さに詰まる
        let plain = makeLabel("あ\u{3000}い")
        let label = makeLabel("あ\u{3000}い", images: [
            STImageAnnotation(offset: 1, image: makeImage(width: 200, height: 100), isBlock: false),
        ])
        #expect(abs(plain.context.runs[1].frame.height - 20) < 0.5)
        #expect(abs(label.context.runs[1].frame.height - 10) < 0.5)
        // 行の中なのでページは増えない
        #expect(label.pageCount == 1)
    }

    @Test func tallInlineImageTakesMoreRoomAlongTheLine() {
        let label = makeLabel("あ\u{3000}い", images: [
            STImageAnnotation(offset: 1, image: makeImage(width: 100, height: 200), isBlock: false),
        ])
        // 縦長 (1:2) なので、行の中で 2 文字ぶんの長さになる
        #expect(abs(label.context.runs[1].frame.height - 40) < 0.5)
        // 後ろの文字はそのぶん下へずれる
        #expect(abs(label.context.runs[2].frame.minY - 60) < 0.5)
    }

    @Test func inlineImageIsDrawnInItsCell() {
        let size = CGSize(width: 200, height: 200)
        let label = makeLabel("あ\u{3000}い", images: [
            STImageAnnotation(offset: 1, image: makeImage(width: 100, height: 100), isBlock: false),
        ], size: size)
        let pixels = render(label, size: size)
        let width = Int(size.width)
        let cell = label.context.runs[1].frame
        // 置き場所の真ん中に墨がある (全角空白は何も描かないので、画像が描かれた証拠になる)
        let x = Int(cell.midX - label.rubyExtent)
        let y = Int(cell.midY)
        #expect(pixels[(y * width + x) * 4 + 3] > 0)
    }

    @Test func imagesOutsideTheTextAreIgnored() {
        let label = makeLabel("短い", images: [
            STImageAnnotation(offset: 99, image: makeImage(width: 10, height: 10), isBlock: true),
            STImageAnnotation(offset: -1, image: makeImage(width: 10, height: 10), isBlock: false),
        ])
        #expect(label.pageCount == 1)
        #expect(label.pages == [.text(0..<1)])
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
