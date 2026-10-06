import Foundation

/// 読み取り専用の ZIP コンテナ。中央ディレクトリを走査し、エントリを必要時に展開する (stored / deflate のみ)。
final class ZipArchive: @unchecked Sendable {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: [UInt8]
    private(set) var entries: [Entry] = []
    private let lock = NSLock()

    init(data: Data) throws {
        self.data = [UInt8](data)
        try readCentralDirectory()
    }

    convenience init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: d)
    }

    private func readCentralDirectory() throws {
        // End of central directory record (0x06054b50) を末尾から探す
        guard data.count >= 22 else { throw BookError.invalidData("ZIP file is too short.") }
        var eocd = -1
        var i = data.count - 22
        let minPos = max(0, data.count - 22 - 65535)
        while i >= minPos {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw BookError.invalidData("ZIP central directory not found.") }
        var count = Int(data.u16LE(eocd + 10))
        var cdOffset = Int(data.u32LE(eocd + 16))
        var cdSize = Int(data.u32LE(eocd + 12))

        // ZIP64
        if count == 0xFFFF || cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF {
            let locator = eocd - 20
            if locator >= 0, data.u32LE(locator) == 0x07064B50 {
                let z64 = Int(data.u64LE_le(locator + 8))
                if z64 >= 0, z64 + 56 <= data.count, data.u32LE(z64) == 0x06064B50 {
                    count = Int(data.u64LE_le(z64 + 32))
                    cdSize = Int(data.u64LE_le(z64 + 40))
                    cdOffset = Int(data.u64LE_le(z64 + 48))
                }
            }
        }

        var p = cdOffset
        var list: [Entry] = []
        list.reserveCapacity(count)
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32LE(p) == 0x02014B50 else { break }
            let method = data.u16LE(p + 10)
            var csize = Int(data.u32LE(p + 20))
            var usize = Int(data.u32LE(p + 24))
            let nameLen = Int(data.u16LE(p + 28))
            let extraLen = Int(data.u16LE(p + 30))
            let commentLen = Int(data.u16LE(p + 32))
            var offset = Int(data.u32LE(p + 42))
            let flags = data.u16LE(p + 8)
            let nameBytes = data.slice(p + 46, nameLen)
            // bit 11: UTF-8 名。そうでなければ CP437 だが、実用上 UTF-8 → Latin-1 の順で解釈する
            let name = (flags & 0x800) != 0 ? String(decoding: nameBytes, as: UTF8.self)
                : (String(bytes: nameBytes, encoding: .utf8) ?? TextEncoding.latin1.decode(nameBytes))
            // ZIP64 拡張フィールド
            if csize == 0xFFFFFFFF || usize == 0xFFFFFFFF || offset == 0xFFFFFFFF {
                var e = p + 46 + nameLen
                let extraEnd = e + extraLen
                while e + 4 <= extraEnd {
                    let id = data.u16LE(e)
                    let len = Int(data.u16LE(e + 2))
                    if id == 0x0001 {
                        var q = e + 4
                        if usize == 0xFFFFFFFF { usize = Int(data.u64LE_le(q)); q += 8 }
                        if csize == 0xFFFFFFFF { csize = Int(data.u64LE_le(q)); q += 8 }
                        if offset == 0xFFFFFFFF { offset = Int(data.u64LE_le(q)); q += 8 }
                        break
                    }
                    e += 4 + len
                }
            }
            list.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    /// エントリを展開して返す。
    func read(_ entry: Entry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let h = entry.localHeaderOffset
        guard h + 30 <= data.count, data.u32LE(h) == 0x04034B50 else {
            throw BookError.invalidData("Corrupt ZIP local header: " + entry.name)
        }
        let nameLen = Int(data.u16LE(h + 26))
        let extraLen = Int(data.u16LE(h + 28))
        let start = h + 30 + nameLen + extraLen
        guard start <= data.count else { throw BookError.invalidData("ZIP entry out of range: " + entry.name) }
        let raw = data.slice(start, entry.compressedSize)
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            return Data(try Inflate.inflate(raw, format: .raw, expectedSize: entry.uncompressedSize))
        default:
            throw BookError.invalidData("Unsupported ZIP compression method (\(entry.method)): " + entry.name)
        }
    }
}

private extension Array where Element == UInt8 {
    func u64LE_le(_ off: Int) -> UInt64 {
        guard off >= 0, off + 8 <= count else { return 0 }
        return UInt64(u32LE(off)) | UInt64(u32LE(off + 4)) << 32
    }
}
