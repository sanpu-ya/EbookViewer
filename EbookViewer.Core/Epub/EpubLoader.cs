using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;
using EbookViewer.Core.Model;

namespace EbookViewer.Core.Epub;

/// <summary>EPUB 2 / 3 を読み込んで <see cref="BookDocument"/> を作る。</summary>
public static class EpubLoader
{
    private static readonly XNamespace NsContainer = "urn:oasis:names:tc:opendocument:xmlns:container";
    private static readonly XNamespace NsOpf = "http://www.idpf.org/2007/opf";
    private static readonly XNamespace NsDc = "http://purl.org/dc/elements/1.1/";
    private static readonly XNamespace NsNcx = "http://www.daisy.org/z3986/2005/ncx/";
    private static readonly XNamespace NsXhtml = "http://www.w3.org/1999/xhtml";
    private static readonly XNamespace NsEpub = "http://www.idpf.org/2007/ops";
    private static readonly XNamespace NsEnc = "http://www.w3.org/2001/04/xmlenc#";

    private const string IdpfObfuscation = "http://www.idpf.org/2008/embedding";
    private const string AdobeObfuscation = "http://ns.adobe.com/pdf/enc#RC";

    public static BookDocument Load(string filePath)
    {
        var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Load(stream, leaveOpen: false);
    }

    public static BookDocument Load(Stream stream, bool leaveOpen)
    {
        var zip = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen);
        try
        {
            return LoadCore(zip);
        }
        catch
        {
            zip.Dispose();
            throw;
        }
    }

    private static BookDocument LoadCore(ZipArchive zip)
    {
        var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
        foreach (var e in zip.Entries)
        {
            if (e.FullName.EndsWith('/')) continue;
            entries[PathUtil.Normalize(e.FullName)] = e;
        }

        // container.xml → OPF
        string opfPath = FindOpfPath(entries);
        var opfDir = PathUtil.GetDirectory(opfPath);
        var opf = LoadXml(entries, opfPath) ?? throw new InvalidDataException("OPF を読めません: " + opfPath);
        var package = opf.Root ?? throw new InvalidDataException("OPF が空です");
        var ns = package.Name.Namespace;

        // メタデータ
        var metadata = new BookMetadata();
        var meta = package.Element(ns + "metadata");
        if (meta != null)
        {
            metadata.Title = meta.Elements(NsDc + "title").Select(x => x.Value.Trim()).FirstOrDefault(x => x.Length > 0) ?? string.Empty;
            metadata.Author = string.Join(", ", meta.Elements(NsDc + "creator").Select(x => x.Value.Trim()).Where(x => x.Length > 0));
            metadata.Publisher = meta.Element(NsDc + "publisher")?.Value.Trim() ?? string.Empty;
            metadata.Language = meta.Element(NsDc + "language")?.Value.Trim() ?? string.Empty;
            metadata.Description = meta.Element(NsDc + "description")?.Value.Trim() ?? string.Empty;
            string? uid = package.Attribute("unique-identifier")?.Value;
            metadata.Identifier =
                meta.Elements(NsDc + "identifier").FirstOrDefault(x => uid != null && (string?)x.Attribute("id") == uid)?.Value.Trim()
                ?? meta.Element(NsDc + "identifier")?.Value.Trim() ?? string.Empty;
        }

        // 暗号化 (DRM / フォント難読化)
        var obfuscated = ReadEncryption(entries, out bool hasDrm);
        if (hasDrm)
            throw new UnsupportedBookException("この EPUB は DRM で保護されているため開けません。");

        // manifest
        var manifest = new Dictionary<string, (string path, string mediaType, string properties)>(StringComparer.Ordinal);
        string? coverPath = null;
        string? navPath = null;
        foreach (var item in package.Element(ns + "manifest")?.Elements(ns + "item") ?? [])
        {
            string? id = (string?)item.Attribute("id");
            string? href = (string?)item.Attribute("href");
            if (id == null || href == null) continue;
            string path = ResolveHref(opfDir, href);
            string mediaType = (string?)item.Attribute("media-type") ?? PathUtil.MediaTypeFromExtension(path);
            string properties = (string?)item.Attribute("properties") ?? string.Empty;
            manifest[id] = (path, mediaType, properties);
            if (properties.Split(' ').Contains("cover-image")) coverPath = path;
            if (properties.Split(' ').Contains("nav")) navPath = path;
        }
        if (coverPath == null && meta != null)
        {
            string? coverId = meta.Elements(ns + "meta").FirstOrDefault(m => (string?)m.Attribute("name") == "cover")?.Attribute("content")?.Value;
            if (coverId != null && manifest.TryGetValue(coverId, out var cov)) coverPath = cov.path;
        }

        // spine
        var spineEl = package.Element(ns + "spine");
        var spine = new List<SpineItem>();
        foreach (var itemref in spineEl?.Elements(ns + "itemref") ?? [])
        {
            string? idref = (string?)itemref.Attribute("idref");
            if (idref == null || !manifest.TryGetValue(idref, out var m)) continue;
            bool linear = !string.Equals((string?)itemref.Attribute("linear"), "no", StringComparison.OrdinalIgnoreCase);
            spine.Add(new SpineItem(m.path, m.mediaType, linear));
        }
        if (spine.Count == 0)
        {
            // spine が壊れている場合は manifest 内の HTML を順に並べる
            foreach (var m in manifest.Values.Where(v => PathUtil.IsHtmlMediaType(v.mediaType)).OrderBy(v => v.path, StringComparer.Ordinal))
                spine.Add(new SpineItem(m.path, m.mediaType));
        }

        // 組方向: spine の page-progression-direction / primary-writing-mode メタ / CSS
        var writingMode = WritingMode.Unknown;
        string? ppd = (string?)spineEl?.Attribute("page-progression-direction");
        if (string.Equals(ppd, "rtl", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Vertical;
        else if (string.Equals(ppd, "ltr", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Horizontal;
        if (meta != null)
        {
            string? pwm = meta.Elements(ns + "meta").FirstOrDefault(m => (string?)m.Attribute("name") == "primary-writing-mode")?.Attribute("content")?.Value;
            if (pwm != null && pwm.StartsWith("vertical", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Vertical;
            else if (pwm != null && pwm.StartsWith("horizontal", StringComparison.OrdinalIgnoreCase)) writingMode = WritingMode.Horizontal;
        }

        // リソース (遅延読み込み)
        var resources = new Dictionary<string, BookResource>(StringComparer.Ordinal);
        var manifestByPath = manifest.Values.ToDictionary(v => v.path, v => v.mediaType, StringComparer.Ordinal);
        foreach (var (path, entry) in entries)
        {
            string mediaType = manifestByPath.TryGetValue(path, out var mt) ? mt : PathUtil.MediaTypeFromExtension(path);
            var e = entry;
            obfuscated.TryGetValue(path, out string? algorithm);
            string uid = metadata.Identifier;
            resources[path] = new BookResource(path, mediaType, () =>
            {
                byte[] data = ReadEntry(e);
                return algorithm == null ? data : Deobfuscate(data, algorithm, uid);
            });
        }

        if (writingMode == WritingMode.Unknown)
        {
            writingMode = DetectWritingModeFromCss(resources);
        }

        // 目次: EPUB3 nav → NCX
        var toc = new List<TocEntry>();
        if (navPath != null)
        {
            var nav = LoadXml(entries, navPath);
            if (nav != null) ParseNav(nav, navPath, toc);
        }
        if (toc.Count == 0)
        {
            string? ncxId = (string?)spineEl?.Attribute("toc");
            string? ncxPath = ncxId != null && manifest.TryGetValue(ncxId, out var ncxItem) ? ncxItem.path
                : manifest.Values.FirstOrDefault(v => v.mediaType == "application/x-dtbncx+xml").path;
            if (ncxPath != null)
            {
                var ncx = LoadXml(entries, ncxPath);
                if (ncx != null) ParseNcx(ncx, ncxPath, toc);
            }
        }

        return new BookDocument(BookFormat.Epub, metadata, spine, toc, resources, writingMode, coverPath, zip);
    }

    private static string FindOpfPath(Dictionary<string, ZipArchiveEntry> entries)
    {
        var container = LoadXml(entries, "META-INF/container.xml");
        string? path = container?.Descendants(NsContainer + "rootfile")
            .Select(r => (string?)r.Attribute("full-path"))
            .FirstOrDefault(p => !string.IsNullOrEmpty(p));
        if (path == null)
        {
            // container.xml が無い/壊れている場合は .opf を探す
            path = entries.Keys.FirstOrDefault(k => k.EndsWith(".opf", StringComparison.OrdinalIgnoreCase));
        }
        return PathUtil.Normalize(path ?? throw new InvalidDataException("EPUB の OPF ファイルが見つかりません。"));
    }

    private static string ResolveHref(string opfDir, string href)
    {
        return PathUtil.Normalize(opfDir.Length == 0 ? href : opfDir + "/" + href);
    }

    private static XDocument? LoadXml(Dictionary<string, ZipArchiveEntry> entries, string path)
    {
        if (!entries.TryGetValue(PathUtil.Normalize(path), out var entry)) return null;
        try
        {
            using var s = entry.Open();
            return XDocument.Load(s, LoadOptions.None);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static byte[] ReadEntry(ZipArchiveEntry entry)
    {
        lock (entry.Archive)
        {
            using var s = entry.Open();
            using var ms = new MemoryStream();
            s.CopyTo(ms);
            return ms.ToArray();
        }
    }

    /// <summary>META-INF/encryption.xml を読み、難読化フォントの一覧と DRM の有無を返す。</summary>
    private static Dictionary<string, string> ReadEncryption(Dictionary<string, ZipArchiveEntry> entries, out bool hasDrm)
    {
        hasDrm = false;
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var enc = LoadXml(entries, "META-INF/encryption.xml");
        if (enc == null) return result;
        foreach (var data in enc.Descendants(NsEnc + "EncryptedData"))
        {
            string? algorithm = (string?)data.Element(NsEnc + "EncryptionMethod")?.Attribute("Algorithm");
            string? uri = data.Descendants(NsEnc + "CipherReference").Select(c => (string?)c.Attribute("URI")).FirstOrDefault();
            if (uri == null) continue;
            string path = PathUtil.Normalize(uri);
            if (algorithm == IdpfObfuscation || algorithm == AdobeObfuscation)
                result[path] = algorithm;
            else
                hasDrm = true;
        }
        return result;
    }

    /// <summary>IDPF / Adobe 方式のフォント難読化を解除する。</summary>
    internal static byte[] Deobfuscate(byte[] data, string algorithm, string uniqueIdentifier)
    {
        byte[] key;
        int length;
        if (algorithm == IdpfObfuscation)
        {
            string id = string.Concat(uniqueIdentifier.Trim().Where(c => !char.IsWhiteSpace(c)));
            key = SHA1.HashData(Encoding.UTF8.GetBytes(id));
            length = 1040;
        }
        else
        {
            string hex = uniqueIdentifier.Trim();
            if (hex.StartsWith("urn:uuid:", StringComparison.OrdinalIgnoreCase)) hex = hex[9..];
            hex = hex.Replace("-", string.Empty);
            if (hex.Length < 32) return data;
            key = Convert.FromHexString(hex[..32]);
            length = 1024;
        }
        var result = (byte[])data.Clone();
        int n = Math.Min(length, result.Length);
        for (int i = 0; i < n; i++) result[i] ^= key[i % key.Length];
        return result;
    }

    private static WritingMode DetectWritingModeFromCss(Dictionary<string, BookResource> resources)
    {
        foreach (var r in resources.Values)
        {
            if (r.MediaType != "text/css") continue;
            string css;
            try { css = Encoding.UTF8.GetString(r.GetData()); }
            catch { continue; }
            int idx = css.IndexOf("writing-mode", StringComparison.OrdinalIgnoreCase);
            while (idx >= 0)
            {
                int end = css.IndexOfAny([';', '}'], idx);
                string decl = end < 0 ? css[idx..] : css[idx..end];
                if (decl.Contains("vertical", StringComparison.OrdinalIgnoreCase)) return WritingMode.Vertical;
                idx = css.IndexOf("writing-mode", idx + 12, StringComparison.OrdinalIgnoreCase);
            }
        }
        return WritingMode.Unknown;
    }

    private static void ParseNav(XDocument nav, string navPath, List<TocEntry> toc)
    {
        var navs = nav.Descendants(NsXhtml + "nav").ToList();
        var tocNav = navs.FirstOrDefault(n => (string?)n.Attribute(NsEpub + "type") == "toc") ?? navs.FirstOrDefault();
        var ol = tocNav?.Element(NsXhtml + "ol");
        if (ol == null) return;
        ParseNavList(ol, navPath, toc);
    }

    private static void ParseNavList(XElement ol, string navPath, List<TocEntry> target)
    {
        foreach (var li in ol.Elements(NsXhtml + "li"))
        {
            var a = li.Element(NsXhtml + "a") ?? li.Element(NsXhtml + "span");
            string title = NormalizeTitle(a?.Value ?? li.Nodes().OfType<XText>().FirstOrDefault()?.Value ?? string.Empty);
            string? href = (string?)a?.Attribute("href");
            var (path, fragment) = SplitHref(navPath, href);
            var entry = new TocEntry(title, path, fragment);
            var child = li.Element(NsXhtml + "ol");
            if (child != null) ParseNavList(child, navPath, entry.Children);
            target.Add(entry);
        }
    }

    private static void ParseNcx(XDocument ncx, string ncxPath, List<TocEntry> toc)
    {
        var navMap = ncx.Descendants(NsNcx + "navMap").FirstOrDefault();
        if (navMap == null) return;
        ParseNavPoints(navMap, ncxPath, toc);
    }

    private static void ParseNavPoints(XElement parent, string ncxPath, List<TocEntry> target)
    {
        foreach (var np in parent.Elements(NsNcx + "navPoint"))
        {
            string title = NormalizeTitle(np.Element(NsNcx + "navLabel")?.Element(NsNcx + "text")?.Value ?? string.Empty);
            string? src = (string?)np.Element(NsNcx + "content")?.Attribute("src");
            var (path, fragment) = SplitHref(ncxPath, src);
            var entry = new TocEntry(title, path, fragment);
            ParseNavPoints(np, ncxPath, entry.Children);
            target.Add(entry);
        }
    }

    private static (string? path, string? fragment) SplitHref(string basePath, string? href)
    {
        if (string.IsNullOrWhiteSpace(href)) return (null, null);
        href = href.Trim();
        string? fragment = null;
        int hash = href.IndexOf('#');
        if (hash >= 0)
        {
            fragment = Uri.UnescapeDataString(href[(hash + 1)..]);
            href = href[..hash];
        }
        string? path = href.Length == 0 ? PathUtil.Normalize(basePath) : PathUtil.Resolve(basePath, href);
        return (path, string.IsNullOrEmpty(fragment) ? null : fragment);
    }

    private static string NormalizeTitle(string s)
    {
        return string.Join(' ', s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    }
}
