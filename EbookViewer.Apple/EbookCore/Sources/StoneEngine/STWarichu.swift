//
//  STWarichu.swift
//  EbookViewer
//
//  stone_engine に割り注を足すための追加。upstream には無い。
//
//  割り注は、本文 1 行ぶんの幅の中に、半分の大きさの文字を 2 行に組んだものである。
//  stone_engine は 1 本の流れとして組むので、
//
//  1. まず半分の大きさで 1 行に組ませ (ふつうの組版)
//  2. 2 行に積んだときに必要な長さまで字間を詰めて組み直し
//  3. 前半と後半を 2 行に積み直す
//
//  という順で作る。2 は親文字を広げるときと同じ `STContext.spacings` のしくみを使う。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 割り注を 2 行に積む。
enum STWarichuLayout {
    /// 割り注の文字の大きさ (本文に対する比)。
    static let fontScale: CGFloat = 0.5

    /// 2 行に積んだときの長さまで詰めるための字間。詰める必要が無ければ空の配列。
    static func spacings(context: STContext, ranges: [Range<Int>]) -> [STSpacing] {
        guard !ranges.isEmpty, !context.runs.isEmpty else { return [] }
        var spacings = [STSpacing](repeating: .zero, count: context.runs.count)
        var needsToShrink = false
        for range in ranges {
            guard let indexes = usableIndexes(context: context, range: range) else { continue }
            let extents = indexes.map { naturalExtent(context: context, at: $0) }
            let total = extents.reduce(0, +)
            // 1 行目 (前半) の長さが、積んだあとに要る長さ
            let rowLength = (indexes.count + 1) / 2
            let needed = extents.prefix(rowLength).reduce(0, +)
            let shrink = total - needed
            guard shrink > 0.5 else { continue }
            let perRun = shrink / CGFloat(indexes.count)
            for index in indexes {
                spacings[index] = STSpacing(before: 0, after: -perRun)
            }
            needsToShrink = true
        }
        return needsToShrink ? spacings : []
    }

    /// 組み終わった本文の割り注を、前半と後半の 2 行に積み直す。
    static func apply(context: STContext, ranges: [Range<Int>]) {
        guard !ranges.isEmpty, !context.runs.isEmpty else { return }
        for range in ranges {
            guard let indexes = usableIndexes(context: context, range: range) else { continue }
            stack(context: context, indexes: indexes)
        }
    }

    /// 2 行に積める割り注の run。1 行に収まらなかったもの (行をまたいだもの) は、
    /// 積み直すと読み順が崩れるので触らない。
    private static func usableIndexes(context: STContext, range: Range<Int>) -> [Int]? {
        let lower = max(0, range.lowerBound)
        let upper = min(context.runs.count, range.upperBound)
        guard lower < upper else { return nil }
        let indexes = (lower..<upper).filter { !context.runs[$0].char.isNewline }
        guard indexes.count > 1 else { return nil }
        let line = context.runs[indexes[0]].line
        guard indexes.allSatisfy({ context.runs[$0].line == line }) else { return nil }
        return indexes
    }

    /// 字間を詰める前の、文字が進む向きの長さ。
    private static func naturalExtent(context: STContext, at index: Int) -> CGFloat {
        let frame = context.runs[index].frame
        let spacing = context.spacing(at: index)
        return (context.direction == .tbRl ? frame.height : frame.width) - spacing.total
    }

    private static func stack(context: STContext, indexes: [Int]) {
        let isVertical = context.direction == .tbRl
        // 本文 1 文字ぶんの枠の、行が積まれる向きの始まり
        let first = context.runs[indexes[0]]
        let centering = (context.adjustFontSize - first.fontSize) * 0.5
        let blockOrigin = (isVertical ? first.frame.minX : first.frame.minY) - centering
        let half = context.adjustFontSize * fontScale
        // 文字が進む向きの、割り注の始まり
        let inlineOrigin = isVertical
            ? indexes.map({ context.runs[$0].frame.minY }).min()!
            : indexes.map({ context.runs[$0].frame.minX }).min()!

        let rowLength = (indexes.count + 1) / 2
        var inline: [CGFloat] = [inlineOrigin, inlineOrigin]
        for (position, index) in indexes.enumerated() {
            let row = position < rowLength ? 0 : 1
            // 縦書きは 1 行目が右 (行は右から左へ進む)、横書きは 1 行目が上
            let block = isVertical
                ? blockOrigin + (row == 0 ? half : 0)
                : blockOrigin + (row == 0 ? 0 : half)
            let extent = naturalExtent(context: context, at: index)
            let frame = context.runs[index].frame
            let origin = isVertical
                ? CGPoint(x: block, y: inline[row])
                : CGPoint(x: inline[row], y: block)
            let delta = CGPoint(x: origin.x - frame.minX, y: origin.y - frame.minY)
            context.runs[index].position.x += delta.x
            context.runs[index].position.y += delta.y
            // 詰めたぶんを戻して、文字そのものの大きさの枠にする
            var stacked = frame.offsetBy(dx: delta.x, dy: delta.y)
            if isVertical { stacked.size.height = extent } else { stacked.size.width = extent }
            context.runs[index].frame = stacked
            inline[row] += extent
        }
    }
}
