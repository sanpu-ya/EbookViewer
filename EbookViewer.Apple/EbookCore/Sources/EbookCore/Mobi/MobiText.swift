import Foundation

/// テキストレコードの展開 (末尾データの除去、PalmDOC / HUFF-CDIC 展開)。
enum MobiText {
    /// ヘッダーレコード headerRecord に続くテキストレコードをすべて展開して連結する。
    static func readRawText(_ db: PalmDatabase, header: MobiHeader, headerRecord: Int) throws -> [UInt8] {
        if header.encryption != 0 {
            throw BookError.drmProtected
        }

        var huff: HuffCdicDecompressor?
        if header.compression == 17480 {
            let huffRec = headerRecord + Int(header.huffRecordOffset)
            var cdics: [[UInt8]] = []
            if header.huffRecordCount > 1 {
                for i in 1..<Int(header.huffRecordCount) {
                    cdics.append(db.record(huffRec + i))
                }
            }
            huff = try HuffCdicDecompressor(huff: db.record(huffRec), cdics: cdics)
        } else if header.compression != 1 && header.compression != 2 {
            throw BookError.invalidData("Unsupported compression type: \(header.compression)")
        }

        var out: [UInt8] = []
        out.reserveCapacity(Int(min(header.textLength, 256 * 1024 * 1024)) + 1024)
        if header.textRecordCount > 0 {
            for i in 1...header.textRecordCount {
                let rec = db.record(headerRecord + i)
                if rec.isEmpty { break }
                let trailing = trailingEntriesSize(rec, extraFlags: header.extraFlags)
                let body = rec.slice(0, rec.count - trailing)
                switch header.compression {
                case 1: out.append(contentsOf: body)
                case 2: out.append(contentsOf: PalmDocDecompressor.decompress(body))
                default: out.append(contentsOf: try huff!.decompress(body))
                }
            }
        }
        return out
    }

    /// レコード末尾の付加データ (マルチバイト継続バイト・TBS など) の合計サイズ。
    static func trailingEntriesSize(_ record: [UInt8], extraFlags: UInt32) -> Int {
        let size = record.count
        var total = 0
        var flags = extraFlags >> 1
        while flags != 0 {
            if (flags & 1) != 0 {
                let (entrySize, _) = MobiIndex.readBackwardVwi(record, endExclusive: size - total)
                total += Int(min(entrySize, Int64(size - total)))
            }
            flags >>= 1
        }
        if (extraFlags & 1) != 0 && size - total - 1 >= 0 {
            total += Int(record[size - total - 1] & 0x03) + 1
        }
        return min(total, size)
    }
}
