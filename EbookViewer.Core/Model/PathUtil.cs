using System.Text;

namespace EbookViewer.Core.Model;

public static class PathUtil
{
    private static readonly char[] QueryOrFragment = ['?', '#'];

    /// <summary>"/" 区切り、"." ".." を解決し、先頭スラッシュを除いた形にする。%XX は復号する。</summary>
    public static string Normalize(string path)
    {
        if (string.IsNullOrEmpty(path)) return string.Empty;
        path = path.Replace('\\', '/');
        int q = path.IndexOfAny(QueryOrFragment);
        if (q >= 0) path = path[..q];
        path = Uri.UnescapeDataString(path);
        var parts = new List<string>();
        foreach (var seg in path.Split('/'))
        {
            if (seg.Length == 0 || seg == ".") continue;
            if (seg == "..")
            {
                if (parts.Count > 0) parts.RemoveAt(parts.Count - 1);
                continue;
            }
            parts.Add(seg);
        }
        return string.Join('/', parts);
    }

    /// <summary>basePath (ファイルのパス) から見た相対参照 href を書籍ルート相対パスに解決する。</summary>
    public static string Resolve(string basePath, string href)
    {
        string dir = GetDirectory(basePath);
        if (href.StartsWith('/')) return Normalize(href);
        return Normalize(dir.Length == 0 ? href : dir + "/" + href);
    }

    public static string GetDirectory(string path)
    {
        int i = path.LastIndexOf('/');
        return i < 0 ? string.Empty : path[..i];
    }

    public static string GetFileName(string path)
    {
        int i = path.LastIndexOf('/');
        return i < 0 ? path : path[(i + 1)..];
    }

    public static string GetExtension(string path)
    {
        string name = GetFileName(path);
        int i = name.LastIndexOf('.');
        return i < 0 ? string.Empty : name[i..].ToLowerInvariant();
    }

    /// <summary>fromPath (ファイル) から toPath (ファイル) への相対パスを作る。</summary>
    public static string MakeRelative(string fromPath, string toPath)
    {
        var from = GetDirectory(Normalize(fromPath)).Split('/', StringSplitOptions.RemoveEmptyEntries);
        var to = Normalize(toPath).Split('/', StringSplitOptions.RemoveEmptyEntries);
        int common = 0;
        while (common < from.Length && common < to.Length - 1 && from[common] == to[common]) common++;
        var sb = new StringBuilder();
        for (int i = common; i < from.Length; i++) sb.Append("../");
        for (int i = common; i < to.Length; i++)
        {
            if (i > common) sb.Append('/');
            sb.Append(to[i]);
        }
        return sb.ToString();
    }

    public static string MediaTypeFromExtension(string path)
    {
        return GetExtension(path) switch
        {
            ".xhtml" or ".xht" => "application/xhtml+xml",
            ".html" or ".htm" => "text/html",
            ".css" => "text/css",
            ".js" => "text/javascript",
            ".png" => "image/png",
            ".jpg" or ".jpeg" or ".jpe" => "image/jpeg",
            ".gif" => "image/gif",
            ".svg" => "image/svg+xml",
            ".webp" => "image/webp",
            ".bmp" => "image/bmp",
            ".ttf" => "font/ttf",
            ".otf" => "font/otf",
            ".woff" => "font/woff",
            ".woff2" => "font/woff2",
            ".ncx" => "application/x-dtbncx+xml",
            ".opf" => "application/oebps-package+xml",
            ".xml" => "application/xml",
            ".txt" => "text/plain",
            ".mp3" => "audio/mpeg",
            ".mp4" => "video/mp4",
            _ => "application/octet-stream",
        };
    }

    public static bool IsHtmlMediaType(string mediaType)
    {
        return mediaType.Contains("html", StringComparison.OrdinalIgnoreCase);
    }
}
