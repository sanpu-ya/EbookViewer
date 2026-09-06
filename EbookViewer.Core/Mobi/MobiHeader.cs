using System.Buffers.Binary;
using System.Text;

namespace EbookViewer.Core.Mobi;

/// <summary>PalmDOC ヘッダー + MOBI ヘッダー + EXTH をまとめて解析したもの。</summary>
internal sealed class MobiHeader
{
    public const uint NullIndex = 0xFFFFFFFF;

    public int Compression { get; private set; }
    public uint TextLength { get; private set; }
    public int TextRecordCount { get; private set; }
    public int TextRecordSize { get; private set; }
    public int Encryption { get; private set; }

    public int HeaderLength { get; private set; }
    public uint MobiType { get; private set; }
    public int TextEncoding { get; private set; }
    public uint Version { get; private set; }
    public uint FirstNonBookIndex { get; private set; }
    public uint FirstResourceIndex { get; private set; }
    public uint HuffRecordOffset { get; private set; }
    public uint HuffRecordCount { get; private set; }
    public uint ExthFlags { get; private set; }
    public uint FirstContentRecord { get; private set; }
    public uint LastContentRecord { get; private set; }
    public uint FdstIndex { get; private set; } = NullIndex;
    public uint FdstCount { get; private set; }
    public uint ExtraFlags { get; private set; }
    public uint NcxIndex { get; private set; } = NullIndex;
    public uint FragmentIndex { get; private set; } = NullIndex;
    public uint SkeletonIndex { get; private set; } = NullIndex;
    public uint GuideIndex { get; private set; } = NullIndex;
    public string FullName { get; private set; } = string.Empty;
    public List<(uint type, byte[] data)> Exth { get; } = [];

    public bool IsKf8 => Version >= 8;
    public Encoding TextEncodingObject => TextEncoding == 1252 ? CodePage1252 : Encoding.UTF8;

    private static readonly Encoding CodePage1252 = GetCp1252();

    private static Encoding GetCp1252()
    {
        try
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(1252);
        }
        catch
        {
            return Encoding.Latin1;
        }
    }

    public static bool LooksLikeMobiHeader(ReadOnlySpan<byte> record)
    {
        return record.Length >= 24 && record[16] == 'M' && record[17] == 'O' && record[18] == 'B' && record[19] == 'I';
    }

    public static MobiHeader Parse(ReadOnlySpan<byte> rec)
    {
        if (rec.Length < 16) throw new InvalidDataException("MOBI ヘッダーが短すぎます。");
        var h = new MobiHeader
        {
            Compression = BinaryPrimitives.ReadUInt16BigEndian(rec),
            TextLength = BinaryPrimitives.ReadUInt32BigEndian(rec[4..]),
            TextRecordCount = BinaryPrimitives.ReadUInt16BigEndian(rec[8..]),
            TextRecordSize = BinaryPrimitives.ReadUInt16BigEndian(rec[10..]),
            Encryption = BinaryPrimitives.ReadUInt16BigEndian(rec[12..]),
        };
        if (!LooksLikeMobiHeader(rec))
        {
            // 純粋な PalmDOC (MOBI ヘッダー無し)
            h.HeaderLength = 0;
            h.TextEncoding = 1252;
            return h;
        }
        h.HeaderLength = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[0x14..]);
        h.MobiType = BinaryPrimitives.ReadUInt32BigEndian(rec[0x18..]);
        h.TextEncoding = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[0x1C..]);
        h.Version = BinaryPrimitives.ReadUInt32BigEndian(rec[0x24..]);
        int end = Math.Min(rec.Length, 16 + h.HeaderLength);
        byte[] hdr = rec[..end].ToArray();
        uint U32(int off) => off + 4 <= hdr.Length ? BinaryPrimitives.ReadUInt32BigEndian(hdr.AsSpan(off)) : NullIndex;
        uint U16(int off) => off + 2 <= hdr.Length ? BinaryPrimitives.ReadUInt16BigEndian(hdr.AsSpan(off)) : 0u;

        h.FirstNonBookIndex = U32(0x50);
        uint fullNameOffset = U32(0x54);
        uint fullNameLength = U32(0x58);
        h.FirstResourceIndex = U32(0x6C);
        h.HuffRecordOffset = U32(0x70);
        h.HuffRecordCount = U32(0x74);
        h.ExthFlags = U32(0x80);
        if (h.IsKf8)
        {
            h.FdstIndex = U32(0xC0);
            h.FdstCount = U32(0xC4);
        }
        else
        {
            h.FirstContentRecord = U16(0xC0);
            h.LastContentRecord = U16(0xC2);
        }
        if (h.HeaderLength >= 0xE4 && h.Version >= 5)
        {
            h.ExtraFlags = U16(0xF2);
        }
        if (16 + h.HeaderLength >= 0xF8)
        {
            h.NcxIndex = U32(0xF4);
        }
        if (h.IsKf8)
        {
            h.FragmentIndex = U32(0xF8);
            h.SkeletonIndex = U32(0xFC);
            h.GuideIndex = U32(0x104);
        }
        if (fullNameOffset != NullIndex && fullNameLength != NullIndex && fullNameOffset + fullNameLength <= rec.Length)
        {
            h.FullName = h.TextEncodingObject.GetString(rec.Slice((int)fullNameOffset, (int)fullNameLength)).TrimEnd('\0');
        }

        // EXTH
        if ((h.ExthFlags & 0x40) != 0)
        {
            int exthStart = 16 + h.HeaderLength;
            if (exthStart + 12 <= rec.Length && rec[exthStart] == 'E' && rec[exthStart + 1] == 'X' && rec[exthStart + 2] == 'T' && rec[exthStart + 3] == 'H')
            {
                int count = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[(exthStart + 8)..]);
                int pos = exthStart + 12;
                for (int i = 0; i < count && pos + 8 <= rec.Length; i++)
                {
                    uint type = BinaryPrimitives.ReadUInt32BigEndian(rec[pos..]);
                    int len = (int)BinaryPrimitives.ReadUInt32BigEndian(rec[(pos + 4)..]);
                    if (len < 8 || pos + len > rec.Length) break;
                    h.Exth.Add((type, rec.Slice(pos + 8, len - 8).ToArray()));
                    pos += len;
                }
            }
        }
        return h;
    }

    public string? GetExthString(uint type)
    {
        foreach (var (t, data) in Exth)
        {
            if (t == type) return TextEncodingObject.GetString(data).TrimEnd('\0');
        }
        return null;
    }

    public IEnumerable<string> GetExthStrings(uint type)
    {
        foreach (var (t, data) in Exth)
        {
            if (t == type) yield return TextEncodingObject.GetString(data).TrimEnd('\0');
        }
    }

    public uint? GetExthUInt32(uint type)
    {
        foreach (var (t, data) in Exth)
        {
            if (t == type && data.Length == 4) return BinaryPrimitives.ReadUInt32BigEndian(data);
        }
        return null;
    }
}
