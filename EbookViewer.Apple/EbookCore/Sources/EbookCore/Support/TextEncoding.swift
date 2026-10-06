import Foundation

/// MOBI (CP1252) や EPUB 内の各種文字コードのデコード。Linux の Foundation でも動くよう CP1252 は自前で持つ。
enum TextEncoding: Sendable {
    case utf8
    case cp1252
    case latin1
    case shiftJIS
    case eucJP
    case iso2022JP
    case utf16LE
    case utf16BE

    // 0x80-0x9F の CP1252 固有部分。0 は未定義 (Latin-1 と同じ扱いにする)。
    private static let cp1252High: [UInt32] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    /// charset 名から対応する文字コードを求める。未知なら nil。
    static func named(_ name: String) -> TextEncoding? {
        let n = name.lowercased().replacingOccurrences(of: "_", with: "-")
        switch n {
        case "utf-8", "utf8": return .utf8
        case "windows-1252", "cp1252", "cp-1252", "x-cp1252": return .cp1252
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1", "us-ascii", "ascii": return .latin1
        case "shift-jis", "sjis", "x-sjis", "ms932", "windows-31j", "cp932": return .shiftJIS
        case "euc-jp", "eucjp", "x-euc-jp": return .eucJP
        case "iso-2022-jp", "csiso2022jp": return .iso2022JP
        case "utf-16le", "utf-16": return .utf16LE
        case "utf-16be": return .utf16BE
        default:
            if n.hasPrefix("shift") && n.contains("jis") { return .shiftJIS }
            return nil
        }
    }

    func decode(_ bytes: [UInt8]) -> String {
        switch self {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .cp1252, .latin1:
            var scalars = String.UnicodeScalarView()
            for b in bytes {
                var v = UInt32(b)
                if self == .cp1252, b >= 0x80, b <= 0x9F {
                    let m = Self.cp1252High[Int(b - 0x80)]
                    if m != 0 { v = m }
                }
                scalars.append(Unicode.Scalar(v)!)
            }
            return String(scalars)
        case .shiftJIS:
            return String(data: Data(bytes), encoding: .shiftJIS) ?? String(decoding: bytes, as: UTF8.self)
        case .eucJP:
            return String(data: Data(bytes), encoding: .japaneseEUC) ?? String(decoding: bytes, as: UTF8.self)
        case .iso2022JP:
            return String(data: Data(bytes), encoding: .iso2022JP) ?? String(decoding: bytes, as: UTF8.self)
        case .utf16LE:
            return String(data: Data(bytes), encoding: .utf16LittleEndian) ?? ""
        case .utf16BE:
            return String(data: Data(bytes), encoding: .utf16BigEndian) ?? ""
        }
    }
}
