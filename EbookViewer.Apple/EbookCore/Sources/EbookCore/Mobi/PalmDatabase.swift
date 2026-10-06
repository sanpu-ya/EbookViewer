import Foundation

/// PalmDB (PDB) コンテナ。MOBI / AZW3 はこの形式のレコード集合。
public final class PalmDatabase: @unchecked Sendable {
    let data: [UInt8]
    private let offsets: [Int]

    public let name: String
    public let type: String
    public let creator: String
    public var recordCount: Int { offsets.count - 1 }

    private init(data: [UInt8], offsets: [Int], name: String, type: String, creator: String) {
        self.data = data
        self.offsets = offsets
        self.name = name
        self.type = type
        self.creator = creator
    }

    public static func parse(_ d: Data) throws -> PalmDatabase {
        let data = [UInt8](d)
        guard data.count >= 78 + 8 else { throw BookError.invalidData("PalmDB header is too short.") }
        let name = data.asciiString(0, 32).trimmingNulls
        let type = data.asciiString(60, 4)
        let creator = data.asciiString(64, 4)
        let count = Int(data.u16BE(76))
        guard count > 0 else { throw BookError.invalidData("PalmDB has no records.") }
        guard 78 + count * 8 <= data.count else { throw BookError.invalidData("PalmDB record table is corrupt.") }
        var offsets = [Int](repeating: 0, count: count + 1)
        for i in 0..<count {
            offsets[i] = min(Int(data.u32BE(78 + i * 8)), data.count)
        }
        offsets[count] = data.count
        // オフセットは単調増加のはずだが、壊れたファイルでも例外にならないよう補正する
        for i in 1...count where offsets[i] < offsets[i - 1] {
            offsets[i] = offsets[i - 1]
        }
        return PalmDatabase(data: data, offsets: offsets, name: name, type: type, creator: creator)
    }

    /// レコードのバイト列 (範囲外は空)。
    public func record(_ index: Int) -> [UInt8] {
        guard index >= 0, index < recordCount else { return [] }
        return Array(data[offsets[index]..<offsets[index + 1]])
    }

    public func recordStartsWith(_ index: Int, _ magic: String) -> Bool {
        guard index >= 0, index < recordCount else { return false }
        let m = Array(magic.utf8)
        let start = offsets[index]
        guard offsets[index + 1] - start >= m.count else { return false }
        for i in 0..<m.count where data[start + i] != m[i] { return false }
        return true
    }
}
