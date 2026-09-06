using System.Buffers.Binary;
using System.Text;

namespace EbookViewer.Core.Mobi;

/// <summary>INDX レコード群 (NCX / スケルトン / フラグメント索引) の 1 エントリ。</summary>
internal sealed class IndexEntry
{
    public IndexEntry(byte[] label, Dictionary<int, List<long>> tags)
    {
        Label = label;
        Tags = tags;
    }

    public byte[] Label { get; }
    public Dictionary<int, List<long>> Tags { get; }

    public string LabelText => Encoding.UTF8.GetString(Label);

    public long? Tag(int tag, int index = 0)
    {
        return Tags.TryGetValue(tag, out var values) && values.Count > index ? values[index] : null;
    }
}

/// <summary>KindleUnpack の mobi_index.py 相当。INDX の主レコードから索引エントリ一覧と CNCX 文字列表を取り出す。</summary>
internal static class MobiIndex
{
    public sealed record Result(List<IndexEntry> Entries, Dictionary<long, byte[]> Cncx);

    public static Result Read(PalmDatabase db, int indexRecord)
    {
        var entries = new List<IndexEntry>();
        var cncx = new Dictionary<long, byte[]>();
        if (indexRecord < 0 || indexRecord >= db.RecordCount) return new Result(entries, cncx);

        var main = db.GetRecord(indexRecord);
        if (!IsIndx(main)) return new Result(entries, cncx);
        int headerLen = (int)BinaryPrimitives.ReadUInt32BigEndian(main[4..]);
        int indexCount = (int)BinaryPrimitives.ReadUInt32BigEndian(main[24..]);
        // INDX ヘッダー: len@4 type@12 gen@16 idxt@20 count@24 code@28 lng@32 total@36 ordt@40 ligt@44 nligt@48 ncncx@52
        int cncxCount = main.Length >= 56 ? (int)BinaryPrimitives.ReadUInt32BigEndian(main[52..]) : 0;

        // TAGX
        var tagTable = new List<(int tag, int valuesPerEntry, int mask, bool endOfControlByte)>();
        int controlByteCount = 0;
        if (headerLen + 12 <= main.Length && main[headerLen] == 'T' && main[headerLen + 1] == 'A' && main[headerLen + 2] == 'G' && main[headerLen + 3] == 'X')
        {
            int tagxLen = (int)BinaryPrimitives.ReadUInt32BigEndian(main[(headerLen + 4)..]);
            controlByteCount = (int)BinaryPrimitives.ReadUInt32BigEndian(main[(headerLen + 8)..]);
            for (int p = headerLen + 12; p + 4 <= headerLen + tagxLen && p + 4 <= main.Length; p += 4)
            {
                tagTable.Add((main[p], main[p + 1], main[p + 2], main[p + 3] != 0));
            }
        }

        // CNCX (索引ラベル文字列表)
        long cncxOffset = 0;
        for (int i = 0; i < cncxCount; i++)
        {
            int rec = indexRecord + 1 + indexCount + i;
            if (rec >= db.RecordCount) break;
            var data = db.GetRecord(rec);
            int pos = 0;
            while (pos < data.Length)
            {
                int index = pos;
                int len = (int)ReadForwardVwi(data, ref pos);
                if (pos + len > data.Length) break;
                cncx[cncxOffset + index] = data.Slice(pos, len).ToArray();
                pos += len;
            }
            cncxOffset += 0x10000;
        }

        // 索引エントリ
        for (int i = 0; i < indexCount; i++)
        {
            int rec = indexRecord + 1 + i;
            if (rec >= db.RecordCount) break;
            var data = db.GetRecord(rec);
            if (!IsIndx(data)) continue;
            int idxtPos = (int)BinaryPrimitives.ReadUInt32BigEndian(data[20..]);
            int entryCount = (int)BinaryPrimitives.ReadUInt32BigEndian(data[24..]);
            if (idxtPos + 4 > data.Length) continue;
            for (int j = 0; j < entryCount; j++)
            {
                int o = idxtPos + 4 + j * 2;
                if (o + 2 > data.Length) break;
                int startPos = BinaryPrimitives.ReadUInt16BigEndian(data[o..]);
                int endPos = j + 1 < entryCount && o + 4 <= data.Length ? BinaryPrimitives.ReadUInt16BigEndian(data[(o + 2)..]) : idxtPos;
                if (startPos >= data.Length || endPos > data.Length || endPos < startPos) continue;
                int labelLen = data[startPos];
                if (startPos + 1 + labelLen > endPos) continue;
                var label = data.Slice(startPos + 1, labelLen).ToArray();
                var tags = ReadTagMap(controlByteCount, tagTable, data, startPos + 1 + labelLen, endPos);
                entries.Add(new IndexEntry(label, tags));
            }
        }
        return new Result(entries, cncx);
    }

    private static bool IsIndx(ReadOnlySpan<byte> data)
    {
        return data.Length >= 52 && data[0] == 'I' && data[1] == 'N' && data[2] == 'D' && data[3] == 'X';
    }

    private static Dictionary<int, List<long>> ReadTagMap(
        int controlByteCount,
        List<(int tag, int valuesPerEntry, int mask, bool endOfControlByte)> tagTable,
        ReadOnlySpan<byte> data, int startPos, int endPos)
    {
        var tagMap = new Dictionary<int, List<long>>();
        var controlBytes = data.Slice(startPos, Math.Min(controlByteCount, endPos - startPos)).ToArray();
        int pos = startPos + controlByteCount;
        int controlByteIndex = 0;
        var pending = new List<(int tag, int? valueCount, long? valueBytes, int valuesPerEntry)>();
        foreach (var (tag, valuesPerEntry, mask, end) in tagTable)
        {
            if (end)
            {
                controlByteIndex++;
                continue;
            }
            if (controlByteIndex >= controlBytes.Length) break;
            int value = controlBytes[controlByteIndex] & mask;
            if (value == 0) continue;
            if (value == mask)
            {
                if (System.Numerics.BitOperations.PopCount((uint)mask) > 1)
                {
                    long count = ReadForwardVwi(data, ref pos);
                    pending.Add((tag, null, count, valuesPerEntry));
                }
                else
                {
                    pending.Add((tag, 1, null, valuesPerEntry));
                }
            }
            else
            {
                int m = mask;
                while ((m & 1) == 0)
                {
                    m >>= 1;
                    value >>= 1;
                }
                pending.Add((tag, value, null, valuesPerEntry));
            }
        }
        foreach (var (tag, valueCount, valueBytes, valuesPerEntry) in pending)
        {
            var values = new List<long>();
            if (valueCount != null)
            {
                for (int i = 0; i < valueCount * valuesPerEntry && pos < endPos; i++)
                    values.Add(ReadForwardVwi(data, ref pos));
            }
            else
            {
                long consumed = 0;
                while (consumed < valueBytes && pos < endPos)
                {
                    int before = pos;
                    values.Add(ReadForwardVwi(data, ref pos));
                    consumed += pos - before;
                }
            }
            tagMap[tag] = values;
        }
        return tagMap;
    }

    /// <summary>前方可変幅整数 (7 ビット/バイト、停止ビット 0x80 が末尾バイトに立つ)。</summary>
    public static long ReadForwardVwi(ReadOnlySpan<byte> data, ref int pos)
    {
        long value = 0;
        for (int i = 0; i < 5 && pos < data.Length; i++)
        {
            byte b = data[pos++];
            value = (value << 7) | (uint)(b & 0x7F);
            if ((b & 0x80) != 0) break;
        }
        return value;
    }

    /// <summary>後方可変幅整数 (レコード末尾から読む)。返り値は値、size に消費バイト数。</summary>
    public static long ReadBackwardVwi(ReadOnlySpan<byte> data, int endExclusive, out int size)
    {
        long value = 0;
        int shift = 0;
        size = 0;
        for (int p = endExclusive - 1; p >= 0 && size < 5; p--)
        {
            byte b = data[p];
            value |= (long)(b & 0x7F) << shift;
            shift += 7;
            size++;
            if ((b & 0x80) != 0) break;
        }
        return value;
    }
}
