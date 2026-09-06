using System.Text.Json;
using System.Text.Json.Serialization;

namespace EbookViewer.App.Services;

/// <summary>表示設定。LocalAppData/EbookViewer/settings.json に保存する。</summary>
public sealed class ReaderSettings
{
    private static string FilePath => Path.Combine(App.DataDirectory, "settings.json");

    /// <summary>"auto" / "vertical" / "horizontal"</summary>
    public string WritingMode { get; set; } = "auto";
    public double FontSizePx { get; set; } = 20;
    /// <summary>"mincho" / "gothic"</summary>
    public string FontKey { get; set; } = "mincho";
    public double LineHeight { get; set; } = 1.9;
    /// <summary>"light" / "sepia" / "dark"</summary>
    public string Theme { get; set; } = "light";
    public int PaddingPx { get; set; } = 36;
    public bool TocOpen { get; set; }
    public List<string> RecentFiles { get; set; } = [];
    public double WindowWidth { get; set; }
    public double WindowHeight { get; set; }

    [JsonIgnore]
    public string FontFamilyCss => FontKey switch
    {
        "gothic" => "\"Yu Gothic\", \"游ゴシック\", \"BIZ UDGothic\", \"Meiryo\", \"Noto Sans JP\", sans-serif",
        _ => "\"Yu Mincho\", \"游明朝\", \"BIZ UDMincho Medium\", \"MS Mincho\", \"ＭＳ 明朝\", serif",
    };

    [JsonIgnore]
    public (string background, string foreground) ThemeColors => Theme switch
    {
        "sepia" => ("#f4ecd8", "#3b2f1e"),
        "dark" => ("#1e1e1e", "#d8d8d8"),
        _ => ("#fdfdf8", "#1a1a1a"),
    };

    public void AddRecent(string path)
    {
        RecentFiles.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        RecentFiles.Insert(0, path);
        if (RecentFiles.Count > 12) RecentFiles.RemoveRange(12, RecentFiles.Count - 12);
    }

    public static ReaderSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var s = JsonSerializer.Deserialize<ReaderSettings>(File.ReadAllText(FilePath));
                if (s != null) return s;
            }
        }
        catch
        {
            // 壊れた設定は既定値で上書きする
        }
        return new ReaderSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(App.DataDirectory);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // 保存失敗は致命的ではない
        }
    }
}

/// <summary>ファイルごとの読書位置。</summary>
public sealed class ReadingPosition
{
    public int SpineIndex { get; set; }
    public double Fraction { get; set; }
    public DateTime UpdatedAt { get; set; }
}

public sealed class ReadingPositionStore
{
    private static string FilePath => Path.Combine(App.DataDirectory, "positions.json");
    private readonly Dictionary<string, ReadingPosition> _positions;

    private ReadingPositionStore(Dictionary<string, ReadingPosition> positions)
    {
        _positions = positions;
    }

    public static ReadingPositionStore Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var d = JsonSerializer.Deserialize<Dictionary<string, ReadingPosition>>(File.ReadAllText(FilePath));
                if (d != null) return new ReadingPositionStore(new Dictionary<string, ReadingPosition>(d, StringComparer.OrdinalIgnoreCase));
            }
        }
        catch
        {
        }
        return new ReadingPositionStore(new Dictionary<string, ReadingPosition>(StringComparer.OrdinalIgnoreCase));
    }

    public ReadingPosition? Get(string path)
    {
        return _positions.TryGetValue(path, out var p) ? p : null;
    }

    public void Set(string path, int spineIndex, double fraction)
    {
        _positions[path] = new ReadingPosition { SpineIndex = spineIndex, Fraction = fraction, UpdatedAt = DateTime.Now };
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(App.DataDirectory);
            // 古いものから削って肥大化を防ぐ
            if (_positions.Count > 500)
            {
                foreach (var key in _positions.OrderBy(kv => kv.Value.UpdatedAt).Take(_positions.Count - 500).Select(kv => kv.Key).ToList())
                    _positions.Remove(key);
            }
            File.WriteAllText(FilePath, JsonSerializer.Serialize(_positions));
        }
        catch
        {
        }
    }
}
