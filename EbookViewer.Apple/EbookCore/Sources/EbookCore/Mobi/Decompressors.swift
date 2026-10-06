import Foundation

/// PalmDOC (LZ77 系) 圧縮の展開。
public enum PalmDocDecompressor {
    public static func decompress(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 4)
        var i = 0
        let n = input.count
        while i < n {
            let c = input[i]
            i += 1
            if c == 0 {
                output.append(0)
            } else if c <= 8 {
                // 続く c バイトはリテラル
                var k = 0
                while k < Int(c) && i < n { output.append(input[i]); i += 1; k += 1 }
            } else if c < 0x80 {
                output.append(c)
            } else if c >= 0xC0 {
                output.append(0x20)
                output.append(c ^ 0x80)
            } else {
                if i >= n { break }
                let pair = Int(c) << 8 | Int(input[i])
                i += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 7) + 3
                let start = output.count - distance
                if distance == 0 || start < 0 { continue }
                for k in 0..<length { output.append(output[start + k]) }
            }
        }
        return output
    }
}

/// HUFF/CDIC 圧縮の展開 (calibre の HuffReader と同じアルゴリズム)。
final class HuffCdicDecompressor {
    private var dict1 = [(codeLen: Int, term: Bool, maxCode: UInt32)](repeating: (0, false, 0), count: 256)
    private var minCodes = [UInt32](repeating: 0, count: 33)
    private var maxCodes = [UInt32](repeating: 0, count: 33)
    private var dictionary: [(data: [UInt8], expanded: Bool)?] = []

    init(huff: [UInt8], cdics: [[UInt8]]) throws {
        guard huff.count >= 24, huff.startsWith("HUFF") else { throw BookError.invalidData("Invalid HUFF record.") }
        let off1 = Int(huff.u32BE(8))
        let off2 = Int(huff.u32BE(12))
        for i in 0..<256 {
            let v = huff.u32BE(off1 + i * 4)
            let codeLen = Int(v & 0x1F)
            let term = (v & 0x80) != 0
            var maxCode = v >> 8
            guard codeLen > 0 else { throw BookError.invalidData("Invalid HUFF table.") }
            maxCode = UInt32(truncatingIfNeeded: ((UInt64(maxCode) + 1) << UInt64(32 - codeLen)) - 1)
            dict1[i] = (codeLen, term, maxCode)
        }
        for codeLen in 0..<32 {
            let mn = huff.u32BE(off2 + codeLen * 8)
            let mx = huff.u32BE(off2 + codeLen * 8 + 4)
            minCodes[codeLen] = codeLen == 0 ? 0 : UInt32(truncatingIfNeeded: UInt64(mn) << UInt64(32 - codeLen))
            maxCodes[codeLen] = codeLen == 0 ? 0 : UInt32(truncatingIfNeeded: ((UInt64(mx) + 1) << UInt64(32 - codeLen)) - 1)
        }
        minCodes[32] = 0
        maxCodes[32] = 0

        for cdic in cdics {
            guard cdic.count >= 16, cdic.startsWith("CDIC") else { continue }
            let phrases = Int(cdic.u32BE(8))
            let bits = Int(cdic.u32BE(12))
            let n = min(1 << bits, phrases - dictionary.count)
            if n <= 0 { continue }
            for i in 0..<n {
                let off = Int(cdic.u16BE(16 + i * 2))
                let blen = Int(cdic.u16BE(16 + off))
                let len = blen & 0x7FFF
                let slice = cdic.slice(18 + off, min(len, cdic.count - 18 - off))
                dictionary.append((slice, (blen & 0x8000) != 0))
            }
        }
    }

    func decompress(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 4)
        try unpack(data, into: &out)
        return out
    }

    private func unpack(_ input: [UInt8], into output: inout [UInt8]) throws {
        var bitsLeft = Int64(input.count) * 8
        var data = input
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        var pos = 0
        var x = data.u64BE(pos)
        var n = 32
        while true {
            if n <= 0 {
                pos += 4
                x = data.u64BE(pos)
                n += 32
            }
            let code = UInt32(truncatingIfNeeded: x >> UInt64(n))
            var (codeLen, term, maxCode) = dict1[Int(code >> 24)]
            if !term {
                while codeLen < 32 && code < minCodes[codeLen] { codeLen += 1 }
                maxCode = maxCodes[codeLen]
            }
            n -= codeLen
            bitsLeft -= Int64(codeLen)
            if bitsLeft < 0 { break }
            let r = Int((maxCode &- code) >> UInt32(32 - codeLen))
            guard r >= 0, r < dictionary.count else { throw BookError.invalidData("HUFF/CDIC dictionary reference out of range.") }
            guard let entry = dictionary[r] else { throw BookError.invalidData("Recursive HUFF/CDIC dictionary entry.") }
            var slice = entry.data
            if !entry.expanded {
                dictionary[r] = nil
                var inner: [UInt8] = []
                try unpack(slice, into: &inner)
                slice = inner
                dictionary[r] = (slice, true)
            }
            output.append(contentsOf: slice)
        }
    }
}
