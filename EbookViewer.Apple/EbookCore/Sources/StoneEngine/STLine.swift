//
//  STLine.swift
//  EbookViewer
//
//  stone_engine に傍線 (下線・左傍線・取り消し線) を足すための追加。upstream には無い。
//
//  線は字面を変えないので、フォントは差し替えずに draw(_:) で引く。続いている文字を
//  まとめて 1 本にし、行が変わるところで切る。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 線の引き方。青空文庫の注記 (傍線・二重傍線・鎖線・破線・波線) に対応する。
public enum STLineStyle: Sendable, Equatable, CaseIterable {
    /// 実線。
    case solid
    /// 二重線。
    case double
    /// 鎖線 (点線)。
    case dotted
    /// 破線。
    case dashed
    /// 波線。
    case wave
}

/// 線を引く位置。
public enum STLinePosition: Sendable, Equatable, CaseIterable {
    /// 傍線。縦書きでは文字の右、横書きでは下 (HTML の text-decoration: underline)。
    case underline
    /// 左傍線。縦書きでは文字の左、横書きでは上 (HTML の overline)。
    case overline
    /// 取り消し線。文字の中央 (HTML の line-through)。
    case strikethrough

    /// 行の脇のどちら側に空きが要るか。取り消し線は文字に重なるので要らない。
    func side(for direction: STDirection) -> STRubyPosition? {
        switch self {
        case .underline: return direction == .tbRl ? .over : .under
        case .overline: return direction == .tbRl ? .under : .over
        case .strikethrough: return nil
        }
    }
}

/// 線を引く範囲。
public struct STLineAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    public var style: STLineStyle
    public var position: STLinePosition

    public init(range: Range<Int>, style: STLineStyle = .solid, position: STLinePosition = .underline) {
        self.range = range
        self.style = style
        self.position = position
    }
}

extension CGContext {
    /// 線を 1 本引く。`style` に応じて二重線・点線・破線・波線にする。
    ///
    /// - Parameters:
    ///   - from: 線の始点。
    ///   - to: 線の終点。
    ///   - thickness: 線の太さ。
    ///   - isVertical: 線が縦方向に伸びるか (縦書きの傍線)。二重線をずらす向きに使う。
    func strokeTextLine(
        from start: CGPoint, to end: CGPoint, thickness: CGFloat, style: STLineStyle, isVertical: Bool
    ) {
        saveGState()
        setLineWidth(thickness)
        setLineCap(.butt)
        defer { restoreGState() }

        switch style {
        case .solid:
            strokeLine(from: start, to: end)
        case .double:
            // 線の太さぶん離して 2 本引く
            let gap = thickness * 2
            let dx = isVertical ? gap * 0.5 : 0
            let dy = isVertical ? 0 : gap * 0.5
            strokeLine(from: .init(x: start.x - dx, y: start.y - dy), to: .init(x: end.x - dx, y: end.y - dy))
            strokeLine(from: .init(x: start.x + dx, y: start.y + dy), to: .init(x: end.x + dx, y: end.y + dy))
        case .dotted:
            setLineDash(phase: 0, lengths: [thickness, thickness])
            strokeLine(from: start, to: end)
        case .dashed:
            setLineDash(phase: 0, lengths: [thickness * 3, thickness * 2])
            strokeLine(from: start, to: end)
        case .wave:
            strokeWave(from: start, to: end, amplitude: thickness * 1.5, isVertical: isVertical)
        }
    }

    private func strokeLine(from start: CGPoint, to end: CGPoint) {
        beginPath()
        move(to: start)
        addLine(to: end)
        strokePath()
    }

    /// 波線。線に直交する向きへ振れる山を並べる。
    private func strokeWave(from start: CGPoint, to end: CGPoint, amplitude: CGFloat, isVertical: Bool) {
        let length = isVertical ? end.y - start.y : end.x - start.x
        guard length > 0, amplitude > 0 else { return }
        // 山 1 つの長さ。短すぎると波に見えないので下限を置く
        let period = max(amplitude * 4, 4)
        beginPath()
        move(to: start)
        var position: CGFloat = 0
        var sign: CGFloat = 1
        while position < length {
            let step = min(period, length - position)
            let next = position + step
            let control = position + step * 0.5
            if isVertical {
                addQuadCurve(
                    to: .init(x: start.x, y: start.y + next),
                    control: .init(x: start.x + amplitude * sign, y: start.y + control))
            } else {
                addQuadCurve(
                    to: .init(x: start.x + next, y: start.y),
                    control: .init(x: start.x + control, y: start.y + amplitude * sign))
            }
            position = next
            sign *= -1
        }
        strokePath()
    }
}
