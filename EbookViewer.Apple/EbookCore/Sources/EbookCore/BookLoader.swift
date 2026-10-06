import Foundation

/// 拡張子とファイル先頭の署名から形式を判別して読み込む入口。
public enum BookLoader {
    public static let supportedExtensions = ["epub", "mobi", "azw3", "azw", "prc", "kf8"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func load(url: URL) throws -> BookDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BookError.fileNotFound(url.path)
        }
        // セキュリティスコープ付き URL (iOS / サンドボックス) でもアクセス終了後に参照できるよう、マップせず読み切る
        let data = try Data(contentsOf: url)
        return try load(data: data, fileName: url.lastPathComponent)
    }

    public static func load(data: Data, fileName: String) throws -> BookDocument {
        let head = [UInt8](data.prefix(80))
        // ZIP (EPUB) は "PK"、PalmDB は 60 バイト目から type/creator
        if head.count >= 2 && head[0] == 0x50 && head[1] == 0x4B {
            return try EpubLoader.load(data: data)
        }
        if head.count >= 68 {
            let type = head.asciiString(60, 4)
            let creator = head.asciiString(64, 4)
            if (type == "BOOK" && creator == "MOBI") || (type == "TEXt" && creator == "REAd") {
                return try MobiLoader.load(data: data)
            }
        }
        // PathUtil.getExtension は "." 付き小文字で返す
        switch PathUtil.getExtension(fileName) {
        case ".epub": return try EpubLoader.load(data: data)
        case ".mobi", ".azw3", ".azw", ".prc", ".kf8": return try MobiLoader.load(data: data)
        default: throw BookError.unsupportedFormat(fileName)
        }
    }

    public static func load(url: URL) async throws -> BookDocument {
        try await Task.detached(priority: .userInitiated) { try load(url: url) }.value
    }
}
