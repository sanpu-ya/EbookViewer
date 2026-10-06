import Foundation

/// INDX レコード群 (NCX / スケルトン / フラグメント索引) の 1 エントリ。
struct IndexEntry {
    let label: [UInt8]
    let tags: [Int: [Int64]]

    var labelText: String { String(decoding: label, as: UTF8.self) }

    func tag(_ tag: Int, _ index: Int = 0) -> Int64? {
        guard let values = tags[tag], values.count > index else { return nil }
        return values[index]
    }
}

/// KindleUnpack の mobi_index.py 相当。INDX の主レコードから索引エントリ一覧と CNCX 文字列表を取り出す。
enum MobiIndex {
    struct Result {
        let entries: [IndexEntry]
        let cncx: [Int64: [UInt8]]
    }

    private struct TagxEntry {
        let tag: Int
        let valuesPerEntry: Int
        let mask: Int
        let endOfControlByte: Bool
    }

    static func read(_ db: PalmDatabase, indexRecord: Int) -> Result {
        var entries: [IndexEntry] = []
        var cncx: [Int64: [UInt8]] = [:]
        guard indexRecord >= 0, indexRecord < db.recordCount else { return Result(entries: entries, cncx: cncx) }

        let main = db.record(indexRecord)
        guard isIndx(main) else { return Result(entries: entries, cncx: cncx) }
        let headerLen = Int(main.u32BE(4))
        let indexCount = Int(main.u32BE(24))
        // INDX ヘッダー: len@4 type@12 gen@16 idxt@20 count@24 code@28 lng@32 total@36 ordt@40 ligt@44 nligt@48 ncncx@52
        let cncxCount = main.count >= 56 ? Int(main.u32BE(52)) : 0

        // TAGX
        var tagTable: [TagxEntry] = []
        var controlByteCount = 0
        if headerLen + 12 <= main.count && main.startsWith("TAGX", at: headerLen) {
            let tagxLen = Int(main.u32BE(headerLen + 4))
            controlByteCount = Int(main.u32BE(headerLen + 8))
            var p = headerLen + 12
            while p + 4 <= headerLen + tagxLen && p + 4 <= main.count {
                tagTable.append(TagxEntry(tag: Int(main[p]), valuesPerEntry: Int(main[p + 1]), mask: Int(main[p + 2]), endOfControlByte: main[p + 3] != 0))
                p += 4
            }
        }

        // CNCX (索引ラベル文字列表)
        var cncxOffset: Int64 = 0
        for i in 0..<cncxCount {
            let rec = indexRecord + 1 + indexCount + i
            if rec >= db.recordCount { break }
            let data = db.record(rec)
            var pos = 0
            while pos < data.count {
                let index = pos
                let len = Int(readForwardVwi(data, &pos))
                if pos + len > data.count { break }
                cncx[cncxOffset + Int64(index)] = data.slice(pos, len)
                pos += len
            }
            cncxOffset += 0x10000
        }

        // 索引エントリ
        for i in 0..<indexCount {
            let rec = indexRecord + 1 + i
            if rec >= db.recordCount { break }
            let data = db.record(rec)
            guard isIndx(data) else { continue }
            let idxtPos = Int(data.u32BE(20))
            let entryCount = Int(data.u32BE(24))
            if idxtPos + 4 > data.count { continue }
            for j in 0..<entryCount {
                let o = idxtPos + 4 + j * 2
                if o + 2 > data.count { break }
                let startPos = Int(data.u16BE(o))
                let endPos = (j + 1 < entryCount && o + 4 <= data.count) ? Int(data.u16BE(o + 2)) : idxtPos
                if startPos >= data.count || endPos > data.count || endPos < startPos { continue }
                let labelLen = Int(data[startPos])
                if startPos + 1 + labelLen > endPos { continue }
                let label = data.slice(startPos + 1, labelLen)
                let tags = readTagMap(controlByteCount, tagTable, data, startPos + 1 + labelLen, endPos)
                entries.append(IndexEntry(label: label, tags: tags))
            }
        }
        return Result(entries: entries, cncx: cncx)
    }

    private static func isIndx(_ data: [UInt8]) -> Bool {
        data.count >= 52 && data.startsWith("INDX")
    }

    private static func readTagMap(_ controlByteCount: Int, _ tagTable: [TagxEntry], _ data: [UInt8], _ startPos: Int, _ endPos: Int) -> [Int: [Int64]] {
        var tagMap: [Int: [Int64]] = [:]
        let controlBytes = data.slice(startPos, min(controlByteCount, endPos - startPos))
        var pos = startPos + controlByteCount
        var controlByteIndex = 0
        var pending: [(tag: Int, valueCount: Int?, valueBytes: Int64?, valuesPerEntry: Int)] = []
        for t in tagTable {
            if t.endOfControlByte {
                controlByteIndex += 1
                continue
            }
            if controlByteIndex >= controlBytes.count { break }
            var value = Int(controlBytes[controlByteIndex]) & t.mask
            if value == 0 { continue }
            if value == t.mask {
                if t.mask.nonzeroBitCount > 1 {
                    let count = readForwardVwi(data, &pos)
                    pending.append((t.tag, nil, count, t.valuesPerEntry))
                } else {
                    pending.append((t.tag, 1, nil, t.valuesPerEntry))
                }
            } else {
                var m = t.mask
                while (m & 1) == 0 {
                    m >>= 1
                    value >>= 1
                }
                pending.append((t.tag, value, nil, t.valuesPerEntry))
            }
        }
        for p in pending {
            var values: [Int64] = []
            if let valueCount = p.valueCount {
                var i = 0
                while i < valueCount * p.valuesPerEntry && pos < endPos {
                    values.append(readForwardVwi(data, &pos))
                    i += 1
                }
            } else if let valueBytes = p.valueBytes {
                var consumed: Int64 = 0
                while consumed < valueBytes && pos < endPos {
                    let before = pos
                    values.append(readForwardVwi(data, &pos))
                    consumed += Int64(pos - before)
                }
            }
            tagMap[p.tag] = values
        }
        return tagMap
    }

    /// 前方可変幅整数 (7 ビット/バイト、停止ビット 0x80 が末尾バイトに立つ)。
    static func readForwardVwi(_ data: [UInt8], _ pos: inout Int) -> Int64 {
        var value: Int64 = 0
        var i = 0
        while i < 5 && pos < data.count {
            let b = data[pos]
            pos += 1
            value = (value << 7) | Int64(b & 0x7F)
            if (b & 0x80) != 0 { break }
            i += 1
        }
        return value
    }

    /// 後方可変幅整数 (レコード末尾から読む)。返り値は (値, 消費バイト数)。
    static func readBackwardVwi(_ data: [UInt8], endExclusive: Int) -> (value: Int64, size: Int) {
        var value: Int64 = 0
        var shift: Int64 = 0
        var size = 0
        var p = endExclusive - 1
        while p >= 0 && size < 5 {
            let b = data[p]
            value |= Int64(b & 0x7F) << shift
            shift += 7
            size += 1
            if (b & 0x80) != 0 { break }
            p -= 1
        }
        return (value, size)
    }
}
