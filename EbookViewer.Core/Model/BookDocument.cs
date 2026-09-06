namespace EbookViewer.Core.Model;

/// <summary>書籍のファイル形式。</summary>
public enum BookFormat
{
    Epub,
    /// <summary>旧形式 (Mobipocket / KF7)。</summary>
    Mobi7,
    /// <summary>KF8 (AZW3、またはハイブリッド .mobi の KF8 部)。</summary>
    Kf8,
}

/// <summary>書籍側が宣言している組方向。</summary>
public enum WritingMode
{
    Unknown,
    Vertical,
    Horizontal,
}

public sealed class BookMetadata
{
    public string Title { get; set; } = string.Empty;
    public string Author { get; set; } = string.Empty;
    public string Publisher { get; set; } = string.Empty;
    public string Language { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Identifier { get; set; } = string.Empty;
}

/// <summary>読み順に並ぶ本文ドキュメント 1 件。</summary>
public sealed class SpineItem
{
    public SpineItem(string path, string mediaType, bool linear = true)
    {
        Path = path;
        MediaType = mediaType;
        Linear = linear;
    }

    /// <summary>書籍ルートからの相対パス ("/" 区切り、先頭スラッシュなし)。</summary>
    public string Path { get; }
    public string MediaType { get; }
    public bool Linear { get; }
}

/// <summary>目次エントリ (ツリー)。</summary>
public sealed class TocEntry
{
    public TocEntry(string title, string? path, string? fragment)
    {
        Title = title;
        Path = path;
        Fragment = fragment;
    }

    public string Title { get; }
    /// <summary>リンク先ドキュメントのパス。リンクを持たない見出しは null。</summary>
    public string? Path { get; }
    public string? Fragment { get; }
    public List<TocEntry> Children { get; } = [];
}

/// <summary>画像・CSS・フォントなどのリソース。本文ドキュメントもここに含まれる。</summary>
public sealed class BookResource
{
    private readonly Func<byte[]> _loader;
    private byte[]? _cache;

    public BookResource(string path, string mediaType, Func<byte[]> loader)
    {
        Path = path;
        MediaType = mediaType;
        _loader = loader;
    }

    public BookResource(string path, string mediaType, byte[] data)
        : this(path, mediaType, () => data)
    {
        _cache = data;
    }

    public string Path { get; }
    public string MediaType { get; }

    public byte[] GetData()
    {
        lock (_loader)
        {
            return _cache ??= _loader();
        }
    }
}

/// <summary>形式に依存しない書籍モデル。ビューアーはこれだけを見て描画する。</summary>
public sealed class BookDocument : IDisposable
{
    private readonly IDisposable? _owner;

    public BookDocument(
        BookFormat format,
        BookMetadata metadata,
        IReadOnlyList<SpineItem> spine,
        IReadOnlyList<TocEntry> toc,
        IReadOnlyDictionary<string, BookResource> resources,
        WritingMode declaredWritingMode,
        string? coverPath,
        IDisposable? owner = null)
    {
        Format = format;
        Metadata = metadata;
        Spine = spine;
        Toc = toc;
        Resources = resources;
        DeclaredWritingMode = declaredWritingMode;
        CoverPath = coverPath;
        _owner = owner;
    }

    public BookFormat Format { get; }
    public BookMetadata Metadata { get; }
    public IReadOnlyList<SpineItem> Spine { get; }
    public IReadOnlyList<TocEntry> Toc { get; }
    /// <summary>パス ("/" 区切り、先頭スラッシュなし) → リソース。</summary>
    public IReadOnlyDictionary<string, BookResource> Resources { get; }
    public WritingMode DeclaredWritingMode { get; }
    public string? CoverPath { get; }

    public BookResource? FindResource(string path)
    {
        path = PathUtil.Normalize(path);
        if (Resources.TryGetValue(path, out var r)) return r;
        // 大文字小文字違いの参照は珍しくないので保険として線形検索する
        foreach (var kv in Resources)
        {
            if (string.Equals(kv.Key, path, StringComparison.OrdinalIgnoreCase)) return kv.Value;
        }
        return null;
    }

    public int FindSpineIndex(string path)
    {
        path = PathUtil.Normalize(path);
        for (int i = 0; i < Spine.Count; i++)
        {
            if (string.Equals(Spine[i].Path, path, StringComparison.OrdinalIgnoreCase)) return i;
        }
        return -1;
    }

    public void Dispose()
    {
        _owner?.Dispose();
    }
}

/// <summary>対応していない書籍 (DRM 付きなど) を開こうとしたときの例外。</summary>
public sealed class UnsupportedBookException : Exception
{
    public UnsupportedBookException(string message) : base(message) { }
}
