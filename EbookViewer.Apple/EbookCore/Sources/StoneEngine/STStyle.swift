//
//  STStyle.swift
//  EbookViewer
//
//  stone_engine に強調表示 (太字・斜体・圏点) を足すための追加。upstream には無い。
//
//  太字と斜体は文字ごとにフォントを差し替えて表す。圏点 (傍点) は字面を変えずに
//  文字の脇へ印を打つものなので、ルビと同じしくみ (STRuby.swift) に載せている。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 文字の字面の変化。
public struct STTextStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = STTextStyle(rawValue: 1 << 0)
    /// 斜体。日本語フォントには斜体が無いことが多く、その場合は正体のままになる。
    public static let italic = STTextStyle(rawValue: 1 << 1)
}

/// 範囲と、そこにかける字面の変化。
public struct STStyleAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    public var style: STTextStyle
    /// 字面を足すのではなく取り消すか (入れ子の中で太字・斜体を元に戻すのに使う)。
    public var removes: Bool

    public init(range: Range<Int>, style: STTextStyle, removes: Bool = false) {
        self.range = range
        self.style = style
        self.removes = removes
    }
}

/// 文字の大きさを変える範囲。
public struct STSizeAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// ふつうの文字に対する比 (1.4 なら 1.4 倍)。
    public var scale: CGFloat

    public init(range: Range<Int>, scale: CGFloat) {
        self.range = range
        self.scale = scale
    }
}

/// 字下げ・地付きにする範囲 (青空文庫の「字下げ」「地付き」「地寄せ」)。
public struct STIndentAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// 行の始まりに空ける文字数。
    public var head: CGFloat
    /// 折り返した行の始まりに空ける文字数 (青空文庫の「折り返して N 字下げ」)。
    /// nil なら折り返した行も `head` と同じだけ下げる。
    public var hanging: CGFloat?
    /// 行末へ寄せるなら、行の終わりに空ける文字数。寄せないなら nil。
    public var tail: CGFloat?
    /// 1 行に入れる文字数 (青空文庫の「字詰め」)。決めないなら nil。
    public var length: CGFloat?
    /// 行を中央にそろえるか (`text-align: center`)。
    public var centered: Bool

    public init(
        range: Range<Int>, head: CGFloat = 0, hanging: CGFloat? = nil, tail: CGFloat? = nil,
        length: CGFloat? = nil, centered: Bool = false
    ) {
        self.range = range
        self.head = head
        self.hanging = hanging
        self.tail = tail
        self.length = length
        self.centered = centered
    }
}

/// 上付き・下付きにする範囲 (青空文庫の「上付き小文字」「下付き小文字」と
/// 「行右小書き」「行左小書き」)。
///
/// 文字を小さくするのは `STSizeAnnotation` の役目で、こちらは小さくした文字を
/// 1 文字ぶんの枠のどちら側へ寄せるかだけを決める。
public struct STShiftAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// 寄せる側。`.over` が上付き (縦書きでは行の右)、`.under` が下付き (行の左)。
    public var side: STRubyPosition

    public init(range: Range<Int>, side: STRubyPosition) {
        self.range = range
        self.side = side
    }
}

/// 縦組みでの文字の向きを決める範囲 (CSS の text-orientation)。
public struct STOrientationAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// `.upright` は倒さず正立、`.sideways` はかならず倒す。
    public var orientation: STTextOrientation

    public init(range: Range<Int>, orientation: STTextOrientation) {
        self.range = range
        self.orientation = orientation
    }
}

/// 圏点 (傍点) を打つ範囲。
public struct STEmphasisAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// 打つ印。既定は「ゴマ点」。
    public var mark: String
    /// 親文字のどちら側に打つか。青空文庫の「左に傍点」は `.under`。
    public var position: STRubyPosition

    /// ゴマ点 (CSS の text-emphasis-style: filled sesame)。
    public static let sesame = "\u{FE45}"
    /// 白ゴマ点。
    public static let openSesame = "\u{FE46}"
    /// 黒丸。
    public static let dot = "\u{25CF}"
    /// 白丸。
    public static let openDot = "\u{25CB}"

    public init(
        range: Range<Int>,
        mark: String = STEmphasisAnnotation.sesame,
        position: STRubyPosition = .over
    ) {
        self.range = range
        self.mark = mark
        self.position = position
    }

    /// 圏点を 1 文字ずつの注記にする。
    ///
    /// 圏点はふつう親文字の上 (縦書きでは右) に打つが、そこにルビがあるときは
    /// CSS の text-emphasis と同じく反対側へ逃がす。
    func marks(avoiding ruby: [STRubyAnnotation]) -> [STRubyAnnotation] {
        range.map { index in
            let isTaken = ruby.contains {
                $0.position == position && !$0.text.isEmpty && $0.range.contains(index)
            }
            let side: STRubyPosition = isTaken ? (position == .over ? .under : .over) : position
            return STRubyAnnotation(range: index..<(index + 1), text: mark, position: side)
        }
    }
}
