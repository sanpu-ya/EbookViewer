import Foundation

public enum PathUtil {
    /// "/" 区切り、"." ".." を解決し、先頭スラッシュを除いた形にする。%XX は復号する。
    public static func normalize(_ input: String) -> String {
        if input.isEmpty { return "" }
        var path = input.replacingOccurrences(of: "\\", with: "/")
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path
        var parts: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: false) {
            if seg.isEmpty || seg == "." { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(seg)
        }
        return parts.joined(separator: "/")
    }

    /// basePath (ファイルのパス) から見た相対参照 href を書籍ルート相対パスに解決する。
    public static func resolve(basePath: String, href: String) -> String {
        let dir = getDirectory(basePath)
        if href.hasPrefix("/") { return normalize(href) }
        return normalize(dir.isEmpty ? href : dir + "/" + href)
    }

    public static func getDirectory(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    public static func getFileName(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: i)...])
    }

    public static func getExtension(_ path: String) -> String {
        let name = getFileName(path)
        guard let i = name.lastIndex(of: ".") else { return "" }
        return String(name[i...]).lowercased()
    }

    /// fromPath (ファイル) から toPath (ファイル) への相対パスを作る。
    public static func makeRelative(from fromPath: String, to toPath: String) -> String {
        let from = getDirectory(normalize(fromPath)).split(separator: "/").map(String.init)
        let to = normalize(toPath).split(separator: "/").map(String.init)
        var common = 0
        while common < from.count && common < to.count - 1 && from[common] == to[common] { common += 1 }
        var s = ""
        for _ in common..<from.count { s += "../" }
        for i in common..<to.count {
            if i > common { s += "/" }
            s += to[i]
        }
        return s
    }

    public static func mediaType(fromExtension path: String) -> String {
        switch getExtension(path) {
        case ".xhtml", ".xht": return "application/xhtml+xml"
        case ".html", ".htm": return "text/html"
        case ".css": return "text/css"
        case ".js": return "text/javascript"
        case ".png": return "image/png"
        case ".jpg", ".jpeg", ".jpe": return "image/jpeg"
        case ".gif": return "image/gif"
        case ".svg": return "image/svg+xml"
        case ".webp": return "image/webp"
        case ".bmp": return "image/bmp"
        case ".tif", ".tiff": return "image/tiff"
        case ".heic", ".heif": return "image/heic"
        case ".avif": return "image/avif"
        case ".jxl": return "image/jxl"
        case ".ttf": return "font/ttf"
        case ".otf": return "font/otf"
        case ".woff": return "font/woff"
        case ".woff2": return "font/woff2"
        case ".ncx": return "application/x-dtbncx+xml"
        case ".opf": return "application/oebps-package+xml"
        case ".xml": return "application/xml"
        case ".txt": return "text/plain"
        case ".mp3": return "audio/mpeg"
        case ".mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    public static func isHtmlMediaType(_ mediaType: String) -> Bool {
        mediaType.range(of: "html", options: .caseInsensitive) != nil
    }
}
