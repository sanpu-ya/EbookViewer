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

    public init(range: Range<Int>, style: STTextStyle) {
        self.range = range
        self.style = style
    }
}

/// 圏点 (傍点) を打つ範囲。
public struct STEmphasisAnnotation: Equatable, Sendable {
    /// 範囲 (STLabel.text の Character 単位、0 始まり)。
    public var range: Range<Int>
    /// 打つ印。既定は「ゴマ点」。
    public var mark: String

    /// ゴマ点 (CSS の text-emphasis-style: filled sesame)。
    public static let sesame = "\u{FE45}"
    /// 白ゴマ点。
    public static let openSesame = "\u{FE46}"
    /// 黒丸。
    public static let dot = "\u{25CF}"
    /// 白丸。
    public static let openDot = "\u{25CB}"

    public init(range: Range<Int>, mark: String = STEmphasisAnnotation.sesame) {
        self.range = range
        self.mark = mark
    }

    /// 圏点を 1 文字ずつの注記にする。
    ///
    /// 圏点はふつう親文字の上 (縦書きでは右) に打つが、そこにルビがあるときは
    /// CSS の text-emphasis と同じく反対側へ逃がす。
    func marks(avoiding ruby: [STRubyAnnotation]) -> [STRubyAnnotation] {
        range.map { index in
            let hasRubyOver = ruby.contains {
                $0.position == .over && !$0.text.isEmpty && $0.range.contains(index)
            }
            return STRubyAnnotation(
                range: index..<(index + 1), text: mark, position: hasRubyOver ? .under : .over)
        }
    }
}
