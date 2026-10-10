//
//  STRuby.swift
//  EbookViewer
//
//  stone_engine にルビ (振り仮名) を足すための追加。upstream には無い。
//
//  ルビは親文字の脇 — 縦書きなら右、横書きなら上 — の行間に置く。行送りが
//  親文字の大きさより大きいぶんの空きを使うので、行分割や禁則処理には手を入れない。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 親文字の範囲とそれに振るルビ。
public struct STRubyAnnotation: Equatable, Sendable {
    /// 親文字の範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// ルビ (振り仮名)。
    public var text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
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
enum STRubyLayout {
    /// 親文字のレイアウトが済んだ `context` に対して、ルビの run を作る。
    /// - Parameter fontScale: 親文字に対するルビの大きさの比 (0.5 なら半分)。
    static func runs(context: STContext, annotations: [STRubyAnnotation], fontScale: CGFloat) -> [STRubyRun] {
        guard !annotations.isEmpty, !context.runs.isEmpty, fontScale > 0 else { return [] }
        let sub = makeSubContext(context, fontScale: fontScale)
        var runs: [STRubyRun] = []
        for annotation in annotations {
            appendRuns(for: annotation, context: context, sub: sub, into: &runs)
        }
        return runs
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

    /// ルビ 1 つぶんを組んで、親文字の行ごとに置く。
    private static func appendRuns(
        for annotation: STRubyAnnotation,
        context: STContext,
        sub: STContext,
        into runs: inout [STRubyRun]
    ) {
        guard !annotation.text.isEmpty else { return }
        let lower = max(0, annotation.range.lowerBound)
        let upper = min(context.runs.count, annotation.range.upperBound)
        guard lower < upper else { return }

        // 親文字が行をまたぐことがあるので、行ごとに分ける
        let segments = baseSegments(context: context, range: lower..<upper)
        guard !segments.isEmpty else { return }

        // ルビを親文字の文字数に比例して行へ割り振る
        let reading = Array(annotation.text)
        let baseCount = upper - lower
        var consumed = 0
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let share: Int
            if isLast {
                share = reading.count - consumed
            } else {
                let exact = Double(reading.count) * Double(segment.count) / Double(baseCount)
                share = min(reading.count - consumed, max(1, Int(exact.rounded())))
            }
            guard share > 0 else { continue }
            let piece = String(reading[consumed..<(consumed + share)])
            consumed += share
            appendRuns(reading: piece, over: segment, context: context, sub: sub, into: &runs)
        }
    }

    /// 親文字の範囲を、同じ行に載っている run のかたまりに分ける。
    private static func baseSegments(context: STContext, range: Range<Int>) -> [Range<Int>] {
        var segments: [Range<Int>] = []
        var start = range.lowerBound
        for i in range {
            guard i > start else { continue }
            if context.runs[i].line != context.runs[start].line {
                segments.append(start..<i)
                start = i
            }
        }
        segments.append(start..<range.upperBound)
        return segments
    }

    /// 1 行ぶんのルビを組んで、その行の親文字の脇に置く。
    private static func appendRuns(
        reading: String,
        over segment: Range<Int>,
        context: STContext,
        sub: STContext,
        into runs: inout [STRubyRun]
    ) {
        // ルビを 1 行に組む
        switch sub.direction {
        case .tbRl: sub.renderSize = CGSize(width: sub.fontSize, height: unbounded)
        case .lrTb: sub.renderSize = CGSize(width: unbounded, height: sub.fontSize)
        }
        sub.adjustFontScale = 1
        STParser(context: sub).parse(text: reading)
        STLayout(context: sub).layout()
        let rubyRuns = sub.runs.filter { !$0.char.isNewline }
        guard !rubyRuns.isEmpty else { return }

        // 親文字とルビのそれぞれの広がり
        let base = bounds(of: context.runs[segment], direction: sub.direction)
        let ruby = bounds(of: rubyRuns, direction: sub.direction)
        let line = context.runs[segment.lowerBound].line

        // 親文字の中央にそろえ、行の端からはみ出さないように寄せる
        let inlineLimit = sub.direction == .tbRl ? context.renderSize.height : context.renderSize.width
        var inlineStart = base.inlineMin + (base.inlineLength - ruby.inlineLength) * 0.5
        if ruby.inlineLength <= inlineLimit {
            inlineStart = min(max(0, inlineStart), inlineLimit - ruby.inlineLength)
        } else {
            inlineStart = 0
        }

        // 縦書きは親文字の右、横書きは親文字の上に置く
        let translation: CGPoint
        switch sub.direction {
        case .tbRl:
            translation = CGPoint(x: base.blockMax - ruby.blockMin, y: inlineStart - ruby.inlineMin)
        case .lrTb:
            translation = CGPoint(x: inlineStart - ruby.inlineMin, y: base.blockMin - ruby.blockLength - ruby.blockMin)
        }

        for run in rubyRuns {
            runs.append(STRubyRun(
                fontId: run.fontId,
                glyph: run.glyph,
                position: CGPoint(x: run.position.x + translation.x, y: run.position.y + translation.y),
                frame: run.frame.offsetBy(dx: translation.x, dy: translation.y),
                isClockwise: sub.isClockwise(run: run),
                needsToFlip: sub.fontManager.needsToFlip(fontId: run.fontId),
                line: line))
        }
    }

    /// run の並びの、文字が進む向き (inline) と行が積まれる向き (block) それぞれの広がり。
    /// 縦書き (tbRl) は inline = y・block = x、横書き (lrTb) は inline = x・block = y。
    private struct Bounds {
        var inlineMin: CGFloat
        var inlineLength: CGFloat
        var blockMin: CGFloat
        var blockMax: CGFloat
        var blockLength: CGFloat { blockMax - blockMin }
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
