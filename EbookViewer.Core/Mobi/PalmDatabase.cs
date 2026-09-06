using System.Buffers.Binary;
using System.Text;

namespace EbookViewer.Core.Mobi;

/// <summary>PalmDB (PDB) コンテナ。MOBI / AZW3 はこの形式のレコード集合。</summary>
internal sealed class PalmDatabase
{
    private readonly byte[] _data;
    private readonly int[] _offsets;

    private PalmDatabase(byte[] data, int[] offsets, string name, string type, string creator)
    {
        _data = data;
        _offsets = offsets;
        Name = name;
        Type = type;
        Creator = creator;
    }

    public string Name { get; }
    public string Type { get; }
    public string Creator { get; }
    public int RecordCount => _offsets.Length - 1;

    public static PalmDatabase Parse(byte[] data)
    {
        if (data.Length < 78 + 8) throw new InvalidDataException("PalmDB ヘッダーが短すぎます。");
        string name = Encoding.ASCII.GetString(data, 0, 32).TrimEnd('\0');
        string type = Encoding.ASCII.GetString(data, 60, 4);
        string creator = Encoding.ASCII.GetString(data, 64, 4);
        int count = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(76));
        if (count == 0) throw new InvalidDataException("PalmDB にレコードがありません。");
        if (78 + count * 8 > data.Length) throw new InvalidDataException("PalmDB のレコード表が壊れています。");
        var offsets = new int[count + 1];
        for (int i = 0; i < count; i++)
        {
            uint off = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(78 + i * 8));
            offsets[i] = (int)Math.Min(off, (uint)data.Length);
        }
        offsets[count] = data.Length;
        // オフセットは単調増加のはずだが、壊れたファイルでも例外にならないよう補正する
        for (int i = 1; i <= count; i++)
        {
            if (offsets[i] < offsets[i - 1]) offsets[i] = offsets[i - 1];
        }
        return new PalmDatabase(data, offsets, name, type, creator);
    }

    public ReadOnlySpan<byte> GetRecord(int index)
    {
        if (index < 0 || index >= RecordCount) return ReadOnlySpan<byte>.Empty;
        return _data.AsSpan(_offsets[index], _offsets[index + 1] - _offsets[index]);
    }

    public byte[] GetRecordBytes(int index) => GetRecord(index).ToArray();

    public bool RecordStartsWith(int index, string magic)
    {
        var rec = GetRecord(index);
        if (rec.Length < magic.Length) return false;
        for (int i = 0; i < magic.Length; i++)
        {
            if (rec[i] != (byte)magic[i]) return false;
        }
        return true;
    }
}
