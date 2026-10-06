import Foundation

/// 画像・フォントなどのリソースレコードの判別と復号。
enum MobiResources {
    struct Resource {
        let path: String
        let mediaType: String
        let data: [UInt8]
    }

    /// firstResource から end (exclusive) までのレコードを走査し、リソース番号 (1 始まり) → リソースの表を作る。
    /// 画像は Images/imageNNNNN.ext、フォントは Fonts/fontNNNNN.ext に割り当てる。
    static func collect(_ db: PalmDatabase, firstResource: Int, end: Int) -> (resources: [Int: Resource], rescXml: String?) {
        var result: [Int: Resource] = [:]
        var rescXml: String?
        if firstResource < 0 { return (result, nil) }
        let end = min(end, db.recordCount)
        if firstResource >= end { return (result, nil) }
        for rec in firstResource..<end {
            let number = rec - firstResource + 1
            let data = db.record(rec)
            if data.count < 4 { continue }
            let magic4 = data.asciiString(0, 4)
            switch magic4 {
            case "BOUN": // BOUNDARY
                return (result, rescXml)
            case "FLIS", "FCIS", "FDST", "DATP", "SRCS", "PAGE", "CMET", "AUDI", "VIDE", "CRES", "CONT", "INDX", "IDXT", "kind":
                continue
            case "RESC":
                if rescXml == nil { rescXml = extractResc(data) }
                continue
            case "FONT":
                if let font = decodeFont(data) {
                    result[number] = Resource(path: String(format: "Fonts/font%05d%@", number, font.ext), mediaType: font.mime, data: font.data)
                }
                continue
            default:
                break
            }
            if data[0] == 0xE9 && data[1] == 0x8E && data[2] == 0x0D && data[3] == 0x0A { // EOF
                continue
            }
            if let image = detectImage(data) {
                result[number] = Resource(path: String(format: "Images/image%05d%@", number, image.ext), mediaType: image.mime, data: data)
            }
        }
        return (result, rescXml)
    }

    static func detectImage(_ d: [UInt8]) -> (ext: String, mime: String)? {
        guard d.count >= 12 else { return nil }
        if d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF { return (".jpg", "image/jpeg") }
        if d[0] == 0x89 && d.startsWith("PNG", at: 1) { return (".png", "image/png") }
        if d.startsWith("GIF8") { return (".gif", "image/gif") }
        if d.startsWith("BM") { return (".bmp", "image/bmp") }
        if d.startsWith("RIFF") && d.startsWith("WEBP", at: 8) { return (".webp", "image/webp") }
        if d[0] == 0x3C { // '<'
            let head = d.asciiString(0, min(d.count, 512))
            if head.containsIgnoringCase("<svg") { return (".svg", "image/svg+xml") }
        }
        return nil
    }

    /// Kindle の FONT レコード (zlib 圧縮 + XOR 難読化) を復号する。
    private static func decodeFont(_ rec: [UInt8]) -> (data: [UInt8], ext: String, mime: String)? {
        guard rec.count >= 24 else { return nil }
        let decodedSize = Int(rec.u32BE(4))
        let flags = rec.u32BE(8)
        let dataStart = Int(rec.u32BE(12))
        let xorLen = Int(rec.u32BE(16))
        let xorStart = Int(rec.u32BE(20))
        guard dataStart >= 0, dataStart <= rec.count else { return nil }
        var data = rec.slice(dataStart, rec.count - dataStart)
        if (flags & 2) != 0 && xorLen > 0 && xorStart >= 0 && xorStart + xorLen <= rec.count {
            let key = rec.slice(xorStart, xorLen)
            let n = min(1040, data.count)
            for i in 0..<n { data[i] ^= key[i % xorLen] }
        }
        if (flags & 1) != 0 {
            guard let inflated = try? Inflate.inflate(data, format: .zlib, expectedSize: min(decodedSize, 64 * 1024 * 1024)) else { return nil }
            data = inflated
        }
        guard data.count >= 4 else { return nil }
        if data.startsWith("OTTO") { return (data, ".otf", "font/otf") }
        if data.startsWith("wOFF") { return (data, ".woff", "font/woff") }
        if data.startsWith("wOF2") { return (data, ".woff2", "font/woff2") }
        return (data, ".ttf", "font/ttf")
    }

    private static func extractResc(_ rec: [UInt8]) -> String? {
        // "RESC" + 12 バイトヘッダー + XML (先頭に "<?xml" / "<package" が現れる)
        let text = String(decoding: rec.slice(min(16, rec.count), rec.count), as: UTF8.self)
        guard let start = text.firstIndex(of: "<") else { return nil }
        return String(text[start...]).trimmingNulls
    }

    /// Kindle の base32 (0-9A-V) を整数にする。不正なら -1。
    static func fromBase32(_ s: String) -> Int64 {
        var v: Int64 = 0
        for c in s.uppercased().unicodeScalars {
            let d: Int64
            switch c.value {
            case 0x30...0x39: d = Int64(c.value - 0x30)
            case 0x41...0x56: d = Int64(c.value - 0x41 + 10)
            default: return -1
            }
            v = v * 32 + d
        }
        return v
    }
}
