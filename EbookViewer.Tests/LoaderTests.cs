using System.Text;
using EbookViewer.Core;
using EbookViewer.Core.Model;
using EbookViewer.Core.Rendering;

namespace EbookViewer.Tests;

public class LoaderTests
{
    private static string Sample(string name) => Path.Combine(AppContext.BaseDirectory, "Samples", name);

    private static string FirstSpineText(BookDocument book)
    {
        var item = book.Spine[0];
        var res = book.FindResource(item.Path);
        Assert.NotNull(res);
        return Encoding.UTF8.GetString(res!.GetData());
    }

    [Fact]
    public void Epub_Loads_Metadata_Spine_And_Text()
    {
        using var book = BookLoader.Load(Sample("kikai.epub"));
        Assert.Equal(BookFormat.Epub, book.Format);
        Assert.Equal("機械", book.Metadata.Title);
        Assert.Equal("横光利一", book.Metadata.Author);
        Assert.Single(book.Spine);
        Assert.Contains("初めの間は私は私の家の主人が狂人ではないのか", FirstSpineText(book));
        Assert.NotEmpty(book.Toc);
    }

    [Fact]
    public void Vertical_Epub_Declares_Vertical_Writing_Mode()
    {
        using var book = BookLoader.Load(Sample("kikai_vertical.epub"));
        Assert.Equal(WritingMode.Vertical, book.DeclaredWritingMode);
        Assert.NotEmpty(book.Spine);
        Assert.Contains("初めの間は私は私の家の主人", FirstSpineText(book));
    }

    [Fact]
    public void Hybrid_Mobi_Prefers_Kf8_Part()
    {
        using var book = BookLoader.Load(Sample("kikai.mobi"));
        Assert.Equal(BookFormat.Kf8, book.Format);
        Assert.Equal("機械", book.Metadata.Title);
        Assert.NotEmpty(book.Spine);
        string text = FirstSpineText(book);
        Assert.Contains("初めの間は私は私の家の主人が狂人ではないのか", text);
        Assert.DoesNotContain("kindle:", text);
    }

    [Fact]
    public void Mobi7_Part_Can_Be_Read_Directly()
    {
        var data = File.ReadAllBytes(Sample("kikai.mobi"));
        var book = Core.Mobi.MobiLoader.Load(data);
        // KF8 部があるので通常は KF8 が選ばれる。MOBI7 ビルダーを直接検証する
        var db = Core.Mobi.PalmDatabase.Parse(data);
        var header = Core.Mobi.MobiHeader.Parse(db.GetRecord(0));
        int end = (int)(header.GetExthUInt32(121) ?? (uint)db.RecordCount);
        var mobi7 = new Core.Mobi.Mobi7Builder(db, header, 0, (int)header.FirstResourceIndex, end).Build();
        Assert.Equal(BookFormat.Mobi7, mobi7.Format);
        string text = FirstSpineText(mobi7);
        Assert.Contains("初めの間は私は私の家の主人が狂人ではないのか", text);
        Assert.DoesNotContain("filepos=", text);
        Assert.DoesNotContain("<mbp:", text);
        Assert.Equal("機械", mobi7.Metadata.Title);
        book.Dispose();
    }

    [Fact]
    public void Kf8_Toc_Labels_Come_From_Cncx()
    {
        using var mobi = BookLoader.Load(Sample("kikai.mobi"));
        Assert.NotEmpty(mobi.Toc);
        Assert.All(mobi.Toc, t => Assert.False(int.TryParse(t.Title, out _), "目次ラベルが CNCX から取れていない: " + t.Title));
        Assert.Contains(mobi.Toc, t => t.Title == "開始" && t.Path == mobi.Spine[0].Path && t.Fragment != null);

        using var azw3 = BookLoader.Load(Sample("kikai.azw3"));
        Assert.Contains(azw3.Toc, t => t.Title == "機械" && t.Path == azw3.Spine[0].Path);
        // 目次のリンク先 id が本文に存在する
        string text = FirstSpineText(azw3);
        foreach (var t in azw3.Toc.Where(t => t.Fragment != null))
            Assert.Contains("id=\"" + t.Fragment + "\"", text);
    }

    [Fact]
    public void Azw3_Loads_As_Kf8()
    {
        using var book = BookLoader.Load(Sample("kikai.azw3"));
        Assert.Equal(BookFormat.Kf8, book.Format);
        Assert.Equal("機械", book.Metadata.Title);
        Assert.NotEmpty(book.Spine);
        string text = FirstSpineText(book);
        Assert.Contains("初めの間は私は私の家の主人", text);
        Assert.DoesNotContain("kindle:", text);
    }

    [Fact]
    public void ContentPreparer_Injects_Viewer_Assets()
    {
        using var book = BookLoader.Load(Sample("kikai.epub"));
        var item = book.Spine[0];
        var res = book.FindResource(item.Path)!;
        var (body, contentType) = ContentPreparer.Prepare(res.GetData(), item.MediaType, new ViewerOptions());
        string html = Encoding.UTF8.GetString(body);
        Assert.Contains("__viewer__/viewer.js", html);
        Assert.Contains("__EV_SETTINGS__", html);
        Assert.DoesNotContain("jquery", html, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("charset=utf-8", contentType);
        Assert.NotNull(ContentPreparer.GetAsset("viewer.js"));
        Assert.NotNull(ContentPreparer.GetAsset("viewer.css"));
    }

    [Fact]
    public void PathUtil_Resolves_Relative_References()
    {
        Assert.Equal("OEBPS/images/a.png", PathUtil.Resolve("OEBPS/text/ch1.xhtml", "../images/a.png"));
        Assert.Equal("../Images/image00001.jpg", PathUtil.MakeRelative("Text/part0000.xhtml", "Images/image00001.jpg"));
        Assert.Equal("a b.xhtml", PathUtil.Normalize("./x/../a%20b.xhtml#frag"));
    }

    [Fact]
    public void PalmDoc_Decompress_Roundtrip_Of_Known_Sequence()
    {
        // "hello hello" を PalmDOC 圧縮した形: リテラル + 距離 6 / 長さ 5 の参照
        byte[] compressed = [(byte)'h', (byte)'e', (byte)'l', (byte)'l', (byte)'o', (byte)' ', 0x80 | (6 << 3) >> 8, (byte)(((6 << 3) | 2) & 0xFF)];
        var result = Core.Mobi.PalmDocDecompressor.Decompress(compressed);
        Assert.Equal("hello hello", Encoding.ASCII.GetString(result));
    }
}
