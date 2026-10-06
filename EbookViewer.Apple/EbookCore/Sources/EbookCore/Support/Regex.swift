import Foundation

/// Swift 標準 Regex の薄いラッパー。C# の Regex.Replace(evaluator) 相当の置換を提供する。
struct Rx: @unchecked Sendable {
    /// 正規表現のオプション。
    struct Options: OptionSet, Sendable {
        let rawValue: Int
        /// 大文字小文字を区別しない。
        static let caseInsensitive = Options(rawValue: 1 << 0)
        /// "." が改行にもマッチする。
        static let dotMatchesLineSeparators = Options(rawValue: 1 << 1)
    }

    let re: Regex<AnyRegexOutput>

    init(_ pattern: String, _ options: Options = []) {
        // パターンは定数なので失敗しない前提
        var r = try! Regex(pattern)
        if options.contains(.caseInsensitive) { r = r.ignoresCase() }
        if options.contains(.dotMatchesLineSeparators) { r = r.dotMatchesNewlines() }
        // 書記素クラスタではなく Unicode スカラー単位でマッチさせる (結合文字を含む HTML でも属性値の区切りを取りこぼさない)
        re = r.matchingSemantics(.unicodeScalar)
    }

    /// マッチ結果 (全体と各グループの文字列)。
    struct Match {
        let range: Range<String.Index>
        let value: String
        private let groups: [String?]

        init(_ m: Regex<AnyRegexOutput>.Match) {
            range = m.range
            // output[0] は全体マッチ、以降がキャプチャグループ
            groups = m.output.map { $0.substring.map(String.init) }
            value = groups.first.flatMap { $0 } ?? ""
        }

        /// グループ i の文字列 (未マッチは "")。
        func group(_ i: Int) -> String { i < groups.count ? (groups[i] ?? "") : "" }
        func hasGroup(_ i: Int) -> Bool { i < groups.count && groups[i] != nil }
    }

    func firstMatch(in s: String) -> Match? {
        s.firstMatch(of: re).map(Match.init)
    }

    func isMatch(_ s: String) -> Bool {
        s.contains(re)
    }

    func matches(in s: String) -> [Match] {
        s.matches(of: re).map(Match.init)
    }

    /// 全マッチを評価関数の結果で置換する。
    func replace(_ s: String, count: Int = Int.max, _ evaluator: (Match) -> String) -> String {
        var out = ""
        var last = s.startIndex
        var n = 0
        for m in s.matches(of: re) {
            if n >= count { break }
            out += s[last..<m.range.lowerBound]
            out += evaluator(Match(m))
            last = m.range.upperBound
            n += 1
        }
        if n == 0 { return s }
        out += s[last...]
        return out
    }

    /// 全マッチを固定文字列で置換する ($ などのテンプレート展開はしない)。
    func replace(_ s: String, with literal: String, count: Int = Int.max) -> String {
        replace(s, count: count) { _ in literal }
    }
}
