using EbookViewer.Core.Model;

namespace EbookViewer.Core.Mobi;

/// <summary>.mobi / .azw3 / .azw / .prc を読み込む。KF8 部があればそちらを優先する。</summary>
public static class MobiLoader
{
    public static BookDocument Load(string filePath)
    {
        return Load(File.ReadAllBytes(filePath));
    }

    public static BookDocument Load(byte[] data)
    {
        var db = PalmDatabase.Parse(data);
        if (!(db.Type == "BOOK" && db.Creator == "MOBI") && !(db.Type == "TEXt" && db.Creator == "REAd"))
            throw new InvalidDataException($"MOBI 形式ではありません (type/creator = {db.Type}/{db.Creator})。");

        var header0 = MobiHeader.Parse(db.GetRecord(0));
        if (header0.Encryption != 0)
            throw new UnsupportedBookException("この本は DRM で保護されているため開けません。");

        // KF8 部の探索: 単独 AZW3 なら record 0 が version 8、ハイブリッドなら EXTH 121 が境界レコードを指す
        int kf8Record = -1;
        MobiHeader? kf8Header = null;
        if (header0.IsKf8)
        {
            kf8Record = 0;
            kf8Header = header0;
        }
        else
        {
            uint? boundary = header0.GetExthUInt32(121);
            if (boundary != null && boundary.Value != 0xFFFFFFFF)
            {
                int candidate = (int)boundary.Value;
                // 境界レコードそのもの ("BOUNDARY") か、その次が KF8 ヘッダー
                for (int r = candidate; r <= candidate + 1 && r < db.RecordCount; r++)
                {
                    if (MobiHeader.LooksLikeMobiHeader(db.GetRecord(r)))
                    {
                        var h = MobiHeader.Parse(db.GetRecord(r));
                        if (h.IsKf8)
                        {
                            kf8Record = r;
                            kf8Header = h;
                            break;
                        }
                    }
                }
            }
        }

        if (kf8Header != null)
        {
            if (kf8Header.Encryption != 0)
                throw new UnsupportedBookException("この本は DRM で保護されているため開けません。");
            int resourceBase = ResolveResourceBase(db, kf8Header, kf8Record, header0);
            var builder = new Kf8Builder(db, kf8Header, kf8Record, resourceBase, db.RecordCount);
            return builder.Build();
        }

        int base7 = header0.FirstResourceIndex == MobiHeader.NullIndex ? -1 : (int)header0.FirstResourceIndex;
        int end7 = db.RecordCount;
        uint? boundary7 = header0.GetExthUInt32(121);
        if (boundary7 != null && boundary7.Value < (uint)db.RecordCount) end7 = (int)boundary7.Value;
        var builder7 = new Mobi7Builder(db, header0, 0, base7, end7);
        return builder7.Build();
    }

    /// <summary>
    /// KF8 ヘッダーの first_resource は単独 AZW3 では絶対レコード番号、ハイブリッドでは
    /// 先頭ヘッダー側のリソース領域を指すことがあるため、実際に画像が見つかる方を選ぶ。
    /// </summary>
    private static int ResolveResourceBase(PalmDatabase db, MobiHeader kf8, int kf8Record, MobiHeader header0)
    {
        var candidates = new List<int>();
        if (kf8.FirstResourceIndex != MobiHeader.NullIndex)
        {
            candidates.Add((int)kf8.FirstResourceIndex);
            if (kf8Record > 0) candidates.Add(kf8Record + (int)kf8.FirstResourceIndex);
        }
        if (kf8Record > 0 && header0.FirstResourceIndex != MobiHeader.NullIndex)
            candidates.Add((int)header0.FirstResourceIndex);
        foreach (int c in candidates)
        {
            if (c < 0 || c >= db.RecordCount) continue;
            if (MobiResources.DetectImage(db.GetRecord(c)) != null) return c;
            if (db.RecordStartsWith(c, "FONT") || db.RecordStartsWith(c, "RESC") || db.RecordStartsWith(c, "CRES")) return c;
        }
        return candidates.FirstOrDefault(c => c >= 0 && c < db.RecordCount, -1);
    }
}
