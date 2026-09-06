using System.Text;
using System.Text.RegularExpressions;
using EbookViewer.Core;
using EbookViewer.Core.Model;

namespace EbookViewer.Tests;

/// <summary>挿絵入りの本 (青空文庫『奇巌城』図版 4 枚) で画像参照が解決されることを確認する。</summary>
public partial class ImageTests
{
    private static string Sample(string name) => Path.Combine(AppContext.BaseDirectory, "Samples", name);

    private static IEnumerable<TocEntry> Flatten(IEnumerable<TocEntry> entries)
    {
        foreach (var e in entries)
        {
            yield return e;
            foreach (var c in Flatten(e.Children)) yield return c;
        }
    }

    [GeneratedRegex(@"<img\b[^>]*\ssrc\s*=\s*[""']([^""']+)[""']", RegexOptions.IgnoreCase)]
    private static partial Regex ImgSrcRegex();

    /// <summary>spine の全ドキュメントから img の src を集め、それぞれが画像リソースとして存在することを検証する。</summary>
    private static int AssertAllImagesResolve(BookDocument book)
    {
        int count = 0;
        foreach (var item in book.Spine)
        {
            var res = book.FindResource(item.Path);
            Assert.NotNull(res);
            string html = Encoding.UTF8.GetString(res!.GetData());
            Assert.DoesNotContain("kindle:", html);
            Assert.DoesNotContain("recindex", html, StringComparison.OrdinalIgnoreCase);
            foreach (Match m in ImgSrcRegex().Matches(html))
            {
                string src = m.Groups[1].Value;
                Assert.False(src.StartsWith("data:", StringComparison.OrdinalIgnoreCase));
                string path = PathUtil.Resolve(item.Path, src);
                var img = book.FindResource(path);
                Assert.True(img != null, $"画像が見つからない: {src} (in {item.Path}) → {path}");
                Assert.StartsWith("image/", img!.MediaType);
                Assert.True(img.GetData().Length > 100, "画像データが空: " + path);
                count++;
            }
        }
        return count;
    }

    [Fact]
    public void Epub3_Vertical_With_Images_Resolves_All_Images()
    {
        using var book = BookLoader.Load(Sample("kigan.epub"));
        Assert.Equal(WritingMode.Vertical, book.DeclaredWritingMode);
        Assert.True(book.Spine.Count >= 4);
        int images = AssertAllImagesResolve(book);
        Assert.True(images >= 4, $"img が {images} 個しか無い");
        Assert.NotNull(book.CoverPath);
        Assert.StartsWith("image/", book.FindResource(book.CoverPath!)!.MediaType);
        // 目次が複数ファイルにまたがっている
        var flat = Flatten(book.Toc).ToList();
        Assert.True(flat.Count >= 3);
        // 目次のリンク先はすべて spine 内のファイルで、複数ファイルにまたがる
        Assert.All(flat, t => Assert.True(t.Path != null && book.FindSpineIndex(t.Path) >= 0, "spine に無い目次リンク: " + t.Path));
        Assert.True(flat.Select(t => t.Path).Distinct().Count() >= 2);
        Assert.Contains(flat, t => t.Fragment != null);
    }

    [Fact]
    public void Kf8_With_Images_Resolves_Embeds_And_Cover()
    {
        using var book = BookLoader.Load(Sample("kigan.mobi"));
        Assert.Equal(BookFormat.Kf8, book.Format);
        int images = AssertAllImagesResolve(book);
        Assert.True(images >= 4, $"img が {images} 個しか無い");
        Assert.True(book.Resources.Values.Count(r => r.MediaType.StartsWith("image/")) >= 4);
        Assert.NotNull(book.CoverPath);
        // CSS フローが取り出され、本文から参照されている
        var css = book.Resources.Values.Where(r => r.MediaType == "text/css").ToList();
        Assert.NotEmpty(css);
        string first = Encoding.UTF8.GetString(book.FindResource(book.Spine[0].Path)!.GetData());
        Assert.Contains("flow", first);
        Assert.DoesNotContain("kindle:flow", first);
    }

    [Fact]
    public void Mobi7_Part_With_Images_Resolves_Recindex()
    {
        var data = File.ReadAllBytes(Sample("kigan.mobi"));
        var db = Core.Mobi.PalmDatabase.Parse(data);
        var header = Core.Mobi.MobiHeader.Parse(db.GetRecord(0));
        int end = (int)(header.GetExthUInt32(121) ?? (uint)db.RecordCount);
        var book = new Core.Mobi.Mobi7Builder(db, header, 0, (int)header.FirstResourceIndex, end).Build();
        Assert.Equal(BookFormat.Mobi7, book.Format);
        int images = AssertAllImagesResolve(book);
        Assert.True(images >= 4, $"img が {images} 個しか無い");
        Assert.NotNull(book.CoverPath);
        // 目次 (NCX) の filepos アンカーが本文に存在する
        Assert.NotEmpty(book.Toc);
        string html = Encoding.UTF8.GetString(book.FindResource(book.Spine[0].Path)!.GetData());
        foreach (var t in book.Toc.Where(t => t.Fragment != null))
            Assert.Contains("id=\"" + t.Fragment + "\"", html);
    }
}
