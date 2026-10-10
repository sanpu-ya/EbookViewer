import Foundation

/// 親文字の範囲とそれに振るルビ (振り仮名)。
public struct RubyAnnotation: Equatable, Sendable {
    /// 親文字の範囲 (`ExtractedText.text` の Character 単位、0 始まり)。
    public let range: Range<Int>
    /// ルビ。
    public let text: String

    public init(range: Range<Int>, text: String) {
        self.range = range
        self.text = text
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

    public init(text: String, anchors: [String: Int], ruby: [RubyAnnotation] = []) {
        self.text = text
        self.anchors = anchors
        self.ruby = ruby
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

    /// 中身を捨てる要素。`<rtc>` はルビの二段目 (ローマ字など) で、親文字に重なるので捨てる。
    private static let droppedTags: Set<String> = ["head", "script", "style", "rp", "rtc", "title"]

    /// 空白をそのまま残す要素。
    private static let preformattedTags: Set<String> = ["pre"]

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
            // 親文字がいくつかに区切られている形 (<rb>漢</rb><rt>かん</rt><rb>字</rb><rt>じ</rt>)
            if !tag.isClose { builder.beginRubyBase() }
            return
        case "rt":
            tag.isClose ? builder.endRubyText() : builder.beginRubyText()
            return
        default:
            break
        }

        // 画像
        if tag.name == "img" || tag.name == "image" {
            guard !tag.isClose else { return }
            let alt = (tag.attributes["alt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            builder.breakLines(1)
            builder.append(contentsOf: "［" + (alt.isEmpty ? Localized.string("Image") : alt) + "］")
            builder.breakLines(1)
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
            rubyBase = nil
        }

        mutating func endRuby() {
            guard rubyDepth > 0 else { return }
            rubyDepth -= 1
            if rubyDepth == 0 {
                rubyBase = nil
                rubyText = nil
            }
        }

        /// 次の親文字から新しいまとまりを始める。
        mutating func beginRubyBase() {
            rubyBase = nil
        }

        mutating func beginRubyText() {
            guard rubyDepth > 0 else { return }
            rubyText = ""
        }

        mutating func endRubyText() {
            defer { rubyText = nil }
            guard let reading = rubyText?.trimmingCharacters(in: Self.trimmed), !reading.isEmpty else { return }
            guard let base = rubyBase, !base.isEmpty else { return }
            ruby.append(RubyAnnotation(range: base, text: reading))
            // 次の <rt> は、ここから後ろの親文字に付く
            rubyBase = nil
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
                if let base = rubyBase {
                    rubyBase = base.lowerBound..<(count + 1)
                } else {
                    rubyBase = count..<(count + 1)
                }
            }
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
                return RubyAnnotation(range: lower..<upper, text: annotation.text)
            }
            return ExtractedText(text: text, anchors: adjusted, ruby: shifted)
        }
    }
}
