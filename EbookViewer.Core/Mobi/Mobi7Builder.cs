using System.Text;
using System.Text.RegularExpressions;
using EbookViewer.Core.Model;

namespace EbookViewer.Core.Mobi;

/// <summary>旧形式 MOBI (KF7) から BookDocument を組み立てる。本文は 1 つの HTML になる。</summary>
internal sealed partial class Mobi7Builder
{
    private const string TextPath = "Text/book.html";

    private readonly PalmDatabase _db;
    private readonly MobiHeader _header;
    private readonly int _headerRecord;
    private readonly int _resourceBase;
    private readonly int _resourceEnd;

    public Mobi7Builder(PalmDatabase db, MobiHeader header, int headerRecord, int resourceBase, int resourceEnd)
    {
        _db = db;
        _header = header;
        _headerRecord = headerRecord;
        _resourceBase = resourceBase;
        _resourceEnd = resourceEnd;
    }

    public BookDocument Build()
    {
        byte[] raw = MobiText.ReadRawText(_db, _header, _headerRecord);
        var resourceMap = MobiResources.Collect(_db, _resourceBase, _resourceEnd, out _);

        // NCX (あれば) の filepos を集める
        var ncxEntries = new List<(string title, long pos, int parent)>();
        if (_header.NcxIndex != MobiHeader.NullIndex && _header.HeaderLength >= 0xE4)
        {
            var ncx = MobiIndex.Read(_db, _headerRecord + (int)_header.NcxIndex);
            foreach (var e in ncx.Entries)
            {
                long labelIdx = e.Tag(3) ?? -1;
                string title = labelIdx >= 0 && ncx.Cncx.TryGetValue(labelIdx, out var lbl) ? Encoding.UTF8.GetString(lbl) : e.LabelText;
                long pos = e.Tag(1) ?? -1;
                int parent = (int)(e.Tag(21) ?? -1);
                ncxEntries.Add((title.Trim(), pos, parent));
            }
        }

        // filepos 参照位置にアンカーを挿入する
        var positions = new SortedSet<long>();
        foreach (Match m in FileposRegex().Matches(Encoding.Latin1.GetString(raw)))
        {
            if (long.TryParse(m.Groups[1].Value, out long p)) positions.Add(p);
        }
        foreach (var (_, pos, _) in ncxEntries)
        {
            if (pos >= 0) positions.Add(pos);
        }

        var sb = new StringBuilder(raw.Length + positions.Count * 32);
        var enc = _header.TextEncodingObject;
        int cursor = 0;
        foreach (long p in positions)
        {
            int pos = (int)Math.Min(p, raw.Length);
            pos = AdjustAnchorPosition(raw, pos);
            if (pos < cursor) continue;
            sb.Append(enc.GetString(raw, cursor, pos - cursor));
            sb.Append("<a id=\"filepos").Append(p).Append("\"></a>");
            cursor = pos;
        }
        sb.Append(enc.GetString(raw, cursor, raw.Length - cursor));
        string html = sb.ToString();

        // filepos=NNN → href="#fileposNNN"。kindlegen が未解決リンクに残す filepos=XXXXXXXXXX は除去する
        html = FileposAttrRegex().Replace(html, m => " href=\"#filepos" + m.Groups[1].Value + "\"");
        html = FileposPlaceholderRegex().Replace(html, string.Empty);

        // <img recindex="00003"> → 画像パス
        var resources = new Dictionary<string, BookResource>(StringComparer.Ordinal);
        foreach (var r in resourceMap.Values)
            resources[r.Path] = new BookResource(r.Path, r.MediaType, r.Data);
        html = RecindexRegex().Replace(html, m =>
        {
            if (int.TryParse(m.Groups[2].Value, out int n) && resourceMap.TryGetValue(n, out var res))
                return " src=\"" + PathUtil.MakeRelative(TextPath, res.Path) + "\"";
            return m.Value;
        });

        // <guide> の参照は目次の代替として使うので、削除する前に拾っておく
        var guideToc = ExtractTocFromGuide(html).ToList();

        // mbp:pagebreak → 改ページ、その他の mbp: タグは除去
        html = PageBreakRegex().Replace(html, "<div class=\"__ev-pagebreak\"></div>");
        html = MbpTagRegex().Replace(html, string.Empty);
        html = GuideRegex().Replace(html, string.Empty);

        if (!html.Contains("<html", StringComparison.OrdinalIgnoreCase))
            html = "<html><head><meta charset=\"utf-8\"/></head><body>" + html + "</body></html>";
        if (!html.Contains("charset", StringComparison.OrdinalIgnoreCase))
            html = html.Replace("<head>", "<head><meta charset=\"utf-8\"/>", StringComparison.OrdinalIgnoreCase);

        resources[TextPath] = new BookResource(TextPath, "text/html", Encoding.UTF8.GetBytes(html));
        var spine = new List<SpineItem> { new(TextPath, "text/html") };

        var metadata = new BookMetadata
        {
            Title = _header.GetExthString(503) ?? _header.FullName,
            Author = string.Join(", ", _header.GetExthStrings(100)),
            Publisher = _header.GetExthString(101) ?? string.Empty,
            Language = _header.GetExthString(524) ?? string.Empty,
            Description = _header.GetExthString(103) ?? string.Empty,
            Identifier = _header.GetExthString(104) ?? _header.GetExthString(113) ?? string.Empty,
        };
        if (string.IsNullOrWhiteSpace(metadata.Title)) metadata.Title = _db.Name;

        var writingMode = WritingMode.Unknown;
        string? pwm = _header.GetExthString(525);
        if (pwm != null && pwm.StartsWith("vertical", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Vertical;
        else if (string.Equals(_header.GetExthString(527), "rtl", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Vertical;

        string? coverPath = null;
        uint? coverOffset = _header.GetExthUInt32(201);
        if (coverOffset != null && resourceMap.TryGetValue((int)coverOffset.Value + 1, out var cover)) coverPath = cover.Path;

        // 目次
        var toc = new List<TocEntry>();
        var nodes = new List<(TocEntry entry, int parent)>();
        foreach (var (title, pos, parent) in ncxEntries)
        {
            nodes.Add((new TocEntry(title, TextPath, pos >= 0 ? "filepos" + pos : null), parent));
        }
        for (int i = 0; i < nodes.Count; i++)
        {
            var (entry, parent) = nodes[i];
            if (parent >= 0 && parent < nodes.Count && parent != i) nodes[parent].entry.Children.Add(entry);
            else toc.Add(entry);
        }
        if (toc.Count == 0)
        {
            toc.AddRange(guideToc);
        }

        return new BookDocument(BookFormat.Mobi7, metadata, spine, toc, resources, writingMode, coverPath);
    }

    /// <summary>タグの途中やマルチバイト文字の途中にアンカーを入れないよう位置を調整する。</summary>
    private static int AdjustAnchorPosition(byte[] raw, int pos)
    {
        if (pos >= raw.Length) return raw.Length;
        if (raw[pos] == '<') return pos;
        // 直前 256 バイト以内で '<' があり、その後に '>' が無ければタグの途中 → タグ先頭へ
        for (int i = pos - 1; i >= 0 && i >= pos - 256; i--)
        {
            if (raw[i] == '>') break;
            if (raw[i] == '<') return i;
        }
        // UTF-8 継続バイトの途中なら文字の先頭へ
        while (pos > 0 && (raw[pos] & 0xC0) == 0x80) pos--;
        return pos;
    }

    private static IEnumerable<TocEntry> ExtractTocFromGuide(string html)
    {
        // <reference type="toc" title="目次" filepos=...> は href に変換済みなので拾う
        foreach (Match m in ReferenceRegex().Matches(html))
        {
            string title = m.Groups[1].Value;
            string href = m.Groups[2].Value;
            yield return new TocEntry(title, TextPath, href.TrimStart('#'));
        }
    }

    [GeneratedRegex(@"filepos\s*=\s*[""']?(\d+)", RegexOptions.IgnoreCase)]
    private static partial Regex FileposRegex();

    [GeneratedRegex(@"\sfilepos\s*=\s*[""']?(\d+)[""']?", RegexOptions.IgnoreCase)]
    private static partial Regex FileposAttrRegex();

    [GeneratedRegex(@"\sfilepos\s*=\s*[""']?X+[""']?", RegexOptions.IgnoreCase)]
    private static partial Regex FileposPlaceholderRegex();

    [GeneratedRegex(@"\s(?:hi|lo)?recindex\s*=\s*([""']?)(\d+)\1", RegexOptions.IgnoreCase)]
    private static partial Regex RecindexRegex();

    [GeneratedRegex(@"<mbp:pagebreak\s*/?>(?:\s*</mbp:pagebreak>)?", RegexOptions.IgnoreCase)]
    private static partial Regex PageBreakRegex();

    [GeneratedRegex(@"</?mbp:[a-zA-Z]+[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex MbpTagRegex();

    [GeneratedRegex(@"<guide>.*?</guide>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex GuideRegex();

    [GeneratedRegex(@"<reference[^>]*title\s*=\s*[""']([^""']*)[""'][^>]*href\s*=\s*[""']([^""']*)[""'][^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex ReferenceRegex();
}
