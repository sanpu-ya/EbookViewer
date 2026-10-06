import Foundation

/// ビッグエンディアンのバイト列読み取り (範囲外は安全に既定値を返す)。
extension Array where Element == UInt8 {
    @inline(__always)
    func u8(_ off: Int) -> UInt8 {
        off >= 0 && off < count ? self[off] : 0
    }

    func u16BE(_ off: Int) -> UInt16 {
        guard off >= 0, off + 2 <= count else { return 0 }
        return UInt16(self[off]) << 8 | UInt16(self[off + 1])
    }

    func u32BE(_ off: Int) -> UInt32 {
        guard off >= 0, off + 4 <= count else { return 0 }
        return UInt32(self[off]) << 24 | UInt32(self[off + 1]) << 16 | UInt32(self[off + 2]) << 8 | UInt32(self[off + 3])
    }

    func u64BE(_ off: Int) -> UInt64 {
        guard off >= 0, off + 8 <= count else { return 0 }
        return UInt64(u32BE(off)) << 32 | UInt64(u32BE(off + 4))
    }

    func u16LE(_ off: Int) -> UInt16 {
        guard off >= 0, off + 2 <= count else { return 0 }
        return UInt16(self[off]) | UInt16(self[off + 1]) << 8
    }

    func u32LE(_ off: Int) -> UInt32 {
        guard off >= 0, off + 4 <= count else { return 0 }
        return UInt32(self[off]) | UInt32(self[off + 1]) << 8 | UInt32(self[off + 2]) << 16 | UInt32(self[off + 3]) << 24
    }

    /// 範囲を配列の長さに収めて切り出す。
    func slice(_ start: Int, _ length: Int) -> [UInt8] {
        let s = Swift.max(0, Swift.min(start, count))
        let e = Swift.max(s, Swift.min(start + length, count))
        return Array(self[s..<e])
    }

    func startsWith(_ magic: String, at off: Int = 0) -> Bool {
        let m = Array(magic.utf8)
        guard off >= 0, off + m.count <= count else { return false }
        for i in 0..<m.count where self[off + i] != m[i] { return false }
        return true
    }

    func asciiString(_ start: Int, _ length: Int) -> String {
        String(decoding: slice(start, length), as: UTF8.self)
    }
}

extension String {
    /// 先頭・末尾の NUL を除く。
    var trimmingNulls: String {
        var s = Substring(self)
        while s.last == "\0" { s.removeLast() }
        return String(s)
    }

    func hasPrefixIgnoringCase(_ p: String) -> Bool {
        range(of: p, options: [.caseInsensitive, .anchored]) != nil
    }

    func containsIgnoringCase(_ p: String) -> Bool {
        range(of: p, options: .caseInsensitive) != nil
    }

    func equalsIgnoringCase(_ other: String?) -> Bool {
        guard let other else { return false }
        return caseInsensitiveCompare(other) == .orderedSame
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}
