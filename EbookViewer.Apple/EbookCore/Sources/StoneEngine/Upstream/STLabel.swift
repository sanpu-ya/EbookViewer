/*
STLabel.swift

Author: Makoto Kinoshita (mkino@hmdt.jp)

Copyright 2024 Nihon Design Center. All rights reserved.
This software is licensed under the MIT License. See LICENSE for details.
*/

/*
EbookViewer での変更点 (詳細は ../README.md):
 - import を UIKit / AppKit 両対応にし、基底クラスを STPlatformView (UIView / NSView) にした
 - CATiledLayer (STTiledLayer) を使わず、ビューに直接描く
 - 編集機能 (textInput・選択範囲・未確定文字列の下線) の描画を外した
 - ページ分割 (isPaged / pageIndex / pageCount) を足した
 - 同じ条件のときは parse / layout をやり直さないようにした
*/

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

open class STLabel: STPlatformView {
    // Text
    open var text: String? {
        didSet {
            // Set needs layout
            setNeedsLayout()
        }
    }

    // Layout
    open var fontSize: CGFloat {
        get { context.fontSize }
        set {
            context.fontSize = newValue
            setNeedsLayout()
        }
    }
    open var lineHeightScale: CGFloat {
        get { context.lineHeightScale }
        set {
            context.lineHeightScale = newValue
            setNeedsLayout()
        }
    }
    open var textAlign: STTextAlign {
        get { context.textAlign }
        set {
            context.textAlign = newValue
            setNeedsLayout()
        }
    }
    open var directionAlign: STDirectionAlign {
        get { context.directionAlign }
        set {
            context.directionAlign = newValue
            setNeedsLayout()
        }
    }
    open var direction: STDirection {
        get { context.direction }
        set {
            context.direction = newValue
            setNeedsLayout()
        }
    }
    open var isAllowedTateChuYoko: Bool {
        get { context.isAllowedTateChuYoko }
        set {
            context.isAllowedTateChuYoko = newValue
            setNeedsLayout()
        }
    }
    open var adjustsFontSizeToFitWidth: Bool {
        get { context.adjustsFontSizeToFitWidth }
        set {
            context.adjustsFontSizeToFitWidth = newValue
            setNeedsLayout()
        }
    }
    open var minimumScaleFactor: CGFloat {
        get { context.minimumScaleFactor }
        set {
            context.minimumScaleFactor = newValue
            setNeedsLayout()
        }
    }

    // Color
    open var textColor: UIColor {
        get { context.textColor }
        set {
            context.textColor = newValue
            setNeedsLayout()
        }
    }

    // Features
    open var punctuationMode: STPunctuationMode {
        get { context.punctuationMode }
        set {
            context.punctuationMode = newValue
            setNeedsLayout()
        }
    }
    open var isKinsokuAvailable: Bool {
        get { context.isKinsokuAvailable }
        set {
            context.isKinsokuAvailable = newValue
            setNeedsLayout()
        }
    }
    open var isDividedByWords: Bool {
        get { context.isDividedByWords }
        set {
            context.isDividedByWords = newValue
            setNeedsLayout()
        }
    }

    // Context
    public let context = STContext()

    private var needsToLayout: Bool = false

    //--------------------------------------------------------------//
    // MARK: - Initialize
    //--------------------------------------------------------------//

    private func _init() {
        // Configure itself
        backgroundColor = .systemBackground
    }

    public override init(frame: CGRect) {
        // Invoke super
        super.init(frame: frame)

        // Common init
        _init()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)

        // Common init
        _init()
    }

    //--------------------------------------------------------------//
    // MARK: - Font
    //--------------------------------------------------------------//

    open func fontNames(script: STScript) -> [String] {
        // Pass to font manager
        return context.fontManager.fontNames(script: script)
    }

    open func setFontNames(_ fontNames: [String], script: STScript) {
        // Pass to font manager
        context.fontManager.setFontNames(fontNames, script: script)

        // Set needs layout
        setNeedsLayout()
    }

    open func fontScale(script: STScript) -> CGFloat {
        // Pass to font manager
        return context.fontManager.fontScale(script: script)
    }

    open func setFontScale(_ fontScale: CGFloat, script: STScript) {
        // Pass to font manager
        context.fontManager.setFontScale(fontScale, script: script)

        // Set needs layout
        setNeedsLayout()
    }

    //--------------------------------------------------------------//
    // MARK: - Page (EbookViewer)
    //--------------------------------------------------------------//

    /// 行を block 方向 (縦書きなら右から左、横書きなら上から下) にページ単位で区切って表示する。
    /// false のときは upstream と同じく、bounds に収まらない分を省略記号で打ち切る。
    open var isPaged: Bool = false {
        didSet {
            guard isPaged != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 表示するページ (0 始まり)。レイアウトは共通なので、ページを変えても組み直しは起きない。
    open var pageIndex: Int = 0 {
        didSet {
            guard pageIndex != oldValue else { return }
            createDrawBcukets()
            setNeedsDisplay()
        }
    }

    /// 1 ページに収まる行数。
    ///
    /// 行は行送り (fontSize × lineHeightScale) ずつずれて並ぶが、最後の 1 行が必要とするのは
    /// 行送りではなく文字 1 つぶんの幅なので、`文字幅 + 行送り × (行数 - 1) <= 表示領域` で求める。
    /// 単純に「表示領域 ÷ 行送り」にすると、行間のぶんだけ最後の 1 行が入らなくなる。
    open var linesPerPage: Int {
        let extent = context.direction == .tbRl ? bounds.width : bounds.height
        let lineHeight = context.adjustLineHeight
        let glyphExtent = context.adjustFontSize
        guard lineHeight > 0, extent >= glyphExtent else { return 1 }
        // 浮動小数の誤差でちょうど収まる行が落ちないよう少しだけ余裕を持たせる
        return max(1, Int((extent - glyphExtent + 0.5) / lineHeight) + 1)
    }

    /// 組んだ行数。`context.lineCount` は末尾の改行のぶん 1 行多く数えるので、
    /// 実際に文字が置かれている最後の行から求める (run の line は順に増える)。
    open var layoutedLineCount: Int {
        guard let last = context.runs.last else { return 1 }
        return last.line + 1
    }

    /// 全ページ数。text を入れてレイアウトが終わったあとに確定する。
    open var pageCount: Int {
        guard isPaged else { return 1 }
        let perPage = linesPerPage
        return max(1, (layoutedLineCount + perPage - 1) / perPage)
    }

    /// text の先頭から offset 文字目 (Character 単位) を含むページ。
    /// STParser は 1 文字 = 1 run で解析するので、run の添字がそのまま文字位置になる。
    open func page(ofCharacterAt offset: Int) -> Int {
        guard isPaged, offset >= 0, offset < context.runs.count else { return 0 }
        return min(pageCount - 1, context.runs[offset].line / linesPerPage)
    }

    private var clampedPageIndex: Int {
        min(max(0, pageIndex), max(0, pageCount - 1))
    }

    /// 表示中のページが占める行の範囲。
    private var pageLineRange: Range<Int> {
        let perPage = linesPerPage
        let start = clampedPageIndex * perPage
        return start ..< start + perPage
    }

    /// 表示中のページを bounds に収めるための描画位置のずれ。
    private var pageTranslation: CGPoint {
        let page = clampedPageIndex
        guard isPaged, page > 0 else { return .zero }
        let distance = context.adjustLineHeight * CGFloat(page * linesPerPage)
        // 縦書きは行が左へ積まれるので右へ、横書きは下へ積まれるので上へ戻す
        switch context.direction {
        case .tbRl: return .init(x: distance, y: 0)
        case .lrTb: return .init(x: 0, y: -distance)
        }
    }

    //--------------------------------------------------------------//
    // MARK: - Layout
    //--------------------------------------------------------------//

    private func adjustWithScale(_ scale: CGFloat) -> Bool {
        // Set adjust font scale
        context.adjustFontScale = scale

        // Parse and layout
        STParser(context: context).parse(text: text)
        STLayout(context: context).layout()

        // Check truncated
        return !context.isTruncated
    }

    private func adjust() {
        // Check max and min scale
        guard minimumScaleFactor > 0 else { return }
        var maxScale: CGFloat = 1
        guard !adjustWithScale(maxScale) else { return }
        var minScale = minimumScaleFactor
        guard adjustWithScale(minScale) else { return }

        // Adjust scale
        var prevScale = minScale
        var scale = minScale + (maxScale - minScale) * 0.5
        var isAdjusted = false
        while abs(1.0 - prevScale / scale) > 0.05 || !isAdjusted {
            // Set prev scale
            prevScale = scale

            // Adjust with scale
            isAdjusted = adjustWithScale(scale)

            // Decide next scale
            if isAdjusted {
                scale = scale + (maxScale - scale) * 0.5
                minScale = prevScale
            }
            else {
                scale = minScale + (scale - minScale) * 0.5
                maxScale = prevScale
            }
        }
    }

    private func parseAndLayout() {
        // Set render size
        context.renderSize = bounds.size
        context.adjustFontScale = 1.0

        // Refresh font manager
        context.fontManager.refresh()

        // For adjust
        if adjustsFontSizeToFitWidth {
            adjust()
        }
        // For not adjust
        else {
            // Parse and layout
            STParser(context: context).parse(text: text)
            STLayout(context: context).layout()
        }
    }

    /// 組版の結果を左右する条件。これが変わらないかぎり parse / layout をやり直さない。
    /// (ページ送りのたびに章全体を組み直すのを避けるための EbookViewer の追加)
    private struct LayoutSignature: Equatable {
        var size: CGSize
        var textCount: Int
        var textHash: Int
        var fontSize: CGFloat
        var lineHeightScale: CGFloat
        var textAlign: STTextAlign
        var directionAlign: STDirectionAlign
        var direction: STDirection
        var isAllowedTateChuYoko: Bool
        var adjustsFontSizeToFitWidth: Bool
        var minimumScaleFactor: CGFloat
        var punctuationMode: STPunctuationMode
        var isKinsokuAvailable: Bool
        var isDividedByWords: Bool
        var fonts: String
    }

    private var layoutSignature: LayoutSignature?

    private func makeLayoutSignature() -> LayoutSignature {
        let fonts = STScript.allCases.map { script in
            fontNames(script: script).joined(separator: ",") + ":" + String(describing: fontScale(script: script))
        }.joined(separator: "/")
        return LayoutSignature(
            size: bounds.size,
            textCount: text?.count ?? 0,
            textHash: text?.hashValue ?? 0,
            fontSize: fontSize,
            lineHeightScale: lineHeightScale,
            textAlign: textAlign,
            directionAlign: directionAlign,
            direction: direction,
            isAllowedTateChuYoko: isAllowedTateChuYoko,
            adjustsFontSizeToFitWidth: adjustsFontSizeToFitWidth,
            minimumScaleFactor: minimumScaleFactor,
            punctuationMode: punctuationMode,
            isKinsokuAvailable: isKinsokuAvailable,
            isDividedByWords: isDividedByWords,
            fonts: fonts)
    }

    open override func sizeThatFits(_ size: CGSize) -> CGSize {
        // Create copied context
        let context = STContext()
        context.fontSize = fontSize
        context.lineHeightScale = lineHeightScale
        context.textAlign = textAlign
        context.directionAlign = directionAlign
        context.direction = direction
        context.isAllowedTateChuYoko = isAllowedTateChuYoko
        context.adjustsFontSizeToFitWidth = adjustsFontSizeToFitWidth
        context.minimumScaleFactor = minimumScaleFactor
        context.isKinsokuAvailable = isKinsokuAvailable
        context.isDividedByWords = isDividedByWords

        // Set render size
        context.renderSize = size
        context.adjustFontScale = 1.0

        // Refresh font manager
        context.fontManager.refresh()

        // Parse and layout
        STParser(context: context).parse(text: text)
        STLayout(context: context).layout()

        // Get rendered size
        return context.renderedSize
    }

    open override func layoutSubviews() {
        // Invoke super
        super.layoutSubviews()

        // Parse and layout, only when it is needed
        let signature = makeLayoutSignature()
        if signature != layoutSignature {
            parseAndLayout()
            layoutSignature = signature
        }

        // Create draw buckets
        createDrawBcukets()

        // Set needs to display
        setNeedsDisplay()
    }

    open func layoutThatFits(_ size: CGSize) -> CGSize {
        // Check needs to layout
        guard needsToLayout || context.renderSize != size else { return context.renderedSize }

        // Layout
        context.renderSize = size
        STLayout(context: context).layout()

        // Clear flag
        needsToLayout = false

        // Get rendered size
        return context.renderedSize
    }

    //--------------------------------------------------------------//
    // MARK: - Draw
    //--------------------------------------------------------------//

    struct DrawBucket {
        let fontId: Int
        let isClockwise: Bool
        let needsToFlip: Bool
        let ctFont: CTFont
        var glyphs: [CGGlyph]
        var positions: [CGPoint]
        var frames: [CGRect]
    }

    var drawBuckets = [DrawBucket]()

    private func createDrawBcukets() {
        // Decide page
        let lineRange: Range<Int>? = isPaged ? pageLineRange : nil
        let translation = pageTranslation

        // Create draw buckets
        var drawBuckets = [DrawBucket]()
        for run in context.runs {
            // Check visibility
            if let lineRange {
                // ページ表示では visibility ではなく行の範囲で絞る (ページ末尾を省略記号にしない)
                guard lineRange.contains(run.line) else { continue }
            }
            else {
                guard !run.isHidden else { continue }
            }
            let isClockwise = context.isClockwise(run: run)
            let needsToFlip = context.fontManager.needsToFlip(fontId: run.fontId)

            // Find bucket
            let bucketIndex: Int
            if let index = drawBuckets.firstIndex(where: { $0.fontId == run.fontId && $0.isClockwise == isClockwise && $0.needsToFlip == needsToFlip }) {
                bucketIndex = index
            }
            else {
                // Get CT font
                let ctFont = context.fontManager.ctFont(fontId: run.fontId, size: context.adjustFontSize, isClockwise: isClockwise)

                // Add bucket
                drawBuckets.append(DrawBucket(fontId: run.fontId, isClockwise: isClockwise, needsToFlip: needsToFlip, ctFont: ctFont, glyphs: [], positions: [], frames: []))
                bucketIndex = drawBuckets.count - 1
            }

            // Decide position and frame
            let position = CGPoint(x: run.position.x + translation.x, y: run.position.y + translation.y)
            let frame = run.frame.offsetBy(dx: translation.x, dy: translation.y)

            // For ellipsis
            if run.visibility == .ellipsis && !isPaged {
                // Add ellipsis
                drawBuckets[bucketIndex].glyphs.append(context.fontManager.ellipsisGlyph(fontId: run.fontId, direction: context.direction))
                drawBuckets[bucketIndex].positions.append(position)
                drawBuckets[bucketIndex].frames.append(frame)
            }
            // For visible
            else if run.visibility == .visible || isPaged {
                // Add glyph and position
                drawBuckets[bucketIndex].glyphs.append(run.glyph)
                drawBuckets[bucketIndex].positions.append(position)
                drawBuckets[bucketIndex].frames.append(frame)
            }
        }

        // Set draw buckets
        self.drawBuckets = drawBuckets
    }

    private func drawGlyphs(_ dirtyRect: CGRect) {
        // Get CG context
        guard let cgContext = UIGraphicsGetCurrentContext() else { return }

        // Set text color
        cgContext.setFillColor(context.textColor.cgColor)

        // Draw buckets
        for bucket in drawBuckets {
            // Draw glyphs
            if bucket.needsToFlip {
                for i in 0 ..< bucket.glyphs.count {
                    var transform: CGAffineTransform = .identity
                    transform = transform.translatedBy(x: 0, y: bucket.positions[i].y * 2)
                    transform = transform.scaledBy(x: 1, y: -1)
                    cgContext.saveGState()
                    cgContext.concatenate(transform)
                    CTFontDrawGlyphs(bucket.ctFont, [bucket.glyphs[i]], [bucket.positions[i]], 1, cgContext)
                    cgContext.restoreGState()
                }
            }
            else {
                CTFontDrawGlyphs(bucket.ctFont, bucket.glyphs, bucket.positions, bucket.glyphs.count, cgContext)
            }
        }
    }

    private func drawFrames(_ dirtyRect: CGRect) {
        // Get CG context
        guard let cgContext = UIGraphicsGetCurrentContext() else { return }

        // Set frame color
        cgContext.setStrokeColor(UIColor.blue.cgColor)

        // Draw frames
        for run in context.runs {
            cgContext.stroke(run.frame)
        }
    }

    open override func draw(_ dirtyRect: CGRect) {
        // Draw
        drawGlyphs(dirtyRect)

        // For test
        //drawFrames(dirtyRect)
    }
}
