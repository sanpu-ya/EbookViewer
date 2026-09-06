namespace EbookViewer.Core.Mobi;

/// <summary>テキストレコードの展開 (末尾データの除去、PalmDOC / HUFF-CDIC 展開)。</summary>
internal static class MobiText
{
    /// <summary>ヘッダーレコード headerRecord に続くテキストレコードをすべて展開して連結する。</summary>
    public static byte[] ReadRawText(PalmDatabase db, MobiHeader header, int headerRecord)
    {
        if (header.Encryption != 0)
            throw new Model.UnsupportedBookException("この本は DRM で保護されているため開けません。");

        HuffCdicDecompressor? huff = null;
        if (header.Compression == 17480)
        {
            int huffRec = headerRecord + (int)header.HuffRecordOffset;
            var cdics = new List<byte[]>();
            for (int i = 1; i < header.HuffRecordCount; i++)
            {
                cdics.Add(db.GetRecordBytes(huffRec + i));
            }
            huff = new HuffCdicDecompressor(db.GetRecord(huffRec), cdics);
        }
        else if (header.Compression != 1 && header.Compression != 2)
        {
            throw new InvalidDataException($"未対応の圧縮形式です: {header.Compression}");
        }

        var ms = new MemoryStream((int)Math.Min(header.TextLength + 1024, int.MaxValue / 2));
        for (int i = 1; i <= header.TextRecordCount; i++)
        {
            var rec = db.GetRecord(headerRecord + i);
            if (rec.IsEmpty) break;
            int trailing = TrailingEntriesSize(rec, header.ExtraFlags);
            var body = rec[..(rec.Length - trailing)];
            byte[] decoded = header.Compression switch
            {
                1 => body.ToArray(),
                2 => PalmDocDecompressor.Decompress(body),
                _ => huff!.Decompress(body),
            };
            ms.Write(decoded);
        }
        return ms.ToArray();
    }

    /// <summary>レコード末尾の付加データ (マルチバイト継続バイト・TBS など) の合計サイズ。</summary>
    internal static int TrailingEntriesSize(ReadOnlySpan<byte> record, uint extraFlags)
    {
        int size = record.Length;
        int total = 0;
        uint flags = extraFlags >> 1;
        while (flags != 0)
        {
            if ((flags & 1) != 0)
            {
                long entrySize = MobiIndex.ReadBackwardVwi(record, size - total, out _);
                total += (int)Math.Min(entrySize, size - total);
            }
            flags >>= 1;
        }
        if ((extraFlags & 1) != 0 && size - total - 1 >= 0)
        {
            total += (record[size - total - 1] & 0x03) + 1;
        }
        return Math.Min(total, size);
    }
}
