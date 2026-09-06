using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml;
using EbookViewer.Core.Model;

namespace EbookViewer.Core.Rendering;

/// <summary>ビューアーの表示設定。本文 HTML に注入される。</summary>
public sealed class ViewerOptions
{
    public bool Vertical { get; set; } = true;
    public double FontSizePx { get; set; } = 20;
    public string FontFamily { get; set; } = "\"Yu Mincho\", \"游明朝\", \"BIZ UDMincho Medium\", \"MS Mincho\", serif";
    public double LineHeight { get; set; } = 1.9;
    public int PaddingPx { get; set; } = 36;
    public string Background { get; set; } = "#fdfdf8";
    public string Foreground { get; set; } = "#1a1a1a";
    /// <summary>初期表示位置 (JSON)。{"type":"page","page":0} / {"type":"end"} / {"type":"anchor","id":"x"} / {"type":"fraction","value":0.5}</summary>
    public string InitialPositionJson { get; set; } = "{\"type\":\"page\",\"page\":0}";
}

/// <summary>本文ドキュメントにビューアー用 CSS / JS を注入し、WebView に渡せる形にする。</summary>
public static partial class ContentPreparer
{
    /// <summary>ビューアー資産を配信する仮想パスの接頭辞。</summary>
    public const string AssetPrefix = "__viewer__/";

    static ContentPreparer()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    public static byte[]? GetAsset(string name)
    {
        var asm = typeof(ContentPreparer).GetTypeInfo().Assembly;
        using var s = asm.GetManifestResourceStream(name);
        if (s == null) return null;
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        return ms.ToArray();
    }

    public static string AssetMediaType(string name)
    {
        return name.EndsWith(".css", StringComparison.OrdinalIgnoreCase) ? "text/css; charset=utf-8" : "text/javascript; charset=utf-8";
    }

    /// <summary>本文ドキュメントを準備する。戻り値は (バイト列, Content-Type)。</summary>
    public static (byte[] body, string contentType) Prepare(byte[] raw, string mediaType, ViewerOptions options)
    {
        string text = DecodeText(raw);
        text = StripScripts(text);

        bool xhtml = mediaType.Contains("xhtml", StringComparison.OrdinalIgnoreCase);
        if (xhtml)
        {
            // 未定義の名前付き実体参照 (&nbsp; など) を数値参照にし、整形式なら XHTML として配信する
            text = ReplaceNamedEntities(text);
            if (!IsWellFormedXml(text)) xhtml = false;
        }

        string injection = BuildInjection(options, xhtml);
        text = Inject(text, injection);
        string contentType = xhtml ? "application/xhtml+xml; charset=utf-8" : "text/html; charset=utf-8";
        return (Encoding.UTF8.GetBytes(text), contentType);
    }

    private static string BuildInjection(ViewerOptions o, bool xhtml)
    {
        var settings = new
        {
            vertical = o.Vertical,
            padding = o.PaddingPx,
            initial = JsonSerializer.Deserialize<JsonElement>(string.IsNullOrWhiteSpace(o.InitialPositionJson) ? "{}" : o.InitialPositionJson),
        };
        string json = JsonSerializer.Serialize(settings);
        // XHTML では script 内の "<" が問題になるので CDATA で包む
        string settingsScript = xhtml
            ? "<script>//<![CDATA[\nwindow.__EV_SETTINGS__ = " + json + ";\n//]]></script>"
            : "<script>window.__EV_SETTINGS__ = " + json + ";</script>";
        var css = new StringBuilder();
        css.Append("html, body { background: ").Append(o.Background).Append(" !important; color: ").Append(o.Foreground).Append(" !important; }\n");
        css.Append("body { font-size: ").Append(o.FontSizePx.ToString(System.Globalization.CultureInfo.InvariantCulture)).Append("px !important; ");
        css.Append("font-family: ").Append(o.FontFamily).Append(" !important; ");
        css.Append("line-height: ").Append(o.LineHeight.ToString(System.Globalization.CultureInfo.InvariantCulture)).Append(" !important; }\n");
        return "\n<link rel=\"stylesheet\" href=\"/" + AssetPrefix + "viewer.css\"/>\n" +
               "<style id=\"__ev_user\">\n" + css + "</style>\n" +
               settingsScript + "\n" +
               "<script src=\"/" + AssetPrefix + "viewer.js\"></script>\n";
    }

    private static string Inject(string html, string injection)
    {
        var m = HeadEndRegex().Match(html);
        if (m.Success) return html[..m.Index] + injection + html[m.Index..];
        m = BodyStartRegex().Match(html);
        if (m.Success) return html[..m.Index] + "<head>" + injection + "</head>" + html[m.Index..];
        m = HtmlStartRegex().Match(html);
        if (m.Success)
        {
            int at = m.Index + m.Length;
            return html[..at] + "<head>" + injection + "</head>" + html[at..];
        }
        return "<html><head>" + injection + "</head><body>" + html + "</body></html>";
    }

    internal static string StripScripts(string html)
    {
        return ScriptRegex().Replace(html, string.Empty);
    }

    internal static string DecodeText(byte[] raw)
    {
        if (raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) return Encoding.UTF8.GetString(raw, 3, raw.Length - 3);
        if (raw.Length >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) return Encoding.Unicode.GetString(raw, 2, raw.Length - 2);
        if (raw.Length >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(raw, 2, raw.Length - 2);

        string head = Encoding.ASCII.GetString(raw, 0, Math.Min(raw.Length, 2048));
        string? charset = null;
        var m = XmlEncodingRegex().Match(head);
        if (m.Success) charset = m.Groups[1].Value;
        else
        {
            m = MetaCharsetRegex().Match(head);
            if (m.Success) charset = m.Groups[1].Value;
        }
        Encoding enc = Encoding.UTF8;
        if (charset != null && !charset.Equals("utf-8", StringComparison.OrdinalIgnoreCase) && !charset.Equals("utf8", StringComparison.OrdinalIgnoreCase))
        {
            try { enc = Encoding.GetEncoding(charset); }
            catch (ArgumentException) { enc = Encoding.UTF8; }
        }
        string text = enc.GetString(raw);
        // 文字コード宣言はもう不要 (UTF-8 で配信する) なので meta charset を差し替える
        if (enc != Encoding.UTF8)
        {
            text = MetaCharsetRegex().Replace(text, "charset=utf-8", 1);
            text = XmlEncodingRegex().Replace(text, "encoding=\"utf-8\"", 1);
        }
        return text;
    }

    internal static string ReplaceNamedEntities(string text)
    {
        return NamedEntityRegex().Replace(text, m =>
        {
            string name = m.Groups[1].Value;
            if (name is "amp" or "lt" or "gt" or "quot" or "apos") return m.Value;
            string decoded = WebUtility.HtmlDecode(m.Value);
            if (decoded == m.Value) return m.Value;
            var sb = new StringBuilder();
            foreach (var rune in decoded.EnumerateRunes()) sb.Append("&#").Append(rune.Value).Append(';');
            return sb.ToString();
        });
    }

    internal static bool IsWellFormedXml(string text)
    {
        try
        {
            var settings = new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Ignore,
                XmlResolver = null,
                IgnoreWhitespace = false,
            };
            using var reader = XmlReader.Create(new StringReader(text), settings);
            while (reader.Read()) { }
            return true;
        }
        catch (XmlException)
        {
            return false;
        }
    }

    [GeneratedRegex(@"</head\s*>", RegexOptions.IgnoreCase)]
    private static partial Regex HeadEndRegex();

    [GeneratedRegex(@"<body[\s>]", RegexOptions.IgnoreCase)]
    private static partial Regex BodyStartRegex();

    [GeneratedRegex(@"<html[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex HtmlStartRegex();

    [GeneratedRegex(@"<script\b[^>]*>.*?</script\s*>|<script\b[^>]*/>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex ScriptRegex();

    [GeneratedRegex(@"<\?xml[^>]*encoding\s*=\s*[""']([A-Za-z0-9_\-]+)[""']", RegexOptions.IgnoreCase)]
    private static partial Regex XmlEncodingRegex();

    [GeneratedRegex(@"charset\s*=\s*[""']?([A-Za-z0-9_\-]+)", RegexOptions.IgnoreCase)]
    private static partial Regex MetaCharsetRegex();

    [GeneratedRegex(@"&([A-Za-z][A-Za-z0-9]{1,31});")]
    private static partial Regex NamedEntityRegex();
}
