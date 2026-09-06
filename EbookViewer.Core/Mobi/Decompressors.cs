using System.Buffers.Binary;

namespace EbookViewer.Core.Mobi;

/// <summary>PalmDOC (LZ77 系) 圧縮の展開。</summary>
internal static class PalmDocDecompressor
{
    public static byte[] Decompress(ReadOnlySpan<byte> input)
    {
        var output = new List<byte>(input.Length * 4);
        int i = 0;
        while (i < input.Length)
        {
            byte c = input[i++];
            if (c == 0)
            {
                output.Add(0);
            }
            else if (c <= 8)
            {
                // 続く c バイトはリテラル
                for (int k = 0; k < c && i < input.Length; k++) output.Add(input[i++]);
            }
            else if (c < 0x80)
            {
                output.Add(c);
            }
            else if (c >= 0xC0)
            {
                output.Add((byte)' ');
                output.Add((byte)(c ^ 0x80));
            }
            else
            {
                if (i >= input.Length) break;
                int pair = (c << 8) | input[i++];
                int distance = (pair >> 3) & 0x7FF;
                int length = (pair & 7) + 3;
                int start = output.Count - distance;
                if (distance == 0 || start < 0) continue;
                for (int k = 0; k < length; k++) output.Add(output[start + k]);
            }
        }
        return output.ToArray();
    }
}

/// <summary>HUFF/CDIC 圧縮の展開 (calibre の HuffReader と同じアルゴリズム)。</summary>
internal sealed class HuffCdicDecompressor
{
    private readonly (int codeLen, bool term, uint maxCode)[] _dict1 = new (int, bool, uint)[256];
    private readonly uint[] _minCodes = new uint[33];
    private readonly uint[] _maxCodes = new uint[33];
    private readonly List<(byte[] data, bool expanded)?> _dictionary = [];

    public HuffCdicDecompressor(ReadOnlySpan<byte> huff, IEnumerable<byte[]> cdics)
    {
        if (huff.Length < 24 || huff[0] != 'H' || huff[1] != 'U' || huff[2] != 'F' || huff[3] != 'F')
            throw new InvalidDataException("HUFF レコードが不正です。");
        int off1 = (int)BinaryPrimitives.ReadUInt32BigEndian(huff[8..]);
        int off2 = (int)BinaryPrimitives.ReadUInt32BigEndian(huff[12..]);
        for (int i = 0; i < 256; i++)
        {
            uint v = BinaryPrimitives.ReadUInt32BigEndian(huff[(off1 + i * 4)..]);
            int codeLen = (int)(v & 0x1F);
            bool term = (v & 0x80) != 0;
            uint maxCode = v >> 8;
            if (codeLen == 0) throw new InvalidDataException("HUFF テーブルが不正です。");
            maxCode = (uint)(((ulong)(maxCode + 1) << (32 - codeLen)) - 1);
            _dict1[i] = (codeLen, term, maxCode);
        }
        for (int codeLen = 0; codeLen < 32; codeLen++)
        {
            uint min = BinaryPrimitives.ReadUInt32BigEndian(huff[(off2 + codeLen * 8)..]);
            uint max = BinaryPrimitives.ReadUInt32BigEndian(huff[(off2 + codeLen * 8 + 4)..]);
            _minCodes[codeLen] = codeLen == 0 ? 0 : (uint)((ulong)min << (32 - codeLen));
            _maxCodes[codeLen] = codeLen == 0 ? 0 : (uint)(((ulong)(max + 1) << (32 - codeLen)) - 1);
        }
        _minCodes[32] = 0;
        _maxCodes[32] = 0;

        foreach (var cdic in cdics)
        {
            if (cdic.Length < 16 || cdic[0] != 'C' || cdic[1] != 'D' || cdic[2] != 'I' || cdic[3] != 'C') continue;
            int phrases = (int)BinaryPrimitives.ReadUInt32BigEndian(cdic.AsSpan(8));
            int bits = (int)BinaryPrimitives.ReadUInt32BigEndian(cdic.AsSpan(12));
            int n = Math.Min(1 << bits, phrases - _dictionary.Count);
            for (int i = 0; i < n; i++)
            {
                int off = BinaryPrimitives.ReadUInt16BigEndian(cdic.AsSpan(16 + i * 2));
                int blen = BinaryPrimitives.ReadUInt16BigEndian(cdic.AsSpan(16 + off));
                int len = blen & 0x7FFF;
                var slice = cdic.AsSpan(18 + off, Math.Min(len, cdic.Length - 18 - off)).ToArray();
                _dictionary.Add((slice, (blen & 0x8000) != 0));
            }
        }
    }

    public byte[] Decompress(ReadOnlySpan<byte> data)
    {
        var ms = new MemoryStream(data.Length * 4);
        Unpack(data, ms);
        return ms.ToArray();
    }

    private void Unpack(ReadOnlySpan<byte> input, MemoryStream output)
    {
        long bitsLeft = (long)input.Length * 8;
        var data = new byte[input.Length + 8];
        input.CopyTo(data);
        int pos = 0;
        ulong x = BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(pos));
        int n = 32;
        while (true)
        {
            if (n <= 0)
            {
                pos += 4;
                x = BinaryPrimitives.ReadUInt64BigEndian(data.AsSpan(pos));
                n += 32;
            }
            uint code = (uint)((x >> n) & 0xFFFFFFFF);
            var (codeLen, term, maxCode) = _dict1[code >> 24];
            if (!term)
            {
                while (codeLen < 32 && code < _minCodes[codeLen]) codeLen++;
                maxCode = _maxCodes[codeLen];
            }
            n -= codeLen;
            bitsLeft -= codeLen;
            if (bitsLeft < 0) break;
            int r = (int)((maxCode - code) >> (32 - codeLen));
            if (r < 0 || r >= _dictionary.Count) throw new InvalidDataException("HUFF/CDIC の辞書参照が範囲外です。");
            var entry = _dictionary[r];
            if (entry == null) throw new InvalidDataException("HUFF/CDIC の辞書が再帰しています。");
            var (slice, expanded) = entry.Value;
            if (!expanded)
            {
                _dictionary[r] = null;
                var inner = new MemoryStream();
                Unpack(slice, inner);
                slice = inner.ToArray();
                _dictionary[r] = (slice, true);
            }
            output.Write(slice);
        }
    }
}
