import Foundation

/// .mobi / .azw3 / .azw / .prc を読み込む。KF8 部があればそちらを優先する。
public enum MobiLoader {
    public static func load(url: URL) throws -> BookDocument {
        try load(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func load(data: Data) throws -> BookDocument {
        let db = try PalmDatabase.parse(data)
        if !(db.type == "BOOK" && db.creator == "MOBI") && !(db.type == "TEXt" && db.creator == "REAd") {
            throw BookError.invalidData("Not a MOBI file (type/creator = \(db.type)/\(db.creator)).")
        }

        let header0 = try MobiHeader.parse(db.record(0))
        if header0.encryption != 0 {
            throw BookError.drmProtected
        }

        // KF8 部の探索: 単独 AZW3 なら record 0 が version 8、ハイブリッドなら EXTH 121 が境界レコードを指す
        var kf8Record = -1
        var kf8Header: MobiHeader?
        if header0.isKf8 {
            kf8Record = 0
            kf8Header = header0
        } else if let boundary = header0.exthUInt32(121), boundary != 0xFFFFFFFF {
            let candidate = Int(boundary)
            // 境界レコードそのもの ("BOUNDARY") か、その次が KF8 ヘッダー
            var r = candidate
            while r <= candidate + 1 && r < db.recordCount {
                let rec = db.record(r)
                if MobiHeader.looksLikeMobiHeader(rec), let h = try? MobiHeader.parse(rec), h.isKf8 {
                    kf8Record = r
                    kf8Header = h
                    break
                }
                r += 1
            }
        }

        if let kf8Header {
            if kf8Header.encryption != 0 {
                throw BookError.drmProtected
            }
            let resourceBase = resolveResourceBase(db, kf8: kf8Header, kf8Record: kf8Record, header0: header0)
            let builder = try Kf8Builder(db: db, header: kf8Header, headerRecord: kf8Record, resourceBase: resourceBase, resourceEnd: db.recordCount)
            return builder.build()
        }

        let base7 = header0.firstResourceIndex == MobiHeader.nullIndex ? -1 : Int(header0.firstResourceIndex)
        var end7 = db.recordCount
        if let boundary7 = header0.exthUInt32(121), Int(boundary7) < db.recordCount { end7 = Int(boundary7) }
        return try Mobi7Builder(db: db, header: header0, headerRecord: 0, resourceBase: base7, resourceEnd: end7).build()
    }

    /// KF8 ヘッダーの first_resource は単独 AZW3 では絶対レコード番号、ハイブリッドでは
    /// 先頭ヘッダー側のリソース領域を指すことがあるため、実際に画像が見つかる方を選ぶ。
    private static func resolveResourceBase(_ db: PalmDatabase, kf8: MobiHeader, kf8Record: Int, header0: MobiHeader) -> Int {
        var candidates: [Int] = []
        if kf8.firstResourceIndex != MobiHeader.nullIndex {
            candidates.append(Int(kf8.firstResourceIndex))
            if kf8Record > 0 { candidates.append(kf8Record + Int(kf8.firstResourceIndex)) }
        }
        if kf8Record > 0 && header0.firstResourceIndex != MobiHeader.nullIndex {
            candidates.append(Int(header0.firstResourceIndex))
        }
        for c in candidates {
            if c < 0 || c >= db.recordCount { continue }
            if MobiResources.detectImage(db.record(c)) != nil { return c }
            if db.recordStartsWith(c, "FONT") || db.recordStartsWith(c, "RESC") || db.recordStartsWith(c, "CRES") { return c }
        }
        return candidates.first { $0 >= 0 && $0 < db.recordCount } ?? -1
    }
}
