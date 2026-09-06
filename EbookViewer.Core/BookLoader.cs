using EbookViewer.Core.Epub;
using EbookViewer.Core.Mobi;
using EbookViewer.Core.Model;

namespace EbookViewer.Core;

/// <summary>拡張子とファイル先頭の署名から形式を判別して読み込む入口。</summary>
public static class BookLoader
{
    public static readonly string[] SupportedExtensions = [".epub", ".mobi", ".azw3", ".azw", ".prc", ".kf8"];

    public static bool IsSupported(string path)
    {
        return SupportedExtensions.Contains(Path.GetExtension(path).ToLowerInvariant());
    }

    public static BookDocument Load(string filePath)
    {
        if (!File.Exists(filePath)) throw new FileNotFoundException("ファイルが見つかりません。", filePath);
        Span<byte> head = stackalloc byte[80];
        int n;
        using (var fs = File.OpenRead(filePath))
        {
            n = fs.Read(head);
        }
        head = head[..n];

        // ZIP (EPUB) は "PK"、PalmDB は 60 バイト目から type/creator
        if (n >= 2 && head[0] == 'P' && head[1] == 'K')
            return EpubLoader.Load(filePath);
        if (n >= 68)
        {
            string type = System.Text.Encoding.ASCII.GetString(head.Slice(60, 4));
            string creator = System.Text.Encoding.ASCII.GetString(head.Slice(64, 4));
            if ((type == "BOOK" && creator == "MOBI") || (type == "TEXt" && creator == "REAd"))
                return MobiLoader.Load(filePath);
        }

        return Path.GetExtension(filePath).ToLowerInvariant() switch
        {
            ".epub" => EpubLoader.Load(filePath),
            ".mobi" or ".azw3" or ".azw" or ".prc" or ".kf8" => MobiLoader.Load(filePath),
            _ => throw new UnsupportedBookException("対応していないファイル形式です: " + Path.GetFileName(filePath)),
        };
    }

    public static Task<BookDocument> LoadAsync(string filePath, CancellationToken ct = default)
    {
        return Task.Run(() => Load(filePath), ct);
    }
}
