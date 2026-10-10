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
    // MARK: - Ruby (EbookViewer)
    //--------------------------------------------------------------//

    /// ルビ (振り仮名)。親文字の範囲は text の Character 単位で指定する。
    /// 縦書きなら親文字の右、横書きなら上の行間に置くので、行送り (lineHeightScale) が
    /// 1 + rubyFontScale 以上ないと隣の行とぶつかる。
    open var rubyAnnotations: [STRubyAnnotation] = [] {
        didSet {
            guard rubyAnnotations != oldValue else { return }
            resolveAnnotations()
            setNeedsLayout()
        }
    }

    /// 圏点 (傍点) を打つ範囲。ルビと同じく行間に置く。
    open var emphasisAnnotations: [STEmphasisAnnotation] = [] {
        didSet {
            guard emphasisAnnotations != oldValue else { return }
            resolveAnnotations()
            setNeedsLayout()
        }
    }

    /// ルビと圏点を合わせたもの。行間に置くものはすべてここに集める。
    private var annotations: [STRubyAnnotation] = []

    private func resolveAnnotations() {
        annotations = rubyAnnotations + emphasisAnnotations.flatMap { $0.marks(avoiding: rubyAnnotations) }
    }

    /// 本文に差し込む画像。置き場所は text の Character 位置で指定する。
    open var imageAnnotations: [STImageAnnotation] = [] {
        didSet {
            guard imageAnnotations != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 割り注にする範囲。本文 1 行ぶんの幅の中に、半分の大きさで 2 行に組む。
    open var warichuRanges: [Range<Int>] = [] {
        didSet {
            guard warichuRanges != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 字下げ・地付きにする範囲。行の始まり (と終わり) に空きを作る。
    open var indentAnnotations: [STIndentAnnotation] = [] {
        didSet {
            guard indentAnnotations != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 文字の大きさを変える範囲。行送りは変わらないので、行送り (lineHeightScale) を
    /// 超える大きさにはならない (隣の行とぶつからないように頭打ちにする)。
    open var sizeAnnotations: [STSizeAnnotation] = [] {
        didSet {
            guard sizeAnnotations != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 縦中横にする範囲 (青空文庫の「縦組み中で横に並んだ文字」)。
    /// 横書きでは何も起きない。まとまりが 1 語として切り出されないと横に並ばないので、
    /// 数字や欧文の 2〜3 文字を想定している。
    open var tateChuYokoRanges: [Range<Int>] = [] {
        didSet {
            guard tateChuYokoRanges != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 傍線・左傍線・取り消し線を引く範囲。
    open var lineAnnotations: [STLineAnnotation] = [] {
        didSet {
            guard lineAnnotations != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 太字・斜体にする範囲。
    open var styleAnnotations: [STStyleAnnotation] = [] {
        didSet {
            guard styleAnnotations != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// ルビが親文字より長いとき、隣の仮名に掛けてよいか (ルビの掛け)。
    /// false にすると、はみ出すぶんはすべて親文字を広げて収める。
    open var allowsRubyOverhang: Bool = true {
        didSet {
            guard allowsRubyOverhang != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// ルビの大きさ (親文字に対する比)。
    open var rubyFontScale: CGFloat = 0.5 {
        didSet {
            guard rubyFontScale != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 行の脇にルビのために空けておく幅。ルビが無ければ 0。
    /// 二段ルビでは親文字の両側に要るので、上下 (縦書きでは左右) それぞれで数える。
    open func rubyExtent(_ position: STRubyPosition) -> CGFloat {
        let ruby = annotations.contains { $0.position == position && !$0.text.isEmpty }
            ? context.adjustFontSize * rubyFontScale
            : 0
        // 傍線のぶん。引く側は向きと種類で決まる
        let needsLine = lineAnnotations.contains { $0.position.side(for: context.direction) == position }
        guard needsLine else { return ruby }
        return max(ruby, lineExtent)
    }

    /// 行の両脇にルビのために空けておく幅の合計。
    open var rubyExtent: CGFloat {
        STRubyPosition.allCases.reduce(0) { $0 + rubyExtent($1) }
    }

    /// 傍線の太さ。
    open var lineThickness: CGFloat {
        max(1, (context.adjustFontSize / 18).rounded())
    }

    /// 傍線のために文字の脇へ空けておく幅 (線の太さと、文字との間の空き)。
    /// 二重線と波線は太さより広がるので、そのぶんを見ておく。
    private var lineExtent: CGFloat {
        lineThickness * 4
    }

    /// 組み終わったルビ。親文字のレイアウトのあとに置き場所を決める。
    private(set) var rubyRuns: [STRubyRun] = []

    /// 組んだルビ。親文字を広げる量を決めるのと、置き場所を決めるのに使い回す。
    private var rubyLayout: STRubyLayout?

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
        // ルビのぶんは行の脇に空けておく
        let extent = (context.direction == .tbRl ? bounds.width : bounds.height) - rubyExtent
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

    /// ページ 1 つぶんの中身。挿絵は 1 ページを使う。
    enum PageContent: Equatable {
        /// 本文の行の範囲。
        case text(Range<Int>)
        /// imageAnnotations の添字。
        case image(Int)
    }

    /// ページの並び。レイアウトのあとに作る。
    private(set) var pages: [PageContent] = []

    /// 全ページ数。text を入れてレイアウトが終わったあとに確定する。
    open var pageCount: Int {
        guard isPaged else { return 1 }
        return max(1, pages.count)
    }

    /// 行を 1 ページぶんずつに区切る。挿絵が載っている行は、その 1 ページを挿絵に使う。
    private func makePages() -> [PageContent] {
        guard isPaged else { return [] }
        let perPage = max(1, linesPerPage)
        let lineCount = layoutedLineCount

        // 挿絵が載っている行
        var imageLines: [Int: Int] = [:]
        for (index, annotation) in imageAnnotations.enumerated() where annotation.isBlock {
            guard annotation.offset >= 0, annotation.offset < context.runs.count else { continue }
            imageLines[context.runs[annotation.offset].line] = index
        }

        var pages: [PageContent] = []
        var start = 0
        var line = 0
        while line < lineCount {
            if let image = imageLines[line] {
                if line > start { pages.append(.text(start..<line)) }
                pages.append(.image(image))
                line += 1
                start = line
                continue
            }
            if line - start + 1 >= perPage {
                pages.append(.text(start..<(line + 1)))
                line += 1
                start = line
                continue
            }
            line += 1
        }
        if start < lineCount { pages.append(.text(start..<lineCount)) }
        return pages.isEmpty ? [.text(0..<lineCount)] : pages
    }

    /// text の先頭から offset 文字目 (Character 単位) を含むページ。
    /// STParser は 1 文字 = 1 run で解析するので、run の添字がそのまま文字位置になる。
    open func page(ofCharacterAt offset: Int) -> Int {
        guard isPaged, offset >= 0, offset < context.runs.count else { return 0 }
        let line = context.runs[offset].line
        for (index, page) in pages.enumerated() {
            switch page {
            case .text(let lines) where lines.contains(line): return index
            case .image(let image) where imageAnnotations[image].offset == offset: return index
            default: continue
            }
        }
        return max(0, pageCount - 1)
    }

    private var clampedPageIndex: Int {
        min(max(0, pageIndex), max(0, pageCount - 1))
    }

    /// 表示中のページの中身。
    private var currentPage: PageContent {
        guard isPaged, !pages.isEmpty else { return .text(0..<layoutedLineCount) }
        return pages[clampedPageIndex]
    }

    /// 表示中のページが占める行の範囲 (挿絵のページなら空)。
    private var pageLineRange: Range<Int> {
        if case .text(let lines) = currentPage { return lines }
        return 0..<0
    }

    /// 表示中のページを bounds に収め、ルビのぶんを空けるための描画位置のずれ。
    private var contentTranslation: CGPoint {
        // ページのぶん。縦書きは行が左へ積まれるので右へ、横書きは下へ積まれるので上へ戻す
        var distance: CGFloat = 0
        if isPaged, case .text(let lines) = currentPage, lines.lowerBound > 0 {
            distance = context.adjustLineHeight * CGFloat(lines.lowerBound)
        }
        // ルビのぶん。1 行目の over 側のルビ (縦書きなら右端、横書きなら上端の外側) が
        // 切れないよう本文をずらす。under 側は最後の行の外側に要るので、
        // linesPerPage で幅を取り分けておけばずらさなくてよい
        let ruby = rubyExtent(.over)
        switch context.direction {
        case .tbRl: return .init(x: distance - ruby, y: 0)
        case .lrTb: return .init(x: 0, y: ruby - distance)
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
        context.spacings = []

        // 文字ごとの字面 (太字・斜体) を入れる。組む前に決まっていないといけない (EbookViewer)
        context.styles = makeStyles()
        // 行の中に収める画像は、置き場所の 1 文字を画像の幅ぶんに広げる
        context.spacings = makeImageSpacings()
        // 縦中横にする文字
        context.forcedTateChuYoko = Set(tateChuYokoRanges.flatMap { $0 })
        // 文字ごとの大きさ
        context.sizeScales = makeSizeScales()
        // 字下げ・地付き
        applyIndents()

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

        // ルビを組む。ルビのほうが長い親文字は、ルビの長さまで広げて組み直す (EbookViewer)
        let imageSpacings = context.spacings
        let rubyLayout = STRubyLayout(
            context: context, annotations: annotations, fontScale: rubyFontScale, allowsOverhang: allowsRubyOverhang)
        var spacings = rubyLayout.spacings(context: context)
        self.rubyLayout = rubyLayout
        // 割り注は、2 行に積んだときの長さまで詰めてから組み直す
        let warichuSpacings = STWarichuLayout.spacings(context: context, ranges: warichuRanges)
        if !spacings.isEmpty || !warichuSpacings.isEmpty {
            if spacings.isEmpty { spacings = [STSpacing](repeating: .zero, count: context.runs.count) }
            // 画像と割り注のぶんの空きは残す
            for (index, spacing) in imageSpacings.enumerated() where index < spacings.count && spacing != .zero {
                spacings[index] = spacing
            }
            for (index, spacing) in warichuSpacings.enumerated() where index < spacings.count && spacing != .zero {
                spacings[index] = spacing
            }
            context.spacings = spacings
            STLayout(context: context).layout()
        }
        // 組み終わった割り注を 2 行に積む
        STWarichuLayout.apply(context: context, ranges: warichuRanges)
    }

    /// 行の中に収める画像のぶん、置き場所の 1 文字を広げる。
    private func makeImageSpacings() -> [STSpacing] {
        let inline = imageAnnotations.filter { !$0.isBlock }
        guard !inline.isEmpty, let text, !text.isEmpty else { return [] }
        var spacings = [STSpacing](repeating: .zero, count: text.count)
        for annotation in inline {
            guard annotation.offset >= 0, annotation.offset < spacings.count else { continue }
            // 置き場所は全角空白 1 文字 (= 1 em)。画像の形に合わせて後ろの空きで伸ばし縮みさせる。
            // 極端に細い画像で枠が潰れないよう、1 文字の 1/4 までにとどめる
            let wanted = annotation.inlineExtent(fontSize: context.adjustFontSize, direction: context.direction)
            let extent = max(context.adjustFontSize * 0.25, wanted)
            spacings[annotation.offset] = STSpacing(before: 0, after: extent - context.adjustFontSize)
        }
        return spacings
    }

    /// 範囲ごとの字下げ・地付きを、文字ごとの配列にする。範囲が重なっていたら後の指定が勝つ。
    private func applyIndents() {
        guard !indentAnnotations.isEmpty, let text, !text.isEmpty else {
            context.indents = []
            context.trailingGaps = []
            return
        }
        var indents = [CGFloat](repeating: 0, count: text.count)
        var trailings = [CGFloat?](repeating: nil, count: text.count)
        let em = context.adjustFontSize
        for annotation in indentAnnotations {
            let lower = max(0, annotation.range.lowerBound)
            let upper = min(text.count, annotation.range.upperBound)
            guard lower < upper else { continue }
            for i in lower..<upper {
                if annotation.head != 0 { indents[i] = annotation.head * em }
                if let tail = annotation.tail { trailings[i] = tail * em }
            }
        }
        context.indents = indents
        context.trailingGaps = trailings
    }

    /// 範囲ごとの指定を、文字ごとの大きさの配列にする。重なっていたら後の指定を掛け合わせる。
    private func makeSizeScales() -> [CGFloat] {
        guard !sizeAnnotations.isEmpty || !warichuRanges.isEmpty, let text, !text.isEmpty else { return [] }
        var scales = [CGFloat](repeating: 1, count: text.count)
        for annotation in sizeAnnotations {
            let lower = max(0, annotation.range.lowerBound)
            let upper = min(scales.count, annotation.range.upperBound)
            guard lower < upper, annotation.scale > 0 else { continue }
            for i in lower..<upper { scales[i] *= annotation.scale }
        }
        // 割り注は本文の半分の大きさに決まっている
        for range in warichuRanges {
            let lower = max(0, range.lowerBound)
            let upper = min(scales.count, range.upperBound)
            guard lower < upper else { continue }
            for i in lower..<upper { scales[i] = STWarichuLayout.fontScale }
        }
        return scales
    }

    /// 範囲ごとの指定を、文字ごとの字面の配列にする。
    private func makeStyles() -> [STTextStyle] {
        guard !styleAnnotations.isEmpty, let text, !text.isEmpty else { return [] }
        var styles = [STTextStyle](repeating: [], count: text.count)
        for annotation in styleAnnotations {
            let lower = max(0, annotation.range.lowerBound)
            let upper = min(styles.count, annotation.range.upperBound)
            guard lower < upper else { continue }
            // 範囲が重なっていたら重ねがけにする
            for i in lower..<upper { styles[i].formUnion(annotation.style) }
        }
        return styles
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
        var rubyFontScale: CGFloat
        var rubyAnnotations: [STRubyAnnotation]
        var emphasisAnnotations: [STEmphasisAnnotation]
        var styleAnnotations: [STStyleAnnotation]
        var lineAnnotations: [STLineAnnotation]
        var sizeAnnotations: [STSizeAnnotation]
        var indentAnnotations: [STIndentAnnotation]
        var warichuRanges: [Range<Int>]
        var tateChuYokoRanges: [Range<Int>]
        var allowsRubyOverhang: Bool
        var images: [STImageAnnotation]
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
            fonts: fonts,
            rubyFontScale: rubyFontScale,
            rubyAnnotations: rubyAnnotations,
            emphasisAnnotations: emphasisAnnotations,
            styleAnnotations: styleAnnotations,
            lineAnnotations: lineAnnotations,
            sizeAnnotations: sizeAnnotations,
            indentAnnotations: indentAnnotations,
            warichuRanges: warichuRanges,
            tateChuYokoRanges: tateChuYokoRanges,
            allowsRubyOverhang: allowsRubyOverhang,
            images: imageAnnotations)
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
            // ルビは親文字のレイアウトが決まってから、その脇に置く
            rubyRuns = rubyLayout?.runs(context: context) ?? []
            pages = makePages()
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
        /// 親文字ではなくルビ (文字の大きさが違うので別のまとまりにする)。
        let isRuby: Bool
        /// 字面の変化 (太字・斜体)。フォントが違うので別のまとまりにする。
        let style: STTextStyle
        /// 文字の大きさ。これも違えば別のまとまりになる。
        let fontSize: CGFloat
        let ctFont: CTFont
        var glyphs: [CGGlyph]
        var positions: [CGPoint]
        var frames: [CGRect]
    }

    var drawBuckets = [DrawBucket]()

    /// 同じフォント・同じ向きのグリフをまとめて描けるように、まとまりを探して (無ければ作って) 返す。
    private func bucketIndex(
        in drawBuckets: inout [DrawBucket],
        fontId: Int,
        isClockwise: Bool,
        needsToFlip: Bool,
        isRuby: Bool,
        style: STTextStyle,
        fontSize: CGFloat
    ) -> Int {
        if let index = drawBuckets.firstIndex(where: {
            $0.fontId == fontId && $0.isClockwise == isClockwise && $0.needsToFlip == needsToFlip
                && $0.isRuby == isRuby && $0.style == style && $0.fontSize == fontSize
        }) {
            return index
        }
        let ctFont = context.fontManager.ctFont(fontId: fontId, size: fontSize, isClockwise: isClockwise, style: style)
        drawBuckets.append(DrawBucket(
            fontId: fontId, isClockwise: isClockwise, needsToFlip: needsToFlip, isRuby: isRuby,
            style: style, fontSize: fontSize, ctFont: ctFont, glyphs: [], positions: [], frames: []))
        return drawBuckets.count - 1
    }

    private func createDrawBcukets() {
        // Decide page
        let lineRange: Range<Int>? = isPaged ? pageLineRange : nil
        let translation = contentTranslation

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
            let bucketIndex = bucketIndex(
                in: &drawBuckets, fontId: run.fontId, isClockwise: isClockwise, needsToFlip: needsToFlip,
                isRuby: false, style: run.style, fontSize: run.fontSize)

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

        // Add ruby (EbookViewer)
        for run in rubyRuns {
            if let lineRange {
                guard lineRange.contains(run.line) else { continue }
            }
            let index = bucketIndex(
                in: &drawBuckets, fontId: run.fontId, isClockwise: run.isClockwise, needsToFlip: run.needsToFlip,
                isRuby: true, style: [], fontSize: context.adjustFontSize * rubyFontScale)
            drawBuckets[index].glyphs.append(run.glyph)
            drawBuckets[index].positions.append(CGPoint(x: run.position.x + translation.x, y: run.position.y + translation.y))
            drawBuckets[index].frames.append(run.frame.offsetBy(dx: translation.x, dy: translation.y))
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

    /// 傍線 (下線・左傍線・取り消し線) を描く。
    /// 字面を変えずに引くものなので、グリフとは別に、続いている文字をまとめて 1 本にする。
    private func drawLines(_ dirtyRect: CGRect) {
        guard !lineAnnotations.isEmpty, let cgContext = UIGraphicsGetCurrentContext() else { return }
        cgContext.setStrokeColor(context.textColor.cgColor)
        let lineRange: Range<Int>? = isPaged ? pageLineRange : nil
        let translation = contentTranslation
        let thickness = lineThickness

        for annotation in lineAnnotations {
            let lower = max(0, annotation.range.lowerBound)
            let upper = min(context.runs.count, annotation.range.upperBound)
            guard lower < upper else { continue }

            // 行ごとに 1 本ずつ引く
            var group: CGRect = .null
            var previousLine = -1

            func flush() {
                guard !group.isNull else { return }
                let box = group.offsetBy(dx: translation.x, dy: translation.y)
                let (from, to) = endpoints(of: box, for: annotation.position, thickness: thickness)
                cgContext.strokeTextLine(
                    from: from, to: to, thickness: thickness, style: annotation.style,
                    isVertical: context.direction == .tbRl)
                group = .null
            }

            for index in lower..<upper {
                let run = context.runs[index]
                guard !run.char.isNewline else { continue }
                if let lineRange {
                    guard lineRange.contains(run.line) else { continue }
                } else if run.isHidden {
                    continue
                }
                if run.line != previousLine { flush() }
                group = group.isNull ? run.frame : group.union(run.frame)
                previousLine = run.line
            }
            flush()
        }
    }

    /// 文字のかたまりに対して、線を引く始点と終点。
    private func endpoints(
        of box: CGRect, for position: STLinePosition, thickness: CGFloat
    ) -> (CGPoint, CGPoint) {
        let gap = thickness * 1.5
        switch (context.direction, position) {
        case (.tbRl, .underline):
            let x = box.maxX + gap
            return (.init(x: x, y: box.minY), .init(x: x, y: box.maxY))
        case (.tbRl, .overline):
            let x = box.minX - gap
            return (.init(x: x, y: box.minY), .init(x: x, y: box.maxY))
        case (.tbRl, .strikethrough):
            return (.init(x: box.midX, y: box.minY), .init(x: box.midX, y: box.maxY))
        case (.lrTb, .underline):
            let y = box.maxY + gap
            return (.init(x: box.minX, y: y), .init(x: box.maxX, y: y))
        case (.lrTb, .overline):
            let y = box.minY - gap
            return (.init(x: box.minX, y: y), .init(x: box.maxX, y: y))
        case (.lrTb, .strikethrough):
            return (.init(x: box.minX, y: box.midY), .init(x: box.maxX, y: box.midY))
        }
    }

    /// 挿絵のページを、表示領域に収まる大きさで中央に描く。
    private func drawBlockImage(_ annotation: STImageAnnotation) {
        guard let cgContext = UIGraphicsGetCurrentContext() else { return }
        let rect = CGRect.fitting(aspectRatio: annotation.aspectRatio, in: bounds)
        cgContext.drawFlipped(annotation.image, in: rect)
    }

    /// 行の中に収める画像を、置き場所の 1 文字の上に描く。
    private func drawInlineImages(_ dirtyRect: CGRect) {
        guard !imageAnnotations.isEmpty, let cgContext = UIGraphicsGetCurrentContext() else { return }
        let lineRange: Range<Int>? = isPaged ? pageLineRange : nil
        let translation = contentTranslation
        for annotation in imageAnnotations where !annotation.isBlock {
            guard annotation.offset >= 0, annotation.offset < context.runs.count else { continue }
            let run = context.runs[annotation.offset]
            if let lineRange {
                guard lineRange.contains(run.line) else { continue }
            } else if run.isHidden {
                continue
            }
            let cell = run.frame.offsetBy(dx: translation.x, dy: translation.y)
            cgContext.drawFlipped(annotation.image, in: .fitting(aspectRatio: annotation.aspectRatio, in: cell))
        }
    }

    open override func draw(_ dirtyRect: CGRect) {
        // 挿絵のページは画像だけを描く
        if isPaged, case .image(let index) = currentPage, index < imageAnnotations.count {
            drawBlockImage(imageAnnotations[index])
            return
        }

        // Draw
        drawLines(dirtyRect)
        drawInlineImages(dirtyRect)
        drawGlyphs(dirtyRect)

        // For test
        //drawFrames(dirtyRect)
    }
}
