using System.Buffers.Binary;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using EbookViewer.Core.Model;

namespace EbookViewer.Core.Mobi;

/// <summary>KF8 (AZW3 / ハイブリッド mobi の KF8 部) から BookDocument を組み立てる。KindleUnpack の mobi_k8proc.py 相当。</summary>
internal sealed partial class Kf8Builder
{
    private readonly PalmDatabase _db;
    private readonly MobiHeader _header;
    private readonly int _headerRecord;
    private readonly byte[] _rawText;
    private readonly List<(int start, int end)> _flows = [];
    private readonly List<(int fileNumber, string fileName, int start, int end, string html)> _parts = [];
    private readonly List<(long insertPos, string idText, int fileNumber, int seq, long start, long length)> _fragments = [];
    private readonly Dictionary<int, MobiResources.Resource> _resources;
    private readonly string? _resc;

    public Kf8Builder(PalmDatabase db, MobiHeader header, int headerRecord, int resourceBase, int resourceEnd)
    {
        _db = db;
        _header = header;
        _headerRecord = headerRecord;
        _rawText = MobiText.ReadRawText(db, header, headerRecord);
        _resources = MobiResources.Collect(db, resourceBase, resourceEnd, out _resc);
    }

    public BookDocument Build()
    {
        ReadFlows();
        ReadFragmentsAndSkeletons();

        var resources = new Dictionary<string, BookResource>(StringComparer.Ordinal);
        foreach (var r in _resources.Values)
            resources[r.Path] = new BookResource(r.Path, r.MediaType, r.Data);

        // フロー 1 以降: CSS / SVG など。kindle:embed / kindle:flow 参照を書き換える
        var flowPaths = new Dictionary<int, string>();
        for (int i = 1; i < _flows.Count; i++)
        {
            var (s, e) = _flows[i];
            string text = Encoding.UTF8.GetString(_rawText, s, e - s);
            string trimmed = text.TrimStart();
            bool isSvg = trimmed.StartsWith("<?xml", StringComparison.OrdinalIgnoreCase) || trimmed.StartsWith("<svg", StringComparison.OrdinalIgnoreCase);
            string path = isSvg ? $"Images/flow{i:D4}.svg" : $"Styles/flow{i:D4}.css";
            flowPaths[i] = path;
        }
        for (int i = 1; i < _flows.Count; i++)
        {
            var (s, e) = _flows[i];
            string text = Encoding.UTF8.GetString(_rawText, s, e - s);
            string path = flowPaths[i];
            text = RewriteKindleUrls(text, path, flowPaths);
            resources[path] = new BookResource(path, PathUtil.MediaTypeFromExtension(path), Encoding.UTF8.GetBytes(text));
        }

        // 本文パート
        var spine = new List<SpineItem>();
        var partList = new List<(int fileNumber, string fileName, int start, int end, string html)>();
        foreach (var part in _parts)
        {
            string path = "Text/" + part.fileName;
            string html = RewriteKindleUrls(part.html, path, flowPaths);
            html = ConvertAidToId(html);
            partList.Add((part.fileNumber, part.fileName, part.start, part.end, html));
            resources[path] = new BookResource(path, "application/xhtml+xml", Encoding.UTF8.GetBytes(html));
            spine.Add(new SpineItem(path, "application/xhtml+xml"));
        }

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
        else if (pwm != null && pwm.StartsWith("horizontal", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Horizontal;
        if (writingMode == WritingMode.Unknown)
        {
            string? ppd = _header.GetExthString(527);
            if (string.Equals(ppd, "rtl", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Vertical;
        }
        if (writingMode == WritingMode.Unknown && _resc != null)
        {
            if (_resc.Contains("vertical-rl", StringComparison.OrdinalIgnoreCase) ||
                _resc.Contains("page-progression-direction=\"rtl\"", StringComparison.OrdinalIgnoreCase))
                writingMode = WritingMode.Vertical;
        }

        string? coverPath = null;
        uint? coverOffset = _header.GetExthUInt32(201);
        if (coverOffset != null && _resources.TryGetValue((int)coverOffset.Value + 1, out var cover)) coverPath = cover.Path;

        var toc = BuildToc();

        return new BookDocument(BookFormat.Kf8, metadata, spine, toc, resources, writingMode, coverPath);
    }

    private void ReadFlows()
    {
        _flows.Clear();
        if (_header.FdstIndex != MobiHeader.NullIndex && _header.FdstIndex != 0)
        {
            var fdst = _db.GetRecord(_headerRecord + (int)_header.FdstIndex);
            if (fdst.Length >= 12 && fdst[0] == 'F' && fdst[1] == 'D' && fdst[2] == 'S' && fdst[3] == 'T')
            {
                int count = (int)BinaryPrimitives.ReadUInt32BigEndian(fdst[8..]);
                for (int i = 0; i < count && 12 + i * 8 + 8 <= fdst.Length; i++)
                {
                    int s = (int)BinaryPrimitives.ReadUInt32BigEndian(fdst[(12 + i * 8)..]);
                    int e = (int)BinaryPrimitives.ReadUInt32BigEndian(fdst[(16 + i * 8)..]);
                    s = Math.Clamp(s, 0, _rawText.Length);
                    e = Math.Clamp(e, s, _rawText.Length);
                    _flows.Add((s, e));
                }
            }
        }
        if (_flows.Count == 0) _flows.Add((0, _rawText.Length));
    }

    private void ReadFragmentsAndSkeletons()
    {
        _fragments.Clear();
        if (_header.FragmentIndex != MobiHeader.NullIndex)
        {
            var frag = MobiIndex.Read(_db, _headerRecord + (int)_header.FragmentIndex);
            foreach (var e in frag.Entries)
            {
                long insertPos = long.TryParse(e.LabelText, out var ip) ? ip : 0;
                long cncxIdx = e.Tag(2) ?? -1;
                string idText = cncxIdx >= 0 && frag.Cncx.TryGetValue(cncxIdx, out var lbl) ? Encoding.UTF8.GetString(lbl) : string.Empty;
                int fileNumber = (int)(e.Tag(3) ?? 0);
                int seq = (int)(e.Tag(4) ?? 0);
                long start = e.Tag(6, 0) ?? 0;
                long length = e.Tag(6, 1) ?? 0;
                _fragments.Add((insertPos, idText, fileNumber, seq, start, length));
            }
        }

        var skeletons = new List<(int number, string name, int fragCount, long pos, long length)>();
        if (_header.SkeletonIndex != MobiHeader.NullIndex)
        {
            var skel = MobiIndex.Read(_db, _headerRecord + (int)_header.SkeletonIndex);
            for (int i = 0; i < skel.Entries.Count; i++)
            {
                var e = skel.Entries[i];
                skeletons.Add((i, e.LabelText, (int)(e.Tag(1) ?? 0), e.Tag(6, 0) ?? 0, e.Tag(6, 1) ?? 0));
            }
        }

        _parts.Clear();
        var (flowStart, flowEnd) = _flows[0];
        if (skeletons.Count == 0)
        {
            // スケルトン情報が無い場合は本文フロー全体を 1 ファイルとして扱う
            string html = Encoding.UTF8.GetString(_rawText, flowStart, flowEnd - flowStart);
            _parts.Add((0, "part0000.xhtml", flowStart, flowEnd, html));
            return;
        }

        int fragPtr = 0;
        foreach (var (number, _, fragCount, skelPos, skelLen) in skeletons)
        {
            long basePtr = skelPos + skelLen;
            if (skelPos < 0 || basePtr > _rawText.Length) continue;
            var skeleton = new List<byte>(_rawText.AsSpan((int)skelPos, (int)skelLen).ToArray());
            string fileName = $"part{number:D4}.xhtml";
            for (int i = 0; i < fragCount && fragPtr < _fragments.Count; i++, fragPtr++)
            {
                var (insertPos, _, fileNumber, _, _, length) = _fragments[fragPtr];
                if (i == 0) fileName = $"part{fileNumber:D4}.xhtml";
                if (basePtr + length > _rawText.Length) length = _rawText.Length - basePtr;
                var slice = _rawText.AsSpan((int)basePtr, (int)Math.Max(0, length)).ToArray();
                int ip = (int)Math.Clamp(insertPos - skelPos, 0, skeleton.Count);
                skeleton.InsertRange(ip, slice);
                basePtr += length;
            }
            string html = Encoding.UTF8.GetString(skeleton.ToArray());
            _parts.Add((number, fileName, (int)skelPos, (int)basePtr, html));
        }
        if (_parts.Count == 0)
        {
            string html = Encoding.UTF8.GetString(_rawText, flowStart, flowEnd - flowStart);
            _parts.Add((0, "part0000.xhtml", flowStart, flowEnd, html));
        }
    }

    /// <summary>kindle:pos:fid:XXXX:off:YYYY を "partNNNN.xhtml#id" に解決する。</summary>
    private (string fileName, string id)? ResolvePosFid(string fidBase32, string offBase32)
    {
        long row = MobiResources.FromBase32(fidBase32);
        long off = MobiResources.FromBase32(offBase32);
        if (row < 0 || row >= _fragments.Count || off < 0) return null;
        long pos = _fragments[(int)row].insertPos + off;
        return ResolvePosition(pos);
    }

    /// <summary>本文フロー内の絶対位置から、含まれるパートとその直前の id / aid を求める。</summary>
    private (string fileName, string id)? ResolvePosition(long pos)
    {
        foreach (var part in _parts)
        {
            if (pos < part.start || pos >= part.end) continue;
            // 位置はパート内の生バイト位置だが、フラグメント挿入後の文字列とは一致しないため
            // 生テキストから直接 id を探す
            int npos = (int)pos;
            int pgt = Array.IndexOf(_rawText, (byte)'>', npos);
            int plt = Array.IndexOf(_rawText, (byte)'<', npos);
            if (plt == npos || (pgt >= 0 && (plt < 0 || pgt < plt))) npos = pgt + 1;
            if (npos < part.start) npos = part.start;
            string textBefore = Encoding.UTF8.GetString(_rawText, part.start, Math.Max(0, Math.Min(npos, part.end) - part.start));
            string id = FindLastId(textBefore);
            return (part.fileName, id);
        }
        return null;
    }

    private static string FindLastId(string textBefore)
    {
        int lt = textBefore.LastIndexOf('<');
        while (lt >= 0)
        {
            int gt = textBefore.IndexOf('>', lt);
            string tag = gt < 0 ? textBefore[lt..] : textBefore[lt..(gt + 1)];
            var m = IdAttrRegex().Match(tag);
            if (m.Success) return m.Groups[1].Value;
            m = AidAttrRegex().Match(tag);
            if (m.Success) return "aid_" + m.Groups[1].Value;
            lt = lt == 0 ? -1 : textBefore.LastIndexOf('<', lt - 1);
        }
        return string.Empty;
    }

    private string RewriteKindleUrls(string text, string ownPath, Dictionary<int, string> flowPaths)
    {
        text = PosFidRegex().Replace(text, m =>
        {
            var target = ResolvePosFid(m.Groups[3].Value, m.Groups[4].Value);
            if (target == null) return m.Groups[1].Value + m.Groups[2].Value + "#" + m.Groups[2].Value;
            string href = target.Value.fileName;
            if (target.Value.id.Length > 0) href += "#" + target.Value.id;
            return m.Groups[1].Value + m.Groups[2].Value + href + m.Groups[2].Value;
        });
        text = EmbedRegex().Replace(text, m =>
        {
            long n = MobiResources.FromBase32(m.Groups[1].Value);
            if (n > 0 && _resources.TryGetValue((int)n, out var res))
                return PathUtil.MakeRelative(ownPath, res.Path);
            return m.Value;
        });
        text = FlowRegex().Replace(text, m =>
        {
            long n = MobiResources.FromBase32(m.Groups[1].Value);
            if (n > 0 && flowPaths.TryGetValue((int)n, out var path))
                return PathUtil.MakeRelative(ownPath, path);
            return m.Value;
        });
        return text;
    }

    /// <summary>aid 属性を持ち id を持たない要素に id="aid_XXX" を付ける (リンク先として使うため)。</summary>
    private static string ConvertAidToId(string html)
    {
        return TagWithAidRegex().Replace(html, m =>
        {
            string tag = m.Value;
            if (IdAttrRegex().IsMatch(tag)) return tag;
            string aid = m.Groups[1].Value;
            int insert = tag.IndexOf(" aid=", StringComparison.Ordinal);
            if (insert < 0) insert = tag.IndexOf("\taid=", StringComparison.Ordinal);
            if (insert < 0) return tag;
            return tag[..insert] + " id=\"aid_" + aid + "\"" + tag[insert..];
        });
    }

    private List<TocEntry> BuildToc()
    {
        var toc = new List<TocEntry>();
        if (_header.NcxIndex == MobiHeader.NullIndex) return toc;
        var ncx = MobiIndex.Read(_db, _headerRecord + (int)_header.NcxIndex);
        var nodes = new List<(TocEntry entry, int parent)>();
        foreach (var e in ncx.Entries)
        {
            long labelIdx = e.Tag(3) ?? -1;
            string title = labelIdx >= 0 && ncx.Cncx.TryGetValue(labelIdx, out var lbl) ? Encoding.UTF8.GetString(lbl) : e.LabelText;
            string? path = null;
            string? fragment = null;
            if (e.Tags.TryGetValue(6, out var posFid) && posFid.Count >= 2)
            {
                long pos = posFid[0] < _fragments.Count && posFid[0] >= 0 ? _fragments[(int)posFid[0]].insertPos + posFid[1] : -1;
                var target = pos >= 0 ? ResolvePosition(pos) : null;
                if (target != null)
                {
                    path = "Text/" + target.Value.fileName;
                    fragment = target.Value.id.Length > 0 ? target.Value.id : null;
                }
            }
            else if (e.Tag(1) is long filepos)
            {
                var target = ResolvePosition(filepos);
                if (target != null)
                {
                    path = "Text/" + target.Value.fileName;
                    fragment = target.Value.id.Length > 0 ? target.Value.id : null;
                }
            }
            int parent = (int)(e.Tag(21) ?? -1);
            nodes.Add((new TocEntry(title.Trim(), path, fragment), parent));
        }
        for (int i = 0; i < nodes.Count; i++)
        {
            var (entry, parent) = nodes[i];
            if (parent >= 0 && parent < nodes.Count && parent != i) nodes[parent].entry.Children.Add(entry);
            else toc.Add(entry);
        }
        return toc;
    }

    [GeneratedRegex(@"(<[^>]*?\s(?:href|src)\s*=\s*)([""'])kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)\2", RegexOptions.IgnoreCase)]
    private static partial Regex PosFidRegex();

    [GeneratedRegex(@"kindle:embed:([0-9A-V]+)(?:\?mime=[^""'\)\s>]*)?", RegexOptions.IgnoreCase)]
    private static partial Regex EmbedRegex();

    [GeneratedRegex(@"kindle:flow:([0-9A-V]+)(?:\?mime=[^""'\)\s>]*)?", RegexOptions.IgnoreCase)]
    private static partial Regex FlowRegex();

    [GeneratedRegex(@"\sid\s*=\s*[""']([^""']+)[""']", RegexOptions.IgnoreCase)]
    private static partial Regex IdAttrRegex();

    [GeneratedRegex(@"\said\s*=\s*[""']([^""']+)[""']", RegexOptions.IgnoreCase)]
    private static partial Regex AidAttrRegex();

    [GeneratedRegex(@"<[a-zA-Z][^>]*?\said\s*=\s*[""']([^""']+)[""'][^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex TagWithAidRegex();
}
