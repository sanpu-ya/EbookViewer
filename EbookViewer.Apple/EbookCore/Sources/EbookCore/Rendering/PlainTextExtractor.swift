import Foundation

/// ルビを親文字のどちら側に置くか。
public enum RubyPosition: Sendable, Equatable {
    /// 親文字の上 — 縦書きでは右。ふつうのルビ。
    case over
    /// 親文字の下 — 縦書きでは左。二段ルビ (`<rtc>`) の 2 段目。
    case under
}

/// 親文字の範囲とそれに振るルビ (振り仮名)。
public struct RubyAnnotation: Equatable, Sendable {
    /// 親文字の範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    /// ルビ。
    public let text: String
    /// 親文字のどちら側に置くか。
    public let position: RubyPosition

    public init(range: Range<Int>, text: String, position: RubyPosition = .over) {
        self.range = range
        self.text = text
        self.position = position
    }
}

/// 文字の字面の変化。
public struct TextStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = TextStyle(rawValue: 1 << 0)
    public static let italic = TextStyle(rawValue: 1 << 1)
}

/// 範囲と、そこにかける字面の変化。
public struct StyleAnnotation: Equatable, Sendable {
    /// 範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    public let style: TextStyle

    public init(range: Range<Int>, style: TextStyle) {
        self.range = range
        self.style = style
    }
}

/// 線の引き方 (青空文庫の注記: 傍線・二重傍線・鎖線・破線・波線)。
public enum LineStyle: Sendable, Equatable {
    case solid, double, dotted, dashed, wave
}

/// 線を引く位置。
public enum LinePosition: Sendable, Equatable {
    /// 傍線 (縦書きでは文字の右、横書きでは下)。
    case underline
    /// 左傍線 (縦書きでは文字の左、横書きでは上)。
    case overline
    /// 取り消し線。
    case strikethrough
}

/// 線を引く範囲。
public struct LineAnnotation: Equatable, Sendable {
    public let range: Range<Int>
    public let style: LineStyle
    public let position: LinePosition

    public init(range: Range<Int>, style: LineStyle = .solid, position: LinePosition = .underline) {
        self.range = range
        self.style = style
        self.position = position
    }
}

/// 字下げ・地付きにする範囲 (青空文庫の「字下げ」「地付き」「地寄せ」)。
public struct IndentAnnotation: Equatable, Sendable {
    /// 範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    /// 行の始まりに空ける文字数。
    public let head: Double
    /// 折り返した行の始まりに空ける文字数 (青空文庫の「折り返して N 字下げ」)。
    /// nil なら折り返した行も `head` と同じだけ下げる。
    public let hanging: Double?
    /// 行末へ寄せるなら、行の終わりに空ける文字数。寄せないなら nil。
    public let tail: Double?

    public init(range: Range<Int>, head: Double = 0, hanging: Double? = nil, tail: Double? = nil) {
        self.range = range
        self.head = head
        self.hanging = hanging
        self.tail = tail
    }
}

/// 上付き・下付きにする範囲 (青空文庫の「上付き小文字」「下付き小文字」と
/// 「行右小書き」「行左小書き」)。文字を小さくするのは `SizeAnnotation` の役目で、
/// こちらは小さくした文字をどちら側へ寄せるかだけを表す。
public struct ShiftAnnotation: Equatable, Sendable {
    /// 範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    /// 寄せる側。`.over` が上付き (縦書きでは行の右)、`.under` が下付き (行の左)。
    public let position: RubyPosition

    public init(range: Range<Int>, position: RubyPosition) {
        self.range = range
        self.position = position
    }
}

/// 文字の大きさを変える範囲。
public struct SizeAnnotation: Equatable, Sendable {
    /// 範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    /// ふつうの文字に対する比。
    public let scale: Double

    public init(range: Range<Int>, scale: Double) {
        self.range = range
        self.scale = scale
    }
}

/// 圏点 (傍点) を打つ範囲。
public struct EmphasisAnnotation: Equatable, Sendable {
    /// 範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    /// 打つ印 (ゴマ点・丸など)。
    public let mark: String
    /// 親文字のどちら側に打つか。青空文庫の「左に傍点」は `.under`。
    public let position: RubyPosition

    public init(range: Range<Int>, mark: String, position: RubyPosition = .over) {
        self.range = range
        self.mark = mark
        self.position = position
    }
}

/// 本文に差し込む画像。
public struct ImageAnnotation: Equatable, Sendable {
    /// 本文中の位置 (`ExtractedText.text` の Character 単位)。その 1 文字が画像の置き場所。
    public let offset: Int
    /// 画像のパス (本文ドキュメントからの相対)。
    public let source: String
    /// 代替文字列 (alt)。
    public let alt: String
    /// 段落に 1 つだけ置かれている挿絵か。false なら本文中の小さな画像 (外字など)。
    public let isBlock: Bool

    public init(offset: Int, source: String, alt: String, isBlock: Bool) {
        self.offset = offset
        self.source = source
        self.alt = alt
        self.isBlock = isBlock
    }
}

/// 本文ドキュメントから取り出したプレーンテキスト。
public struct ExtractedText: Sendable {
    /// 本文。段落の区切りは改行 1 つ、見出しなどの前後は空行になる。
    public let text: String
    /// `id` / `name` 属性 → `text` の中の文字位置 (Character 単位、0 始まり)。
    /// 目次のリンク先 (`#fragment`) から表示位置を求めるのに使う。
    public let anchors: [String: Int]
    /// `<ruby>` から取り出したルビ。本文に出てくる順に並ぶ。
    public let ruby: [RubyAnnotation]
    /// `<strong>` / `<b>` などから取り出した字面の変化。
    public let styles: [StyleAnnotation]
    /// `<em>` や傍点のクラスから取り出した圏点。
    public let emphasis: [EmphasisAnnotation]
    /// `<u>` や傍線のクラスから取り出した線。
    public let lines: [LineAnnotation]
    /// 縦中横 (`<span class="tcy">`) にする範囲。
    public let tateChuYoko: [Range<Int>]
    /// 見出しや文字サイズの注記から取り出した、文字の大きさ。
    public let sizes: [SizeAnnotation]
    /// 上付き・下付きの注記から取り出した、文字を寄せる側。
    public let shifts: [ShiftAnnotation]
    /// 字下げ・地付きの注記から取り出した、行の始まりと終わりの空き。
    public let indents: [IndentAnnotation]
    /// 割り注 (`<span class="warichu">`) にする範囲。
    public let warichu: [Range<Int>]
    /// 罫囲み (`<span class="keigakomi">`) にする範囲。
    public let boxes: [LineAnnotation]
    /// 縦組みの中で横組みにするブロック (`<div class="yokogumi">`) の範囲。
    public let horizontal: [Range<Int>]
    /// `<img>` から取り出した画像。本文には置き場所として全角空白が 1 文字入る。
    public let images: [ImageAnnotation]

    public init(
        text: String,
        anchors: [String: Int],
        ruby: [RubyAnnotation] = [],
        styles: [StyleAnnotation] = [],
        emphasis: [EmphasisAnnotation] = [],
        lines: [LineAnnotation] = [],
        tateChuYoko: [Range<Int>] = [],
        sizes: [SizeAnnotation] = [],
        shifts: [ShiftAnnotation] = [],
        indents: [IndentAnnotation] = [],
        warichu: [Range<Int>] = [],
        boxes: [LineAnnotation] = [],
        horizontal: [Range<Int>] = [],
        images: [ImageAnnotation] = []
    ) {
        self.text = text
        self.anchors = anchors
        self.ruby = ruby
        self.styles = styles
        self.emphasis = emphasis
        self.lines = lines
        self.tateChuYoko = tateChuYoko
        self.sizes = sizes
        self.shifts = shifts
        self.indents = indents
        self.warichu = warichu
        self.boxes = boxes
        self.horizontal = horizontal
        self.images = images
    }
}

/// 本文ドキュメント (XHTML / HTML) からプレーンテキストを取り出す。
///
/// STLabel は文字の並びだけを組版するので、WebView 表示と違って画像・ルビ・強調・リンクは表現できない。
/// ここでは次のように割り切っている。
///
/// - ブロック要素の境目を改行にする (見出し・表・水平線の前後は空行)
/// - `<ruby>` の親文字は本文に残し、`<rt>` のふりがなは親文字の位置とともに `ruby` に取り出す
///   (`<rp>` の括弧と、ローマ字などの二段目 `<rtc>` は落とす)
/// - `<img>` は `[画像]` (alt があればその文字列) に置き換える
/// - `<script>` / `<style>` / `<head>` の中身は捨てる
///
/// 整形式でない HTML でも止まらないよう、DOM を作らずに前から 1 文字ずつ読んでいく。
public enum PlainTextExtractor {
    /// 本文ドキュメントのバイト列からプレーンテキストを取り出す。
    public static func extract(_ raw: Data, mediaType: String) -> ExtractedText {
        extract(html: ContentPreparer.decodeText([UInt8](raw)))
    }

    /// 改行の前後だけを区切りとみなすブロック要素。
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "br", "caption", "center", "dd", "details",
        "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "header", "html",
        "legend", "li", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "tbody", "td",
        "tfoot", "th", "thead", "tr", "ul",
    ]

    /// 前後に空行を置くブロック要素。
    private static let spacedBlockTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "table",
    ]

    /// 中身を捨てる要素。
    private static let droppedTags: Set<String> = ["head", "script", "style", "rp", "title"]

    /// 空白をそのまま残す要素。
    private static let preformattedTags: Set<String> = ["pre"]

    /// 強調を表す要素。
    static let emphasisTags: Set<String> = [
        "b", "strong", "em", "i", "u", "ins", "s", "strike", "del", "sup", "sub",
    ]

    /// 字下げ・地付きがかかるブロック要素。
    static let indentContainerTags: Set<String> = ["div", "p", "blockquote", "li", "dd"]

    /// ブロックとしてかかる要素か (行の中にかかる `<span>` などと区別する)。
    static func isBlockContainer(tag: String) -> Bool {
        indentContainerTags.contains(tag) || headingSizes[tag] != nil
    }

    /// 見出しの大きさ。
    static let headingSizes: [String: Double] = [
        "h1": 1.60, "h2": 1.50, "h3": 1.40, "h4": 1.20, "h5": 1.10, "h6": 1.00,
    ]

    /// 文字の修飾を表す class。青空文庫の注記 (https://www.aozora.gr.jp/annotation/) を
    /// HTML にした変換器が出力するものに合わせている。
    enum Decoration: Equatable {
        /// 傍点。
        case emphasis(mark: String, position: RubyPosition)
        /// 傍線・左傍線・取り消し線。
        case line(style: LineStyle, position: LinePosition)
        /// 縦中横。
        case tateChuYoko
        /// 文字の大きさ (ふつうの文字に対する比)。
        case size(Double)
        /// 上付き・下付き (小さくした文字を寄せる側)。
        case shift(RubyPosition)
        /// 字下げ (行の始まりに空ける文字数と、折り返した行の字下げ)。
        case indent(head: Double, hanging: Double?)
        /// 地付き・地寄せ (行の終わりに空ける文字数)。
        case trailing(Double)
        /// 割り注。
        case warichu
        /// 罫囲み。
        case box(style: LineStyle)
        /// 縦組みの中の横組み。ブロックなら 1 ページを使い、行の中なら縦中横にする。
        case horizontal
        /// 太字・斜体。
        case style(TextStyle)
    }

    /// 圏点に使う記号。青空文庫の傍点の種類に対応する。
    enum EmphasisMark {
        /// ゴマ点。
        static let sesame = "\u{FE45}"
        static let openSesame = "\u{FE46}"
        /// 黒丸。
        static let dot = "\u{25CF}"
        static let openDot = "\u{25CB}"
        /// 黒三角。
        static let triangle = "\u{25B2}"
        static let openTriangle = "\u{25B3}"
        /// 二重丸。
        static let doubleCircle = "\u{25CE}"
        /// 蛇の目。
        static let fisheye = "\u{25C9}"
        /// ばつ傍点。
        static let saltire = "\u{00D7}"
    }

    /// class 名から文字の修飾を決める。複数の語を含む class でも拾えるよう、語ごとに見る。
    /// 1 つの語が 2 つ以上の修飾を表すこともある (上付き小文字は「小さく」かつ「上へ寄せる」)。
    static func decorations(forClass className: String) -> [Decoration] {
        let names = className.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return names.flatMap(decorations(forClassName:))
    }

    private static func decorations(forClassName name: String) -> [Decoration] {
        // 上付き・下付きは「小さくする」と「端へ寄せる」の 2 つ
        if let side = shiftSide(forClassName: name) {
            return [.size(superscriptScale), .shift(side)]
        }
        guard let decoration = decoration(forClassName: name) else { return [] }
        return [decoration]
    }

    /// 上付き・下付きの文字の大きさ。端へ寄せても隣の行とぶつからないよう、
    /// ふつうの小さな文字 (83%) より小さくする。
    static let superscriptScale = 0.6

    /// 上付き・下付きを表す class。縦組みの「行右小書き」「行左小書き」も同じ扱いにする
    /// (行の右 = 上付き、行の左 = 下付き)。
    static func shiftSide(forClassName name: String) -> RubyPosition? {
        switch name {
        case "superscript", "sup", "upperright", "upr", "gyomigi":
            return .over
        case "subscript", "sub", "lowerleft", "swr", "gyohidari":
            return .under
        default:
            return nil
        }
    }

    private static func decoration(forClassName name: String) -> Decoration? {
        // 青空文庫の傍点。末尾が _after なら左 (縦書き) に打つ
        let isAfter = name.hasSuffix("_after")
        let base = isAfter ? String(name.dropLast("_after".count)) : name
        let position: RubyPosition = isAfter ? .under : .over
        if let mark = emphasisMark(forClassName: base) {
            return .emphasis(mark: mark, position: position)
        }
        // 青空文庫の傍線。underline_* は傍線 (右・下)、overline_* は左傍線
        if let line = lineDecoration(forClassName: base) {
            return line
        }
        if let scale = sizeScale(forClassName: base) { return .size(scale) }
        if let indent = indentDecoration(forClassName: base) { return indent }
        switch base {
        case "keigakomi", "border", "kakomi":
            return .box(style: .solid)
        case "dashed_border":
            return .box(style: .dashed)
        case "warichu", "warichu_open", "warichu_close":
            return .warichu
        case "yokogumi", "yoko", "horizontal":
            return .horizontal
        case "tcy":
            return .tateChuYoko
        case "futoji", "gothic", "goth", "b", "bold":
            return .style(.bold)
        case "shatai", "i", "italic":
            return .style(.italic)
        default:
            return nil
        }
    }

    private static func emphasisMark(forClassName name: String) -> String? {
        switch name {
        case "sesame_dot", "sesame", "kenten", "boten", "bouten", "emphasis", "em-sesame":
            return EmphasisMark.sesame
        case "white_sesame_dot", "white_sesame", "em-open-sesame":
            return EmphasisMark.openSesame
        case "black_circle", "maru", "em-maru", "em-dot", "dot":
            return EmphasisMark.dot
        case "white_circle", "shiro_maru", "em-open-dot":
            return EmphasisMark.openDot
        case "black_up-pointing_triangle", "sankaku":
            return EmphasisMark.triangle
        case "white_up-pointing_triangle", "shiro_sankaku":
            return EmphasisMark.openTriangle
        case "bullseye", "nijuumaru":
            return EmphasisMark.doubleCircle
        case "fisheye", "janome":
            return EmphasisMark.fisheye
        case "saltire", "batsu":
            return EmphasisMark.saltire
        default:
            return nil
        }
    }

    /// 文字の大きさを表す class。青空文庫の「文字サイズ」注記を変換したものに合わせている。
    private static func sizeScale(forClassName name: String) -> Double? {
        // 大きな文字 / 小さな文字 (n 段階)
        if let step = step(of: name, prefix: "dai"), step >= 1, step <= 5 { return 1 + 0.2 * Double(step) }
        if let step = step(of: name, prefix: "sho"), step >= 1, step <= 5 { return 1 - 0.1 * Double(step) }
        switch name {
        // 変換器が出す段階つきの大きさ
        case "font1": return 1.10
        case "font2": return 1.20
        case "font3": return 1.30
        case "font4": return 1.40
        case "font5": return 1.50
        case "font6": return 1.60
        case "font-1": return 0.90
        case "font-2": return 0.83
        case "font-3": return 0.77
        case "font-4", "kogaki": return 0.70
        case "font-5": return 0.66
        case "font-6": return 0.62
        // 見出しの大きさ
        case "chap1", "o-midashi", "dogyo-o-midashi", "mado-o-midashi": return 1.40
        case "chap2", "naka-midashi", "dogyo-naka-midashi", "mado-naka-midashi": return 1.20
        case "chap3", "ko-midashi", "dogyo-ko-midashi", "mado-ko-midashi": return 1.10
        // font-size: smaller 相当
        case "notes", "caption", "kaeriten", "okurigana":
            return 0.83
        default: return nil
        }
    }

    /// "dai3" のような、接頭辞つきの段階の数。
    private static func step(of name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    /// 字下げ・地付きを表す class。`jisage_3` や `chitsuki_2` のように字数が付く。
    ///
    /// 「折り返して N 字下げ」の `burasage` は字数を class に持たないので、
    /// 字下げの量は `style` (`margin-left` と負の `text-indent`) から読む。
    private static func indentDecoration(forClassName name: String) -> Decoration? {
        if name == "jisage" || name == "indent" { return .indent(head: 1, hanging: nil) }
        if let n = step(of: name, prefix: "jisage_") { return .indent(head: Double(n), hanging: nil) }
        if let n = step(of: name, prefix: "jisage") { return .indent(head: Double(n), hanging: nil) }
        if name == "chitsuki" || name == "jitsuki" { return .trailing(0) }
        if let n = step(of: name, prefix: "chitsuki_") { return .trailing(Double(n)) }
        if let n = step(of: name, prefix: "chitsuki") { return .trailing(Double(n)) }
        return nil
    }

    /// `style="margin-left: 3em"` などから字下げを読む (縦書きでは margin-right)。
    ///
    /// 「折り返して N 字下げ」は `margin-left: 3em; text-indent: -1em` のように、
    /// 折り返した行の字下げを margin で、1 行目との差を負の text-indent で表す
    /// (CSS のぶら下げインデント)。そのときは 1 行目と折り返しの両方を返す。
    static func indent(forStyle style: String) -> (head: Double, hanging: Double?)? {
        let margin = ["margin-left", "margin-right", "padding-left", "padding-right"]
            .lazy.compactMap { emValue(of: $0, in: style) }.first { $0 > 0 }
        let textIndent = emValue(of: "text-indent", in: style)
        if let margin, let textIndent, textIndent < 0 {
            return (head: max(0, margin + textIndent), hanging: margin)
        }
        if let margin { return (head: margin, hanging: nil) }
        if let textIndent, textIndent > 0 { return (head: textIndent, hanging: nil) }
        return nil
    }

    /// `style` から `property` の値を em で読む (負の値も読む)。
    private static func emValue(of property: String, in style: String) -> Double? {
        let lowered = style.lowercased()
        guard let range = lowered.range(of: property) else { return nil }
        let value = lowered[range.upperBound...].drop { $0 == ":" || $0 == " " }
        let number = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let amount = Double(number) else { return nil }
        return value.dropFirst(number.count).hasPrefix("em") ? amount : nil
    }

    /// `style="writing-mode: horizontal-tb"` から、縦組みの中の横組みを読む。
    static func isHorizontal(forStyle style: String) -> Bool {
        let lowered = style.lowercased()
        guard let range = lowered.range(of: "writing-mode") else { return false }
        return lowered[range.upperBound...].drop { $0 == ":" || $0 == " " }.hasPrefix("horizontal")
    }

    /// `style="font-size: 140%"` や `1.4em` から大きさを読む。
    static func sizeScale(forStyle style: String) -> Double? {
        let lowered = style.lowercased()
        guard let range = lowered.range(of: "font-size") else { return nil }
        let value = lowered[range.upperBound...].drop { $0 == ":" || $0 == " " }
        let number = value.prefix { $0.isNumber || $0 == "." }
        guard let scale = Double(number), scale > 0 else { return nil }
        let rest = value.dropFirst(number.count)
        if rest.hasPrefix("%") { return scale / 100 }
        if rest.hasPrefix("em") || rest.hasPrefix("rem") { return scale }
        return nil
    }

    private static func lineDecoration(forClassName name: String) -> Decoration? {
        // 取り消し線
        if name == "strike" || name == "line-through" { return .line(style: .solid, position: .strikethrough) }
        if name == "dbl_strike" { return .line(style: .double, position: .strikethrough) }

        let position: LinePosition
        let rest: String
        if name == "underline" || name == "bosen" || name == "傍線" {
            return .line(style: .solid, position: .underline)
        } else if name.hasPrefix("underline_") {
            position = .underline
            rest = String(name.dropFirst("underline_".count))
        } else if name.hasPrefix("overline_") {
            position = .overline
            rest = String(name.dropFirst("overline_".count))
        } else if name == "overline" {
            return .line(style: .solid, position: .overline)
        } else {
            return nil
        }
        switch rest {
        case "solid": return .line(style: .solid, position: position)
        case "double": return .line(style: .double, position: position)
        case "dotted": return .line(style: .dotted, position: position)
        case "dashed": return .line(style: .dashed, position: position)
        case "wave", "wavy": return .line(style: .wave, position: position)
        default: return .line(style: .solid, position: position)
        }
    }

    static func extract(html: String) -> ExtractedText {
        var builder = Builder()
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<" {
                if let end = scanMarkup(chars, from: i, into: &builder) {
                    i = end
                    continue
                }
                // "<" で始まるが markup ではない (比較演算子など) ので文字として扱う
                builder.append(c)
                i += 1
            } else if c == "&" {
                let (decoded, next) = scanEntity(chars, from: i)
                builder.append(contentsOf: decoded)
                i = next
            } else {
                builder.append(c)
                i += 1
            }
        }
        return builder.finish()
    }

    // MARK: - マークアップ

    /// `<` から始まるマークアップを読んで処理し、その次の位置を返す。マークアップでなければ nil。
    private static func scanMarkup(_ chars: [Character], from start: Int, into builder: inout Builder) -> Int? {
        let next = start + 1
        guard next < chars.count else { return nil }

        // コメント
        if matches(chars, at: next, "!--") {
            let end = find(chars, from: next + 3, "-->")
            return end ?? chars.count
        }
        // CDATA セクション (中身は本文)
        if matches(chars, at: next, "![CDATA[") {
            let contentStart = next + 8
            let end = find(chars, from: contentStart, "]]>")
            let contentEnd = (end ?? chars.count + 3) - 3
            if contentStart < contentEnd {
                builder.append(contentsOf: String(chars[contentStart..<min(contentEnd, chars.count)]))
            }
            return end ?? chars.count
        }
        // DOCTYPE・処理命令
        if chars[next] == "!" || chars[next] == "?" {
            let end = find(chars, from: next, ">")
            return end ?? chars.count
        }

        // タグ
        guard let tag = parseTag(chars, from: start) else { return nil }
        apply(tag, into: &builder)
        return tag.end
    }

    private struct Tag {
        var name: String
        var isClose: Bool
        var isSelfClose: Bool
        var attributes: [String: String]
        /// タグの直後の位置。
        var end: Int
    }

    private static func parseTag(_ chars: [Character], from start: Int) -> Tag? {
        var i = start + 1
        var isClose = false
        if i < chars.count, chars[i] == "/" {
            isClose = true
            i += 1
        }
        // 要素名
        let nameStart = i
        while i < chars.count, isNameCharacter(chars[i]) { i += 1 }
        guard i > nameStart else { return nil }
        let name = String(chars[nameStart..<i]).lowercased()

        // 属性
        var attributes: [String: String] = [:]
        var isSelfClose = false
        while i < chars.count {
            let c = chars[i]
            if c == ">" {
                i += 1
                break
            }
            if c == "/" {
                isSelfClose = true
                i += 1
                continue
            }
            if c.isWhitespace {
                i += 1
                continue
            }
            // 属性名
            let keyStart = i
            while i < chars.count, isNameCharacter(chars[i]) { i += 1 }
            guard i > keyStart else {
                // 属性名として読めない文字は読み飛ばす
                i += 1
                continue
            }
            let key = String(chars[keyStart..<i]).lowercased()
            // "=" と値
            var j = i
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "=" else {
                attributes[key] = ""
                continue
            }
            j += 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count else { break }
            var value = ""
            if chars[j] == "\"" || chars[j] == "'" {
                let quote = chars[j]
                j += 1
                let valueStart = j
                while j < chars.count, chars[j] != quote { j += 1 }
                value = String(chars[valueStart..<j])
                if j < chars.count { j += 1 }
            } else {
                let valueStart = j
                while j < chars.count, !chars[j].isWhitespace, chars[j] != ">" { j += 1 }
                value = String(chars[valueStart..<j])
            }
            attributes[key] = decodeEntities(value)
            i = j
        }
        return Tag(name: name, isClose: isClose, isSelfClose: isSelfClose, attributes: attributes, end: i)
    }

    private static func apply(_ tag: Tag, into builder: inout Builder) {
        // 中身を捨てる要素
        if droppedTags.contains(tag.name) {
            if tag.isClose {
                builder.endDropping(tag.name)
            } else if !tag.isSelfClose {
                builder.beginDropping(tag.name)
            }
            return
        }
        guard !builder.isDropping else { return }

        // アンカー (目次のリンク先)
        if !tag.isClose {
            for key in ["id", "name"] {
                if let value = tag.attributes[key], !value.isEmpty { builder.addAnchor(value) }
            }
        }

        // ルビ
        switch tag.name {
        case "ruby":
            tag.isClose ? builder.endRuby() : builder.beginRuby()
            return
        case "rb":
            // 親文字がいくつかに区切られている形。開きでも閉じでも、そこで親文字を区切る
            // (<rb>漢</rb><rb>字</rb><rt>かん</rt><rt>じ</rt> のように <rb> が先に並ぶこともある)
            builder.closeRubyBaseChunk()
            return
        case "rt":
            tag.isClose ? builder.endRubyText() : builder.beginRubyText()
            return
        case "rtc":
            // 二段ルビ。<rtc> の中のルビは親文字の反対側に置く
            tag.isClose ? builder.endRubyContainer() : builder.beginRubyContainer()
            return
        default:
            break
        }

        // 字下げ・地付きはブロックにかかるので、ブロック要素の範囲も覚える。
        // 入れ子がずれないよう、指定の有無にかかわらず対にして覚えておく
        if indentContainerTags.contains(tag.name) {
            if tag.isClose {
                builder.endEmphasis(tag: tag.name)
            } else if !tag.isSelfClose {
                builder.beginEmphasis(tag: tag.name, className: tag.attributes["class"] ?? "",
                                      style: tag.attributes["style"] ?? "")
            }
        }

        // 見出しは大きさを変えるので範囲を覚える。改行はブロック要素として別に入る
        if headingSizes[tag.name] != nil {
            if tag.isClose {
                builder.endEmphasis(tag: tag.name)
            } else if !tag.isSelfClose {
                builder.beginEmphasis(tag: tag.name, className: tag.attributes["class"] ?? "",
                                      style: tag.attributes["style"] ?? "")
            }
        }

        // 強調表示
        if emphasisTags.contains(tag.name) {
            if tag.isClose {
                builder.endEmphasis(tag: tag.name)
            } else if !tag.isSelfClose {
                builder.beginEmphasis(tag: tag.name, className: tag.attributes["class"] ?? "",
                                      style: tag.attributes["style"] ?? "")
            }
            return
        }
        // 見出しの大きさ。
        // h3 が大見出し、h4 が中見出し、h5 が小見出しという変換が多い。
        // 傍点を class で表している本文 (<span class="sesame">) も拾う。
        // 閉じタグには class が無いので、入れ子がずれないよう span はすべて対にして覚えておく
        if tag.name == "span" {
            if tag.isClose {
                builder.endEmphasis(tag: tag.name)
            } else if !tag.isSelfClose {
                builder.beginEmphasis(tag: tag.name, className: tag.attributes["class"] ?? "",
                                      style: tag.attributes["style"] ?? "")
            }
            return
        }

        // 画像。本文には置き場所の 1 文字だけを入れ、実体は images で返す。
        // 改行で囲まないので、段落に 1 つだけ置かれているか (挿絵か) は後から前後の改行で判断できる
        if tag.name == "img" || tag.name == "image" {
            guard !tag.isClose else { return }
            let source = tag.attributes["src"] ?? tag.attributes["xlink:href"] ?? tag.attributes["href"] ?? ""
            guard !source.isEmpty else { return }
            let alt = (tag.attributes["alt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            builder.appendImage(source: source, alt: alt)
            return
        }

        if preformattedTags.contains(tag.name) {
            tag.isClose ? builder.endPreformatted() : builder.beginPreformatted()
        }
        if tag.name == "br" {
            builder.breakLines(1)
            return
        }
        if spacedBlockTags.contains(tag.name) {
            builder.breakLines(2)
        } else if blockTags.contains(tag.name) {
            builder.breakLines(1)
        }
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" || c == "."
    }

    private static func matches(_ chars: [Character], at index: Int, _ s: String) -> Bool {
        var i = index
        for c in s {
            guard i < chars.count, chars[i] == c else { return false }
            i += 1
        }
        return true
    }

    /// `s` が現れた直後の位置を返す。見つからなければ nil。
    private static func find(_ chars: [Character], from index: Int, _ s: String) -> Int? {
        let needle = Array(s)
        guard !needle.isEmpty, chars.count >= needle.count else { return nil }
        var i = index
        while i + needle.count <= chars.count {
            if chars[i] == needle[0], matches(chars, at: i, s) { return i + needle.count }
            i += 1
        }
        return nil
    }

    // MARK: - 文字参照

    /// `&` から始まる文字参照を解釈し、(展開後の文字列, 次の位置) を返す。
    private static func scanEntity(_ chars: [Character], from start: Int) -> (String, Int) {
        // "&name;" / "&#1234;" / "&#x12ab;" の形だけを見る (最長 32 文字)
        var i = start + 1
        let limit = min(chars.count, start + 34)
        while i < limit, chars[i] != ";" {
            guard isNameCharacter(chars[i]) || chars[i] == "#" else { break }
            i += 1
        }
        guard i < limit, chars[i] == ";", i > start + 1 else { return (String(chars[start]), start + 1) }
        let body = String(chars[(start + 1)..<i])
        guard let decoded = decodeReference(body) else { return (String(chars[start]), start + 1) }
        return (decoded, i + 1)
    }

    /// `&` と `;` に挟まれた部分を展開する。
    private static func decodeReference(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: return HtmlEntities.decode(name: body)
        }
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "&" {
                let (decoded, next) = scanEntity(chars, from: i)
                out += decoded
                i = next
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - 組み立て

    /// 空白の畳み込み・ブロックの改行・アンカー位置を見ながら本文を組み立てる。
    private struct Builder {
        private var out = ""
        /// out に入っている文字数 (Character 単位)。out.count は O(n) なので自分で数える。
        private var count = 0
        /// 畳み込んだ空白を 1 つ出す必要があるか。
        private var pendingSpace = false
        /// 畳み込んだ空白に改行が含まれていたか (CJK の間なら空白にせず捨てる)。
        private var pendingSpaceHasBreak = false
        /// 次の文字の前に入れる改行の数。
        private var pendingNewlines = 0
        /// 位置が決まるのを待っているアンカー。
        private var pendingAnchors: [String] = []
        private var anchors: [String: Int] = [:]
        private var lastCharacter: Character?
        private var droppingTag: String?
        private var droppingDepth = 0
        private var preformattedDepth = 0
        /// <ruby> の入れ子の深さ。
        private var rubyDepth = 0
        /// いま組み立てているルビの親文字の範囲。
        private var rubyBase: Range<Int>?
        /// <rt> の中なら、そこまでに読み取ったルビ。
        private var rubyText: String?
        /// いまの <ruby> の親文字をルビの区切りごとに分けたもの。<rtc> の対応付けに使う。
        private var rubyChunks: [Range<Int>] = []
        /// いまの <ruby> の親文字全体。
        private var rubyWhole: Range<Int>?
        /// <rtc> の中にいるか。
        private var isInRubyContainer = false
        /// いまの <rtc> で読み取ったルビ。閉じるときにまとめて親文字と対応付ける。
        private var rubyContainerTexts: [String] = []
        /// いまの <ruby> で見た <rtc> の数。2 つ目から先は置き場所が無いので捨てる。
        private var rubyContainerCount = 0
        /// 1 段目のルビを、親文字のどのまとまりまで対応付けたか。
        private var rubyReadingIndex = 0
        /// 開いている強調の要素。
        /// start は開いた時点では決まらない (畳み込んだ空白がまだ出ていない) ので、
        /// 最初の 1 文字が出たときに埋める。
        private var emphasisStack: [(tag: String, className: String, style: String, start: Int?, wideAtStart: Int)] = []
        /// ここまでに出した全角の文字数。強調が日本語にかかっているかの判断に使う。
        private var wideCharacterCount = 0
        private var styles: [StyleAnnotation] = []
        private var emphasis: [EmphasisAnnotation] = []
        private var lines: [LineAnnotation] = []
        private var tateChuYoko: [Range<Int>] = []
        private var sizes: [SizeAnnotation] = []
        private var shifts: [ShiftAnnotation] = []
        private var indents: [IndentAnnotation] = []
        private var warichu: [Range<Int>] = []
        private var boxes: [LineAnnotation] = []
        private var horizontal: [Range<Int>] = []
        /// 画像の (置き場所, パス, alt)。置き場所は本文を組み立て終わってから確定する。
        private var images: [(offset: Int, source: String, alt: String)] = []
        private var ruby: [RubyAnnotation] = []

        var isDropping: Bool { droppingTag != nil }

        mutating func beginDropping(_ name: String) {
            if droppingTag == nil {
                droppingTag = name
                droppingDepth = 1
            } else if droppingTag == name {
                droppingDepth += 1
            }
        }

        mutating func endDropping(_ name: String) {
            guard droppingTag == name else { return }
            droppingDepth -= 1
            if droppingDepth <= 0 { droppingTag = nil }
        }

        mutating func beginPreformatted() { preformattedDepth += 1 }
        mutating func endPreformatted() { preformattedDepth = max(0, preformattedDepth - 1) }

        // MARK: ルビ

        mutating func beginRuby() {
            rubyDepth += 1
            if rubyDepth == 1 {
                rubyBase = nil
                rubyChunks = []
                rubyWhole = nil
                rubyContainerCount = 0
                rubyReadingIndex = 0
            }
        }

        mutating func endRuby() {
            guard rubyDepth > 0 else { return }
            rubyDepth -= 1
            if rubyDepth == 0 {
                rubyBase = nil
                rubyText = nil
                isInRubyContainer = false
                rubyContainerTexts = []
            }
        }

        /// ここまでの親文字をひとまとまりとして区切る。
        mutating func closeRubyBaseChunk() {
            guard rubyDepth > 0 else { return }
            if let base = rubyBase, !base.isEmpty { rubyChunks.append(base) }
            rubyBase = nil
        }

        mutating func beginRubyText() {
            guard rubyDepth > 0 else { return }
            rubyText = ""
        }

        mutating func endRubyText() {
            // <rtc> の中では、<rt> の外の文字も本文ではなく注記として扱う
            defer { rubyText = isInRubyContainer ? "" : nil }
            guard let reading = rubyText?.trimmingCharacters(in: Self.trimmed), !reading.isEmpty else { return }
            // <rtc> の中のルビは、閉じるときにまとめて親文字と対応付ける
            if isInRubyContainer {
                rubyContainerTexts.append(reading)
                return
            }
            // 区切られていない親文字があれば、ここまでをひとまとまりにする
            closeRubyBaseChunk()
            // ルビは前から順に親文字のまとまりへ対応付ける
            guard rubyReadingIndex < rubyChunks.count else { return }
            ruby.append(RubyAnnotation(range: rubyChunks[rubyReadingIndex], text: reading))
            rubyReadingIndex += 1
        }

        /// 画像の置き場所として全角空白を 1 文字入れる。
        /// 置き場所が決まる (= その 1 文字が出る) のは append の中なので、位置はそこで拾う。
        mutating func appendImage(source: String, alt: String) {
            guard !isDropping, rubyText == nil else { return }
            pendingImage = (source, alt)
            append("\u{3000}")
            pendingImage = nil
        }

        /// いま置き場所を待っている画像。
        private var pendingImage: (source: String, alt: String)?

        // MARK: 強調表示

        mutating func beginEmphasis(tag: String, className: String, style: String = "") {
            emphasisStack.append((tag, className, style, nil, wideCharacterCount))
        }

        mutating func endEmphasis(tag: String) {
            guard let index = emphasisStack.lastIndex(where: { $0.tag == tag }) else { return }
            let open = emphasisStack.remove(at: index)
            guard let start = open.start, start < count else { return }
            let range = start..<count

            // style の font-size / margin は class より優先する
            if let scale = PlainTextExtractor.sizeScale(forStyle: open.style) {
                sizes.append(SizeAnnotation(range: range, scale: scale))
            }
            let styleIndent = PlainTextExtractor.indent(forStyle: open.style)
            if let styleIndent {
                indents.append(IndentAnnotation(
                    range: range, head: styleIndent.head, hanging: styleIndent.hanging))
            }
            // class で指定されていればそれに従う (青空文庫の注記から変換されたもの)。
            // 青空文庫の HTML は class と style の両方を持つので、字下げは style を優先する
            var decorations = PlainTextExtractor.decorations(forClass: open.className)
                .filter { if case .indent = $0, styleIndent != nil { return false } else { return true } }
            if PlainTextExtractor.isHorizontal(forStyle: open.style), !decorations.contains(.horizontal) {
                decorations.append(.horizontal)
            }
            if !decorations.isEmpty {
                for decoration in decorations { apply(decoration, to: range, tag: open.tag) }
                return
            }
            if styleIndent != nil { return }
            // 見出しは class が無くても大きさを変える
            if let scale = PlainTextExtractor.headingSizes[open.tag] {
                if PlainTextExtractor.sizeScale(forStyle: open.style) == nil {
                    sizes.append(SizeAnnotation(range: range, scale: scale))
                }
                return
            }
            switch open.tag {
            case "b", "strong":
                styles.append(StyleAnnotation(range: range, style: .bold))
            case "u", "ins":
                lines.append(LineAnnotation(range: range, style: .solid, position: .underline))
            case "s", "strike", "del":
                lines.append(LineAnnotation(range: range, style: .solid, position: .strikethrough))
            case "sup", "sub":
                // <sup> / <sub> は小さくして端へ寄せる
                sizes.append(SizeAnnotation(range: range, scale: PlainTextExtractor.superscriptScale))
                shifts.append(ShiftAnnotation(range: range, position: open.tag == "sup" ? .over : .under))
            case "em", "i":
                // 日本語には斜体が無いので、全角の文字を含む範囲は圏点にする
                if wideCharacterCount > open.wideAtStart {
                    emphasis.append(EmphasisAnnotation(range: range, mark: PlainTextExtractor.EmphasisMark.sesame))
                } else {
                    styles.append(StyleAnnotation(range: range, style: .italic))
                }
            default:
                break
            }
        }

        private mutating func apply(
            _ decoration: PlainTextExtractor.Decoration, to range: Range<Int>, tag: String
        ) {
            switch decoration {
            case .emphasis(let mark, let position):
                emphasis.append(EmphasisAnnotation(range: range, mark: mark, position: position))
            case .line(let style, let position):
                lines.append(LineAnnotation(range: range, style: style, position: position))
            case .style(let style):
                styles.append(StyleAnnotation(range: range, style: style))
            case .tateChuYoko:
                tateChuYoko.append(range)
            case .size(let scale):
                sizes.append(SizeAnnotation(range: range, scale: scale))
            case .shift(let position):
                shifts.append(ShiftAnnotation(range: range, position: position))
            case .indent(let head, let hanging):
                indents.append(IndentAnnotation(range: range, head: head, hanging: hanging))
            case .trailing(let tail):
                indents.append(IndentAnnotation(range: range, tail: tail))
            case .warichu:
                warichu.append(range)
            case .box(let style):
                boxes.append(LineAnnotation(range: range, style: style))
            case .horizontal:
                // ブロックの横組みは 1 ページを使う。行の中の短い横組みは縦中横にする
                if PlainTextExtractor.isBlockContainer(tag: tag) {
                    horizontal.append(range)
                } else {
                    tateChuYoko.append(range)
                }
            }
        }

        mutating func beginRubyContainer() {
            guard rubyDepth > 0 else { return }
            isInRubyContainer = true
            rubyContainerTexts = []
            // <rt> を使わず <rtc> に直接書く形 (<rtc>kanji</rtc>) も拾う
            rubyText = ""
        }

        mutating func endRubyContainer() {
            guard isInRubyContainer else { return }
            // <rtc> に直接書かれた文字を拾う
            if let loose = rubyText?.trimmingCharacters(in: Self.trimmed), !loose.isEmpty {
                rubyContainerTexts.append(loose)
            }
            let texts = rubyContainerTexts
            isInRubyContainer = false
            rubyText = nil
            rubyContainerTexts = []
            rubyContainerCount += 1
            // 置けるのは親文字の反対側の 1 段だけなので、2 つ目から先の <rtc> は捨てる
            guard rubyContainerCount == 1, !texts.isEmpty else { return }

            if texts.count == 1 {
                // ひとまとまりの注記は親文字全体に付ける
                if let whole = rubyWhole, !whole.isEmpty {
                    ruby.append(RubyAnnotation(range: whole, text: texts[0], position: .under))
                }
            } else {
                // 複数あるときは 1 段目と同じ区切りに順に対応付ける
                for (index, text) in texts.enumerated() where index < rubyChunks.count {
                    ruby.append(RubyAnnotation(range: rubyChunks[index], text: text, position: .under))
                }
            }
        }

        mutating func addAnchor(_ id: String) {
            // まだ文字が出ていないので、次に出る文字の位置を割り当てる
            if anchors[id] == nil { pendingAnchors.append(id) }
        }

        mutating func breakLines(_ n: Int) {
            guard !isDropping else { return }
            // 先頭の空行は作らない
            guard count > 0 else { return }
            pendingSpace = false
            pendingSpaceHasBreak = false
            pendingNewlines = max(pendingNewlines, n)
        }

        mutating func append(_ c: Character) {
            guard !isDropping else { return }
            // <rt> の中は本文ではなくルビとして取り込む
            if rubyText != nil {
                if Self.isCollapsible(c) {
                    if rubyText?.isEmpty == false { rubyText?.append(" ") }
                } else {
                    rubyText?.append(c)
                }
                return
            }
            if Self.isCollapsible(c), preformattedDepth == 0 {
                // 行頭・文書先頭の空白は捨て、それ以外は 1 つに畳む
                if count > 0, pendingNewlines == 0 {
                    pendingSpace = true
                    if c.isNewline { pendingSpaceHasBreak = true }
                }
                return
            }
            flushPending(before: c)
            // この文字の位置を、位置が決まるのを待っているアンカーに結び付ける
            if !pendingAnchors.isEmpty {
                for id in pendingAnchors { anchors[id] = count }
                pendingAnchors.removeAll()
            }
            // 強調の始まりも、畳み込んだ空白ではなく中身の 1 文字目にそろえる
            for i in emphasisStack.indices where emphasisStack[i].start == nil {
                emphasisStack[i].start = count
            }
            // 画像の置き場所も、畳み込んだ改行ではなくこの 1 文字
            if let image = pendingImage {
                images.append((offset: count, source: image.source, alt: image.alt))
                pendingImage = nil
            }
            emit(c)
        }

        mutating func append(contentsOf s: String) {
            for c in s { append(c) }
        }

        private mutating func flushPending(before c: Character) {
            if pendingNewlines > 0 {
                for _ in 0..<pendingNewlines { emit("\n") }
            } else if pendingSpace {
                // CSS の segment break transformation rules と同じく、全角文字に挟まれた
                // 原文の改行は空白にせず捨てる (日本語の本文に不要な空きが入らないように)
                let dropped = pendingSpaceHasBreak
                    && Self.isWideScript(lastCharacter)
                    && Self.isWideScript(c)
                if !dropped { emit(" ") }
            }
            pendingNewlines = 0
            pendingSpace = false
            pendingSpaceHasBreak = false
        }

        /// 文字を 1 つ出す。アンカーの位置はブロックの改行ではなく中身の先頭に付けたいので、
        /// アンカーの割り当ては append(_:) 側で行う。
        private mutating func emit(_ c: Character) {
            // <ruby> の中なら、この文字を親文字の範囲に加える
            if rubyDepth > 0, !c.isNewline {
                rubyBase = (rubyBase?.lowerBound ?? count)..<(count + 1)
                rubyWhole = (rubyWhole?.lowerBound ?? count)..<(count + 1)
            }
            if Self.isWideScript(c) { wideCharacterCount += 1 }
            out.append(c)
            count += 1
            lastCharacter = c
        }

        /// HTML で畳み込みの対象になる空白 (スペース・タブ・改行)。
        /// 全角スペース (段落の字下げに使われる) や NBSP は本文の一部として残す。
        /// CRLF は Swift では 1 つの Character なので、個別に "\r" "\n" と比べると取りこぼす。
        private static func isCollapsible(_ c: Character) -> Bool {
            c.isNewline || c == " " || c == "\t"
        }

        /// 前後から削る空白 (畳み込みの対象と同じもの)。
        private static let trimmed = CharacterSet(charactersIn: " \t\n\r\u{000B}\u{000C}\u{0085}\u{2028}\u{2029}")

        /// 前後の改行を詰めてよい全角の文字 (かな・漢字・CJK の約物など) か。
        private static func isWideScript(_ c: Character?) -> Bool {
            guard let u = c?.unicodeScalars.first else { return false }
            switch u.value {
            case 0x1100...0x11FF,   // ハングル字母
                 0x2E80...0x2FFF,   // CJK 部首補助・康熙部首
                 0x3000...0x303F,   // CJK の記号と句読点
                 0x3040...0x30FF,   // ひらがな・カタカナ
                 0x3130...0x318F,   // ハングル互換字母
                 0x3400...0x4DBF,   // CJK 拡張 A
                 0x4E00...0x9FFF,   // CJK 統合漢字
                 0xA960...0xA97F,   // ハングル字母拡張 A
                 0xAC00...0xD7FF,   // ハングル音節
                 0xF900...0xFAFF,   // CJK 互換漢字
                 0xFE10...0xFE1F,   // 縦書き用記号
                 0xFE30...0xFE4F,   // CJK 互換形
                 0xFF00...0xFF60,   // 全角英数・記号
                 0xFFE0...0xFFE6,   // 全角記号
                 0x20000...0x3134F: // CJK 拡張 B〜G (BMP 外)
                return true
            default:
                return false
            }
        }

        /// 先頭を削ったぶんだけ範囲を詰める。本文の外に出るものは捨てる。
        private func shift(_ range: Range<Int>, by leading: Int, limit: Int) -> Range<Int>? {
            let lower = min(max(0, range.lowerBound - leading), limit)
            let upper = min(max(0, range.upperBound - leading), limit)
            return lower < upper ? lower..<upper : nil
        }

        mutating func finish() -> ExtractedText {
            let text = out.trimmingCharacters(in: Self.trimmed)
            // 先頭を削った分だけアンカー位置を詰める
            let leading = out.prefix(while: { Self.isCollapsible($0) }).count
            var adjusted: [String: Int] = [:]
            let length = text.count
            for (id, position) in anchors {
                adjusted[id] = min(max(0, position - leading), max(0, length - 1))
            }
            for id in pendingAnchors where adjusted[id] == nil {
                adjusted[id] = max(0, length - 1)
            }
            // ルビの親文字の位置も、先頭を削ったぶんだけ詰める
            let shifted = ruby.compactMap { annotation -> RubyAnnotation? in
                let lower = min(max(0, annotation.range.lowerBound - leading), length)
                let upper = min(max(0, annotation.range.upperBound - leading), length)
                guard lower < upper else { return nil }
                return RubyAnnotation(range: lower..<upper, text: annotation.text, position: annotation.position)
            }
            let shiftedStyles = styles.compactMap { annotation -> StyleAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return StyleAnnotation(range: range, style: annotation.style)
            }
            let shiftedEmphasis = emphasis.compactMap { annotation -> EmphasisAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return EmphasisAnnotation(range: range, mark: annotation.mark, position: annotation.position)
            }
            let shiftedLines = lines.compactMap { annotation -> LineAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return LineAnnotation(range: range, style: annotation.style, position: annotation.position)
            }
            // 置き場所の前後が改行 (または本文の端) なら、段落に 1 つだけ置かれた挿絵とみなす
            let characters = Array(text)
            let shiftedImages = images.compactMap { image -> ImageAnnotation? in
                let offset = image.offset - leading
                guard offset >= 0, offset < characters.count else { return nil }
                let isAlone = (offset == 0 || characters[offset - 1].isNewline)
                    && (offset == characters.count - 1 || characters[offset + 1].isNewline)
                return ImageAnnotation(offset: offset, source: image.source, alt: image.alt, isBlock: isAlone)
            }
            let shiftedTateChuYoko = tateChuYoko.compactMap { shift($0, by: leading, limit: length) }
            let shiftedSizes = sizes.compactMap { annotation -> SizeAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return SizeAnnotation(range: range, scale: annotation.scale)
            }
            let shiftedIndents = indents.compactMap { annotation -> IndentAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return IndentAnnotation(
                    range: range, head: annotation.head, hanging: annotation.hanging, tail: annotation.tail)
            }
            let shiftedShifts = shifts.compactMap { annotation -> ShiftAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return ShiftAnnotation(range: range, position: annotation.position)
            }
            let shiftedWarichu = warichu.compactMap { shift($0, by: leading, limit: length) }
            let shiftedBoxes = boxes.compactMap { annotation -> LineAnnotation? in
                guard let range = shift(annotation.range, by: leading, limit: length) else { return nil }
                return LineAnnotation(range: range, style: annotation.style)
            }
            let shiftedHorizontal = horizontal.compactMap { shift($0, by: leading, limit: length) }
            return ExtractedText(
                text: text, anchors: adjusted, ruby: shifted, styles: shiftedStyles,
                emphasis: shiftedEmphasis, lines: shiftedLines, tateChuYoko: shiftedTateChuYoko,
                sizes: shiftedSizes, shifts: shiftedShifts, indents: shiftedIndents, warichu: shiftedWarichu,
                boxes: shiftedBoxes, horizontal: shiftedHorizontal, images: shiftedImages)
        }
    }
}
