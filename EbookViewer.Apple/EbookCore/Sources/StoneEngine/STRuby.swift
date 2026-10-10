//
//  STRuby.swift
//  EbookViewer
//
//  stone_engine にルビ (振り仮名) を足すための追加。upstream には無い。
//
//  ルビは親文字の脇 — 縦書きなら右、横書きなら上 — の行間に置く。行送りが
//  親文字の大きさより大きいぶんの空きを使うので、行分割や禁則処理には手を入れない。
//  ルビのほうが長いときだけ、親文字の字間を広げてルビの長さに合わせる。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// ルビを親文字のどちら側に置くか。
public enum STRubyPosition: Sendable, Equatable, CaseIterable {
    /// 親文字の上 — 縦書きでは右。ふつうのルビ。
    case over
    /// 親文字の下 — 縦書きでは左。二段ルビの 2 段目 (読み以外の注記など)。
    case under
}

/// 親文字の範囲とそれに振るルビ。
public struct STRubyAnnotation: Equatable, Sendable {
    /// 親文字の範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// ルビ (振り仮名)。
    public var text: String
    /// 親文字のどちら側に置くか。
    public var position: STRubyPosition

    public init(range: Range<Int>, text: String, position: STRubyPosition = .over) {
        self.range = range
        self.text = text
        self.position = position
    }
}

/// 文字の前後に足す空き。
public struct STSpacing: Equatable, Sendable {
    public var before: CGFloat
    public var after: CGFloat

    public static let zero = STSpacing(before: 0, after: 0)

    public var total: CGFloat { before + after }

    public init(before: CGFloat, after: CGFloat) {
        self.before = before
        self.after = after
    }
}

/// 描画位置まで決まったルビの 1 文字。親文字の run (`STRun`) に対応するもの。
struct STRubyRun {
    var fontId: Int
    var glyph: CGGlyph
    var position: CGPoint
    var frame: CGRect
    var isClockwise: Bool
    var needsToFlip: Bool
    /// 親文字が載っている行。どのページに描くかを決めるのに使う。
    var line: Int
}

/// ルビを組んで、親文字の脇に置く。
///
/// ルビ自体の組版 (グリフの選択、縦書き用グリフへの置換、前進幅) は、親文字と同じ設定の
/// 小さな `STContext` を作って `STParser` / `STLayout` に任せる。こうすると縦書きでの
/// 字形の差し替えや欧文の回転がそのまま効き、ここで書き直す必要がない。
///
/// 使う順番は次のとおり。親文字を広げると行分割が変わるので、組版は 2 回に分かれる。
///
/// 1. 親文字をふつうに組む (`STLayout`)
/// 2. `init` でルビを組む
/// 3. `spacings(context:)` で親文字を広げる量を求め、空でなければ親文字を組み直す
/// 4. `runs(context:)` でルビの置き場所を決める
struct STRubyLayout {
    /// ルビ 1 つを組んだ結果。
    private struct Prepared {
        var annotation: STRubyAnnotation
        /// ルビの run。1 文字 = 1 run で、改行は含まない。
        var runs: [STRun]
        /// 文字が進む向きのルビの長さ。
        var inlineLength: CGFloat
        var isClockwise: [Bool]
        var needsToFlip: [Bool]
    }

    private let prepared: [Prepared]
    private let direction: STDirection
    /// 隣の文字にルビを掛けてよいか。
    private let allowsOverhang: Bool
    /// 片側に掛けてよい最大の量 (ルビ 1 文字ぶん)。
    private let overhangLimit: CGFloat

    /// ルビをそれぞれ 1 行に組む。
    /// - Parameter fontScale: 親文字に対するルビの大きさの比 (0.5 なら半分)。
    init(context: STContext, annotations: [STRubyAnnotation], fontScale: CGFloat, allowsOverhang: Bool = true) {
        direction = context.direction
        self.allowsOverhang = allowsOverhang
        overhangLimit = context.adjustFontSize * fontScale
        guard !annotations.isEmpty, fontScale > 0 else {
            prepared = []
            return
        }
        let sub = Self.makeSubContext(context, fontScale: fontScale)
        var prepared: [Prepared] = []
        for annotation in annotations {
            guard !annotation.text.isEmpty else { continue }
            let runs = Self.layout(reading: annotation.text, sub: sub)
            guard !runs.isEmpty else { continue }
            prepared.append(Prepared(
                annotation: annotation,
                runs: runs,
                inlineLength: Self.bounds(of: runs, direction: sub.direction).inlineLength,
                isClockwise: runs.map { sub.isClockwise(run: $0) },
                needsToFlip: runs.map { sub.fontManager.needsToFlip(fontId: $0.fontId) }))
        }
        self.prepared = prepared
    }

    // MARK: - 親文字を広げる

    /// ルビのほうが長い親文字を、ルビの長さまで広げるための字間を返す。
    /// 広げる必要がどこにも無ければ空の配列を返す。
    ///
    /// 空きは JIS X 4051 の配置に倣い、親文字の外側が内側の半分になるように配る
    /// (N 文字なら 0.5 : 1 : … : 1 : 0.5)。1 文字あたり前後に `余り / 2N` ずつ入れると
    /// この配分になる。
    func spacings(context: STContext) -> [STSpacing] {
        guard !prepared.isEmpty, !context.runs.isEmpty else { return [] }
        let annotated = annotatedIndexes()
        var spacings = [STSpacing](repeating: .zero, count: context.runs.count)
        var needsToWiden = false
        for ruby in prepared {
            guard let range = Self.baseRange(ruby.annotation, in: context) else { continue }
            let overhang = overhangs(for: ruby, range: range, context: context, annotated: annotated)

            // 掛けても収まらないぶんだけ親文字を広げる。1pt に満たない差のために組み直さない
            let extra = overhang.extra - overhang.before - overhang.after
            guard extra > 1 else { continue }
            let half = extra / CGFloat(range.count * 2)
            for i in range {
                // 二段ルビでは同じ親文字に 2 つのルビが付く。長いほうに合わせる
                spacings[i] = STSpacing(before: max(spacings[i].before, half), after: max(spacings[i].after, half))
            }
            needsToWiden = true
        }
        return needsToWiden ? spacings : []
    }

    /// ルビが親文字からはみ出す量と、その前後への振り分け (ルビの掛け)。
    ///
    /// 親文字を広げる量を決めるときと、実際に置くときの両方で使う。置くときは組み直したあとの
    /// 行割りで取り直すので、広げたことで行が変わっても置き場所がずれない。
    private func overhangs(
        for ruby: Prepared, range: Range<Int>, context: STContext, annotated: Set<Int>
    ) -> (extra: CGFloat, before: CGFloat, after: CGFloat) {
        let baseLength = range.reduce(CGFloat.zero) {
            $0 + Self.inlineExtent(of: context.runs[$1].frame, direction: direction)
        }
        let extra = ruby.inlineLength - baseLength
        guard extra > 0 else { return (0, 0, 0) }
        var before = min(extra * 0.5, overhangAllowance(at: range.lowerBound - 1, baseAt: range.lowerBound,
                                                        context: context, annotated: annotated))
        let after = min(extra - before, overhangAllowance(at: range.upperBound, baseAt: range.upperBound - 1,
                                                          context: context, annotated: annotated))
        before = min(extra - after, before)
        return (extra, before, after)
    }

    /// 親文字の隣にルビを掛けてよい量。掛けられないなら 0。
    ///
    /// JIS X 4051 に倣い、掛けてよいのは隣が**仮名**のときだけで、量はルビ 1 文字ぶんまで。
    /// 行をまたぐ場合と、隣にもルビや圏点が付いている場合は掛けない。
    private func overhangAllowance(
        at index: Int, baseAt base: Int, context: STContext, annotated: Set<Int>
    ) -> CGFloat {
        guard allowsOverhang else { return 0 }
        guard index >= 0, index < context.runs.count else { return 0 }
        let neighbour = context.runs[index]
        guard !neighbour.char.isNewline else { return 0 }
        // 行が変わるところでは掛けない
        guard neighbour.line == context.runs[base].line else { return 0 }
        guard !annotated.contains(index) else { return 0 }
        guard Self.allowsOverhang(over: neighbour.char) else { return 0 }
        return overhangLimit
    }

    /// ルビを掛けてよい文字か (仮名だけ)。漢字や欧文には掛けない。
    static func allowsOverhang(over char: Character) -> Bool {
        guard let u = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return false }
        switch u.value {
        case 0x3041...0x309F,  // ひらがな
             0x30A0...0x30FF,  // カタカナ (長音符・小書きを含む)
             0x31F0...0x31FF,  // カタカナ拡張
             0xFF66...0xFF9F:  // 半角カタカナ
            return true
        default:
            return false
        }
    }

    /// ルビや圏点が付いている文字の位置。ここには掛けない。
    private func annotatedIndexes() -> Set<Int> {
        var indexes = Set<Int>()
        for ruby in prepared where !ruby.annotation.text.isEmpty {
            indexes.formUnion(ruby.annotation.range)
        }
        return indexes
    }

    // MARK: - 置き場所を決める

    /// 組み終わった親文字の脇にルビを置く。
    func runs(context: STContext) -> [STRubyRun] {
        guard !prepared.isEmpty, !context.runs.isEmpty else { return [] }
        let annotated = annotatedIndexes()
        var runs: [STRubyRun] = []
        for ruby in prepared {
            guard let range = Self.baseRange(ruby.annotation, in: context) else { continue }
            // 組み直したあとの行割りで掛けを決める
            let overhang = overhangs(for: ruby, range: range, context: context, annotated: annotated)
            // 親文字が行をまたぐことがあるので行ごとに分け、ルビも親文字の文字数に比例して分ける
            let segments = Self.baseSegments(context: context, range: range)
            var consumed = 0
            for (index, segment) in segments.enumerated() {
                let share: Int
                if index == segments.count - 1 {
                    share = ruby.runs.count - consumed
                } else {
                    let exact = Double(ruby.runs.count) * Double(segment.count) / Double(range.count)
                    share = min(ruby.runs.count - consumed, max(1, Int(exact.rounded())))
                }
                guard share > 0 else { continue }
                let piece = consumed..<(consumed + share)
                consumed += share
                // 掛けは、前は最初の行だけ、後ろは最後の行だけに効く
                place(
                    ruby, piece: piece, over: segment, context: context,
                    overhangBefore: index == 0 ? overhang.before : 0,
                    overhangAfter: index == segments.count - 1 ? overhang.after : 0,
                    into: &runs)
            }
        }
        return runs
    }

    /// ルビの一部を、その行の親文字の脇に置く。
    private func place(
        _ ruby: Prepared,
        piece: Range<Int>,
        over segment: Range<Int>,
        context: STContext,
        overhangBefore: CGFloat,
        overhangAfter: CGFloat,
        into runs: inout [STRubyRun]
    ) {
        let pieceRuns = Array(ruby.runs[piece])
        guard !pieceRuns.isEmpty else { return }
        let base = Self.bounds(of: context.runs[segment], direction: direction)
        let rubyBounds = Self.bounds(of: pieceRuns, direction: direction)
        let line = context.runs[segment.lowerBound].line

        // 親文字 (掛けてよいぶんを足したもの) の中央にそろえ、行の端からはみ出さないように寄せる
        let inlineLimit = direction == .tbRl ? context.renderSize.height : context.renderSize.width
        let span = base.inlineLength + overhangBefore + overhangAfter
        var inlineStart = base.inlineMin - overhangBefore + (span - rubyBounds.inlineLength) * 0.5
        if rubyBounds.inlineLength <= inlineLimit {
            inlineStart = min(max(0, inlineStart), inlineLimit - rubyBounds.inlineLength)
        } else {
            inlineStart = 0
        }

        // over は親文字の上 (縦書きでは右)、under は下 (縦書きでは左) に置く
        let blockStart: CGFloat
        switch (direction, ruby.annotation.position) {
        case (.tbRl, .over): blockStart = base.blockMax
        case (.tbRl, .under): blockStart = base.blockMin - rubyBounds.blockLength
        case (.lrTb, .over): blockStart = base.blockMin - rubyBounds.blockLength
        case (.lrTb, .under): blockStart = base.blockMax
        }
        let translation: CGPoint
        switch direction {
        case .tbRl:
            translation = CGPoint(x: blockStart - rubyBounds.blockMin, y: inlineStart - rubyBounds.inlineMin)
        case .lrTb:
            translation = CGPoint(x: inlineStart - rubyBounds.inlineMin, y: blockStart - rubyBounds.blockMin)
        }

        for (offset, run) in pieceRuns.enumerated() {
            let index = piece.lowerBound + offset
            runs.append(STRubyRun(
                fontId: run.fontId,
                glyph: run.glyph,
                position: CGPoint(x: run.position.x + translation.x, y: run.position.y + translation.y),
                frame: run.frame.offsetBy(dx: translation.x, dy: translation.y),
                isClockwise: ruby.isClockwise[index],
                needsToFlip: ruby.needsToFlip[index],
                line: line))
        }
    }

    // MARK: - ルビ用のコンテキスト

    /// 親文字と同じフォント・同じ組方向で、文字を小さくしただけのコンテキスト。
    private static func makeSubContext(_ context: STContext, fontScale: CGFloat) -> STContext {
        let sub = STContext()
        sub.fontSize = context.adjustFontSize * fontScale
        sub.lineHeightScale = 1
        sub.direction = context.direction
        sub.textAlign = .leading
        sub.directionAlign = .start
        sub.isAllowedTateChuYoko = context.isAllowedTateChuYoko
        // ルビは 1 行に収めて自分で置くので、折り返しも禁則も約物の詰めも要らない
        sub.isKinsokuAvailable = false
        sub.isDividedByWords = false
        sub.punctuationMode = .whole
        for script in STScript.allCases {
            sub.fontManager.setFontNames(context.fontManager.fontNames(script: script), script: script)
            sub.fontManager.setFontScale(context.fontManager.fontScale(script: script), script: script)
        }
        sub.fontManager.refresh()
        return sub
    }

    /// 折り返させないための十分に大きな長さ。
    private static let unbounded: CGFloat = 1_000_000

    /// ルビを 1 行に組んで、その run を返す。
    private static func layout(reading: String, sub: STContext) -> [STRun] {
        switch sub.direction {
        case .tbRl: sub.renderSize = CGSize(width: sub.fontSize, height: unbounded)
        case .lrTb: sub.renderSize = CGSize(width: unbounded, height: sub.fontSize)
        }
        sub.adjustFontScale = 1
        STParser(context: sub).parse(text: reading)
        STLayout(context: sub).layout()
        return sub.runs.filter { !$0.char.isNewline }
    }

    // MARK: - 親文字の範囲

    /// 親文字の範囲を run の範囲にする。範囲外なら切り詰め、空になるなら nil。
    private static func baseRange(_ annotation: STRubyAnnotation, in context: STContext) -> Range<Int>? {
        let lower = max(0, annotation.range.lowerBound)
        let upper = min(context.runs.count, annotation.range.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    /// 親文字の範囲を、同じ行に載っている run のかたまりに分ける。
    private static func baseSegments(context: STContext, range: Range<Int>) -> [Range<Int>] {
        var segments: [Range<Int>] = []
        var start = range.lowerBound
        for i in range where i > start {
            if context.runs[i].line != context.runs[start].line {
                segments.append(start..<i)
                start = i
            }
        }
        segments.append(start..<range.upperBound)
        return segments
    }

    // MARK: - 広がり

    /// run の並びの、文字が進む向き (inline) と行が積まれる向き (block) それぞれの広がり。
    /// 縦書き (tbRl) は inline = y・block = x、横書き (lrTb) は inline = x・block = y。
    private struct Bounds {
        var inlineMin: CGFloat
        var inlineLength: CGFloat
        var blockMin: CGFloat
        var blockMax: CGFloat
        var blockLength: CGFloat { blockMax - blockMin }
    }

    private static func inlineExtent(of frame: CGRect, direction: STDirection) -> CGFloat {
        direction == .tbRl ? frame.height : frame.width
    }

    private static func bounds<S: Sequence<STRun>>(of runs: S, direction: STDirection) -> Bounds {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var found = false
        for run in runs {
            minX = min(minX, run.frame.minX)
            maxX = max(maxX, run.frame.maxX)
            minY = min(minY, run.frame.minY)
            maxY = max(maxY, run.frame.maxY)
            found = true
        }
        guard found else { return Bounds(inlineMin: 0, inlineLength: 0, blockMin: 0, blockMax: 0) }
        switch direction {
        case .tbRl: return Bounds(inlineMin: minY, inlineLength: maxY - minY, blockMin: minX, blockMax: maxX)
        case .lrTb: return Bounds(inlineMin: minX, inlineLength: maxX - minX, blockMin: minY, blockMax: maxY)
        }
    }
}
