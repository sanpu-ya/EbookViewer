import Foundation

/// ビューアーの表示設定。本文 HTML に注入される。
public struct ViewerOptions: Sendable {
    public var vertical = true
    public var fontSizePx: Double = 20
    public var fontFamily = "\"Hiragino Mincho ProN\", \"YuMincho\", \"Hiragino Mincho Pro\", serif"
    public var lineHeight: Double = 1.9
    public var paddingPx = 36
    public var background = "#fdfdf8"
    public var foreground = "#1a1a1a"
    /// 初期表示位置 (JSON)。{"type":"page","page":0} / {"type":"end"} / {"type":"anchor","id":"x"} / {"type":"fraction","value":0.5}
    public var initialPositionJson = "{\"type\":\"page\",\"page\":0}"

    public init() {}
}

/// 本文ドキュメントにビューアー用 CSS / JS を注入し、WebView に渡せる形にする。
public enum ContentPreparer {
    /// ビューアー資産を配信する仮想パスの接頭辞。
    public static let assetPrefix = "__viewer__/"

    private static let headEndRegex = Rx(#"</head\s*>"#, .caseInsensitive)
    private static let bodyStartRegex = Rx(#"<body[\s>]"#, .caseInsensitive)
    private static let htmlStartRegex = Rx(#"<html[^>]*>"#, .caseInsensitive)
    private static let scriptRegex = Rx(#"<script\b[^>]*>.*?</script\s*>|<script\b[^>]*/>"#, [.caseInsensitive, .dotMatchesLineSeparators])
    private static let xmlEncodingRegex = Rx(#"<\?xml[^>]*encoding\s*=\s*["']([A-Za-z0-9_\-]+)["']"#, .caseInsensitive)
    private static let metaCharsetRegex = Rx(#"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, .caseInsensitive)
    private static let namedEntityRegex = Rx(#"&([A-Za-z][A-Za-z0-9]{1,31});"#)

    /// 埋め込み資産 (viewer.css / viewer.js) を返す。
    public static func asset(named name: String) -> Data? {
        guard name == "viewer.css" || name == "viewer.js" else { return nil }
        // PathUtil.getExtension は "." 付き小文字で返す
        let dotExt = PathUtil.getExtension(name)
        let base = String(name.dropLast(dotExt.count))
        let ext = String(dotExt.dropFirst())
        guard let url = Bundle.module.url(forResource: base, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func assetMediaType(_ name: String) -> String {
        name.lowercased().hasSuffix(".css") ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8"
    }

    /// 本文ドキュメントを準備する。戻り値は (バイト列, Content-Type)。
    public static func prepare(_ raw: Data, mediaType: String, options: ViewerOptions) -> (body: Data, contentType: String) {
        var text = decodeText([UInt8](raw))
        text = stripScripts(text)

        var xhtml = mediaType.containsIgnoringCase("xhtml")
        if xhtml {
            // 未定義の名前付き実体参照 (&nbsp; など) を数値参照にし、整形式なら XHTML として配信する
            text = replaceNamedEntities(text)
            if !isWellFormedXml(text) { xhtml = false }
        }

        let injection = buildInjection(options, xhtml: xhtml)
        text = inject(text, injection)
        let contentType = xhtml ? "application/xhtml+xml; charset=utf-8" : "text/html; charset=utf-8"
        return (Data(text.utf8), contentType)
    }

    private static func buildInjection(_ o: ViewerOptions, xhtml: Bool) -> String {
        var initial: Any = [String: Any]()
        if let d = o.initialPositionJson.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: d) {
            initial = parsed
        }
        let settings: [String: Any] = ["vertical": o.vertical, "padding": o.paddingPx, "initial": initial]
        let json = (try? JSONSerialization.data(withJSONObject: settings)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // XHTML では script 内の "<" が問題になるので CDATA で包む
        let settingsScript = xhtml
            ? "<script>//<![CDATA[\nwindow.__EV_SETTINGS__ = " + json + ";\n//]]></script>"
            : "<script>window.__EV_SETTINGS__ = " + json + ";</script>"
        var css = ""
        css += "html, body { background: \(o.background) !important; color: \(o.foreground) !important; }\n"
        css += "body { font-size: \(formatNumber(o.fontSizePx))px !important; "
        css += "font-family: \(o.fontFamily) !important; "
        css += "line-height: \(formatNumber(o.lineHeight)) !important; }\n"
        return "\n<link rel=\"stylesheet\" href=\"/" + assetPrefix + "viewer.css\"/>\n" +
            "<style id=\"__ev_user\">\n" + css + "</style>\n" +
            settingsScript + "\n" +
            "<script src=\"/" + assetPrefix + "viewer.js\"></script>\n"
    }

    private static func formatNumber(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private static func inject(_ html: String, _ injection: String) -> String {
        if let m = headEndRegex.firstMatch(in: html) {
            let at = m.range.lowerBound
            return html[..<at] + injection + html[at...]
        }
        if let m = bodyStartRegex.firstMatch(in: html) {
            let at = m.range.lowerBound
            return html[..<at] + "<head>" + injection + "</head>" + html[at...]
        }
        if let m = htmlStartRegex.firstMatch(in: html) {
            let at = m.range.upperBound
            return html[..<at] + "<head>" + injection + "</head>" + html[at...]
        }
        return "<html><head>" + injection + "</head><body>" + html + "</body></html>"
    }

    static func stripScripts(_ html: String) -> String {
        scriptRegex.replace(html, with: "")
    }

    static func decodeText(_ raw: [UInt8]) -> String {
        if raw.count >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF { return String(decoding: raw[3...], as: UTF8.self) }
        if raw.count >= 2 && raw[0] == 0xFF && raw[1] == 0xFE { return TextEncoding.utf16LE.decode(Array(raw[2...])) }
        if raw.count >= 2 && raw[0] == 0xFE && raw[1] == 0xFF { return TextEncoding.utf16BE.decode(Array(raw[2...])) }

        let head = TextEncoding.latin1.decode(raw.slice(0, min(raw.count, 2048)))
        var charset: String?
        if let m = xmlEncodingRegex.firstMatch(in: head) { charset = m.group(1) }
        else if let m = metaCharsetRegex.firstMatch(in: head) { charset = m.group(1) }
        var enc = TextEncoding.utf8
        if let charset, !charset.equalsIgnoringCase("utf-8"), !charset.equalsIgnoringCase("utf8"), let e = TextEncoding.named(charset) {
            enc = e
        }
        var text = enc.decode(raw)
        // 文字コード宣言はもう不要 (UTF-8 で配信する) なので meta charset を差し替える
        if enc != .utf8 {
            text = metaCharsetRegex.replace(text, count: 1) { m in replacingGroup(m, 1, with: "utf-8") }
            text = xmlEncodingRegex.replace(text, count: 1) { m in replacingGroup(m, 1, with: "utf-8") }
        }
        return text
    }

    /// マッチ全体のうちグループ i の部分だけを差し替えた文字列を返す。
    private static func replacingGroup(_ m: Rx.Match, _ i: Int, with s: String) -> String {
        let whole = m.value
        let g = m.group(i)
        guard let r = whole.range(of: g, options: .backwards) else { return whole }
        return whole.replacingCharacters(in: r, with: s)
    }

    static func replaceNamedEntities(_ text: String) -> String {
        namedEntityRegex.replace(text) { m in
            let name = m.group(1)
            if name == "amp" || name == "lt" || name == "gt" || name == "quot" || name == "apos" { return m.value }
            guard let decoded = HtmlEntities.decode(name: name) else { return m.value }
            return decoded.unicodeScalars.map { "&#\($0.value);" }.joined()
        }
    }

    private static let doctypeRegex = Rx(#"<!DOCTYPE\b[^>\[]*(\[[^\]]*\])?[^>]*>"#, [.caseInsensitive, .dotMatchesLineSeparators])

    static func isWellFormedXml(_ text: String) -> Bool {
        // 整形式の判定に DOCTYPE は不要 (名前付き実体は数値参照に変換済み)。外部 DTD の解決待ちを避けるため外して検査する
        let stripped = doctypeRegex.replace(text, with: "", count: 1)
        return XMLDocumentLite.isWellFormed(Data(stripped.utf8))
    }
}
