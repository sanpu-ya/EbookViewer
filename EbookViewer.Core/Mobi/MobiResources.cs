using System.Buffers.Binary;
using System.IO.Compression;
using EbookViewer.Core.Model;

namespace EbookViewer.Core.Mobi;

/// <summary>画像・フォントなどのリソースレコードの判別と復号。</summary>
internal static class MobiResources
{
    public sealed record Resource(string Path, string MediaType, byte[] Data);

    /// <summary>
    /// firstResource から end (exclusive) までのレコードを走査し、リソース番号 (1 始まり) → リソースの表を作る。
    /// 画像は Images/imageNNNNN.ext、フォントは Fonts/fontNNNNN.ext に割り当てる。
    /// </summary>
    public static Dictionary<int, Resource> Collect(PalmDatabase db, int firstResource, int end, out string? rescXml)
    {
        var result = new Dictionary<int, Resource>();
        rescXml = null;
        if (firstResource < 0) return result;
        end = Math.Min(end, db.RecordCount);
        for (int rec = firstResource; rec < end; rec++)
        {
            int number = rec - firstResource + 1;
            var data = db.GetRecord(rec);
            if (data.Length < 4) continue;
            string magic4 = System.Text.Encoding.ASCII.GetString(data[..4]);
            switch (magic4)
            {
                case "BOUN": // BOUNDARY
                    return result;
                case "FLIS":
                case "FCIS":
                case "FDST":
                case "DATP":
                case "SRCS":
                case "PAGE":
                case "CMET":
                case "AUDI":
                case "VIDE":
                case "CRES":
                case "CONT":
                case "INDX":
                case "IDXT":
                case "kind":
                    continue;
                case "RESC":
                    rescXml ??= ExtractResc(data);
                    continue;
                case "FONT":
                    {
                        var font = DecodeFont(data);
                        if (font != null)
                        {
                            var (bytes, ext, mime) = font.Value;
                            result[number] = new Resource($"Fonts/font{number:D5}{ext}", mime, bytes);
                        }
                        continue;
                    }
            }
            if (data[0] == 0xE9 && data[1] == 0x8E && data[2] == 0x0D && data[3] == 0x0A) // EOF
                continue;
            var image = DetectImage(data);
            if (image != null)
            {
                var (ext, mime) = image.Value;
                result[number] = new Resource($"Images/image{number:D5}{ext}", mime, data.ToArray());
            }
        }
        return result;
    }

    public static (string ext, string mime)? DetectImage(ReadOnlySpan<byte> d)
    {
        if (d.Length < 12) return null;
        if (d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return (".jpg", "image/jpeg");
        if (d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G') return (".png", "image/png");
        if (d[0] == 'G' && d[1] == 'I' && d[2] == 'F' && d[3] == '8') return (".gif", "image/gif");
        if (d[0] == 'B' && d[1] == 'M') return (".bmp", "image/bmp");
        if (d[0] == 'R' && d[1] == 'I' && d[2] == 'F' && d[3] == 'F' && d[8] == 'W' && d[9] == 'E' && d[10] == 'B' && d[11] == 'P') return (".webp", "image/webp");
        if (d[0] == '<')
        {
            var head = System.Text.Encoding.ASCII.GetString(d[..Math.Min(d.Length, 512)]);
            if (head.Contains("<svg", StringComparison.OrdinalIgnoreCase)) return (".svg", "image/svg+xml");
        }
        return null;
    }

    /// <summary>Kindle の FONT レコード (zlib 圧縮 + XOR 難読化) を復号する。</summary>
    private static (byte[] data, string ext, string mime)? DecodeFont(ReadOnlySpan<byte> rec)
    {
        if (rec.Length < 24) return null;
        uint decodedSize = BinaryPrimitives.ReadUInt32BigEndian(rec[4..]);
        uint flags = BinaryPrimitives.ReadUInt32BigEndian(rec[8..]);
        int dataStart = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[12..]);
        int xorLen = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[16..]);
        int xorStart = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[20..]);
        if (dataStart < 0 || dataStart > rec.Length) return null;
        var data = rec[dataStart..].ToArray();
        if ((flags & 2) != 0 && xorLen > 0 && xorStart + xorLen <= rec.Length)
        {
            var key = rec.Slice(xorStart, xorLen);
            int n = Math.Min(1040, data.Length);
            for (int i = 0; i < n; i++) data[i] ^= key[i % xorLen];
        }
        if ((flags & 1) != 0)
        {
            try
            {
                using var input = new MemoryStream(data);
                using var z = new ZLibStream(input, CompressionMode.Decompress);
                using var output = new MemoryStream((int)Math.Min(decodedSize, 64 * 1024 * 1024));
                z.CopyTo(output);
                data = output.ToArray();
            }
            catch (Exception)
            {
                return null;
            }
        }
        if (data.Length < 4) return null;
        if (data[0] == 'O' && data[1] == 'T' && data[2] == 'T' && data[3] == 'O') return (data, ".otf", "font/otf");
        if (data[0] == 'w' && data[1] == 'O' && data[2] == 'F' && data[3] == 'F') return (data, ".woff", "font/woff");
        if (data[0] == 'w' && data[1] == 'O' && data[2] == 'F' && data[3] == '2') return (data, ".woff2", "font/woff2");
        return (data, ".ttf", "font/ttf");
    }

    private static string? ExtractResc(ReadOnlySpan<byte> rec)
    {
        // "RESC" + 12 バイトヘッダー + XML (先頭に "<?xml" / "<package" が現れる)
        var text = System.Text.Encoding.UTF8.GetString(rec[Math.Min(16, rec.Length)..]);
        int start = text.IndexOf('<');
        return start < 0 ? null : text[start..].TrimEnd('\0');
    }

    public static string Base32Decode(string s)
    {
        return FromBase32(s).ToString();
    }

    public static long FromBase32(string s)
    {
        long v = 0;
        foreach (char c in s.ToUpperInvariant())
        {
            int d = c is >= '0' and <= '9' ? c - '0' : c is >= 'A' and <= 'V' ? c - 'A' + 10 : -1;
            if (d < 0) return -1;
            v = v * 32 + d;
        }
        return v;
    }
}
