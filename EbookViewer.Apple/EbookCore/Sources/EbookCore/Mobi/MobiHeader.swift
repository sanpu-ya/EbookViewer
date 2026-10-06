import Foundation

/// PalmDOC ヘッダー + MOBI ヘッダー + EXTH をまとめて解析したもの。
public struct MobiHeader: Sendable {
    public static let nullIndex: UInt32 = 0xFFFFFFFF

    public var compression = 0
    public var textLength: UInt32 = 0
    public var textRecordCount = 0
    public var textRecordSize = 0
    public var encryption = 0

    public var headerLength = 0
    public var mobiType: UInt32 = 0
    public var textEncoding = 0
    public var version: UInt32 = 0
    public var firstNonBookIndex: UInt32 = nullIndex
    public var firstResourceIndex: UInt32 = nullIndex
    public var huffRecordOffset: UInt32 = 0
    public var huffRecordCount: UInt32 = 0
    public var exthFlags: UInt32 = 0
    public var firstContentRecord: UInt32 = 0
    public var lastContentRecord: UInt32 = 0
    public var fdstIndex: UInt32 = nullIndex
    public var fdstCount: UInt32 = 0
    public var extraFlags: UInt32 = 0
    public var ncxIndex: UInt32 = nullIndex
    public var fragmentIndex: UInt32 = nullIndex
    public var skeletonIndex: UInt32 = nullIndex
    public var guideIndex: UInt32 = nullIndex
    public var fullName = ""
    public var exth: [(type: UInt32, data: [UInt8])] = []

    public var isKf8: Bool { version >= 8 }
    var textEncodingObject: TextEncoding { textEncoding == 1252 ? .cp1252 : .utf8 }

    public static func looksLikeMobiHeader(_ record: [UInt8]) -> Bool {
        record.count >= 24 && record.startsWith("MOBI", at: 16)
    }

    public static func parse(_ rec: [UInt8]) throws -> MobiHeader {
        guard rec.count >= 16 else { throw BookError.invalidData("MOBI header is too short.") }
        var h = MobiHeader()
        h.compression = Int(rec.u16BE(0))
        h.textLength = rec.u32BE(4)
        h.textRecordCount = Int(rec.u16BE(8))
        h.textRecordSize = Int(rec.u16BE(10))
        h.encryption = Int(rec.u16BE(12))
        if !looksLikeMobiHeader(rec) {
            // 純粋な PalmDOC (MOBI ヘッダー無し)
            h.headerLength = 0
            h.textEncoding = 1252
            return h
        }
        h.headerLength = Int(rec.u32BE(0x14))
        h.mobiType = rec.u32BE(0x18)
        h.textEncoding = Int(rec.u32BE(0x1C))
        h.version = rec.u32BE(0x24)
        let end = min(rec.count, 16 + h.headerLength)
        let hdr = rec.slice(0, end)
        func u32(_ off: Int) -> UInt32 { off + 4 <= hdr.count ? hdr.u32BE(off) : nullIndex }
        func u16(_ off: Int) -> UInt32 { off + 2 <= hdr.count ? UInt32(hdr.u16BE(off)) : 0 }

        h.firstNonBookIndex = u32(0x50)
        let fullNameOffset = u32(0x54)
        let fullNameLength = u32(0x58)
        h.firstResourceIndex = u32(0x6C)
        h.huffRecordOffset = u32(0x70)
        h.huffRecordCount = u32(0x74)
        h.exthFlags = u32(0x80)
        if h.isKf8 {
            h.fdstIndex = u32(0xC0)
            h.fdstCount = u32(0xC4)
        } else {
            h.firstContentRecord = u16(0xC0)
            h.lastContentRecord = u16(0xC2)
        }
        if h.headerLength >= 0xE4 && h.version >= 5 {
            h.extraFlags = u16(0xF2)
        }
        if 16 + h.headerLength >= 0xF8 {
            h.ncxIndex = u32(0xF4)
        }
        if h.isKf8 {
            h.fragmentIndex = u32(0xF8)
            h.skeletonIndex = u32(0xFC)
            h.guideIndex = u32(0x104)
        }
        if fullNameOffset != nullIndex && fullNameLength != nullIndex && Int(fullNameOffset) + Int(fullNameLength) <= rec.count {
            h.fullName = h.textEncodingObject.decode(rec.slice(Int(fullNameOffset), Int(fullNameLength))).trimmingNulls
        }

        // EXTH
        if (h.exthFlags & 0x40) != 0 {
            let exthStart = 16 + h.headerLength
            if exthStart + 12 <= rec.count && rec.startsWith("EXTH", at: exthStart) {
                let count = Int(rec.u32BE(exthStart + 8))
                var pos = exthStart + 12
                var i = 0
                while i < count && pos + 8 <= rec.count {
                    let type = rec.u32BE(pos)
                    let len = Int(rec.u32BE(pos + 4))
                    if len < 8 || pos + len > rec.count { break }
                    h.exth.append((type, rec.slice(pos + 8, len - 8)))
                    pos += len
                    i += 1
                }
            }
        }
        return h
    }

    public func exthString(_ type: UInt32) -> String? {
        for (t, data) in exth where t == type {
            return textEncodingObject.decode(data).trimmingNulls
        }
        return nil
    }

    public func exthStrings(_ type: UInt32) -> [String] {
        exth.filter { $0.type == type }.map { textEncodingObject.decode($0.data).trimmingNulls }
    }

    public func exthUInt32(_ type: UInt32) -> UInt32? {
        for (t, data) in exth where t == type && data.count == 4 {
            return data.u32BE(0)
        }
        return nil
    }
}
