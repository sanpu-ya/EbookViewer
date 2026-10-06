import Foundation
import Unrar

/// CBZ / ZIP / CBR / RAR 書庫、または画像フォルダーをコミックとして読み込む。
/// 書庫内 (またはフォルダー内) の ComicInfo.xml があればメタデータとして取り込む。
/// PDF はアプリ側 (PDFKit) で扱うので、ここでは対象外。
public enum ComicLoader {
    /// 読み込める書庫の拡張子。
    public static let archiveExtensions = ["cbz", "zip", "cbr", "rar"]
    /// RAR 書庫の拡張子 (unrar で展開する)。
    public static let rarExtensions = ["cbr", "rar"]
    /// 形式としては認識するが展開できない書庫 (7z / tar / ACE)。分かりやすいエラーを返すために区別する。
    public static let unsupportedArchiveExtensions = ["cb7", "cbt", "cba"]
    /// ページとして扱う画像の拡張子 (ImageIO でデコードできるもの)。
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "jxl",
    ]
    public static let comicInfoFileName = "ComicInfo.xml"

    /// 拡張子、またはフォルダーであることから、コミックとして開ける対象か。
    public static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) || unsupportedArchiveExtensions.contains(ext) { return true }
        return isDirectory(url)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func isRar(_ url: URL) -> Bool {
        rarExtensions.contains(url.pathExtension.lowercased())
    }

    /// 表示している間もファイルへのアクセスを維持する必要があるか。
    /// フォルダーと RAR はページを要求されるたびにディスクから読むので、サンドボックスのスコープ付きアクセスを閉じてはいけない。
    public static func needsPersistentAccess(_ url: URL) -> Bool {
        isRar(url) || isDirectory(url)
    }

    public static func isImage(_ name: String) -> Bool {
        // PathUtil.getExtension は "." 付き小文字で返す
        let ext = PathUtil.getExtension(name)
        return !ext.isEmpty && imageExtensions.contains(String(ext.dropFirst()))
    }

    /// 隠しファイル・隠しフォルダー配下・macOS のリソースフォーク (__MACOSX) か。
    static func isIgnoredEntry(_ name: String) -> Bool {
        name.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
    }

    /// 書庫内のエントリをページとして採用するか。
    static func isPageEntry(_ name: String) -> Bool {
        if name.hasSuffix("/") || isIgnoredEntry(name) { return false }
        return isImage(name)
    }

    /// ComicInfo.xml か (パスは問わない)。
    static func isComicInfoEntry(_ name: String) -> Bool {
        !isIgnoredEntry(name) && PathUtil.getFileName(name).caseInsensitiveCompare(comicInfoFileName) == .orderedSame
    }

    /// 複数の ComicInfo.xml があればもっとも浅い階層のものを選ぶ。
    static func preferredComicInfo<T>(_ entries: [T], name: (T) -> String) -> T? {
        var best: T?
        var bestDepth = Int.max
        for e in entries {
            let n = normalizedEntryName(name(e))
            guard isComicInfoEntry(n) else { continue }
            let depth = n.split(separator: "/").count
            if depth < bestDepth {
                best = e
                bestDepth = depth
            }
        }
        return best
    }

    /// 書庫内パスの区切りを "/" に揃える (Windows で作られた RAR は "\" のことがある)。
    static func normalizedEntryName(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }

    /// ファイル名の自然順 ("2.jpg" < "10.jpg")。大文字小文字は区別しない。
    public static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    public static func load(url: URL) throws -> ComicDocument {
        if isDirectory(url) { return try loadFolder(url) }
        let ext = url.pathExtension.lowercased()
        if unsupportedArchiveExtensions.contains(ext) {
            throw BookError.unsupported(Localized.format("Comic archives in this format (.%@) are not supported. Please convert it to CBZ.", ext))
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw BookError.fileNotFound(url.path) }
        if isRar(url) { return try loadRar(url) }
        // セキュリティスコープ付き URL でもアクセス終了後にページを取り出せるよう、読み切ってから解析する
        let data = try Data(contentsOf: url)
        return try load(data: data, fileName: url.lastPathComponent)
    }

    // MARK: - 共通: ページ列と ComicInfo からドキュメントを組み立てる

    /// 画像 (ファイル名順) と ComicInfo.xml の内容からドキュメントを作る。
    /// ComicInfo の Pages で Deleted とされた画像は除き、Bookmark は残ったページの添字に付け替える。
    static func makeDocument(format: ComicFormat, fileName: String, infoData: Data?,
                             images: [(name: String, loader: () throws -> Data)]) throws -> ComicDocument {
        let info = infoData.flatMap { ComicInfo.parse($0) }
        let byImage = info?.pagesByImage ?? [:]
        var pages: [ComicPage] = []
        var bookmarks: [ComicBookmark] = []
        for (i, image) in images.enumerated() {
            let pageInfo = byImage[i]
            if pageInfo?.type == .deleted { continue }
            if let pageInfo, !pageInfo.bookmark.isEmpty {
                bookmarks.append(ComicBookmark(title: pageInfo.bookmark, pageIndex: pages.count))
            }
            pages.append(ComicPage(name: image.name, mediaType: PathUtil.mediaType(fromExtension: image.name), info: pageInfo, loader: image.loader))
        }
        guard !pages.isEmpty else { throw BookError.unsupported(Localized.format("No images were found in %@.", fileName)) }
        let title = info?.displayTitle ?? titleFromFileName(fileName)
        return ComicDocument(format: format, title: title, pages: pages, info: info, bookmarks: bookmarks)
    }

    // MARK: - ZIP

    public static func load(data: Data, fileName: String) throws -> ComicDocument {
        let zip = try ZipArchive(data: data)
        let images = zip.entries.filter { isPageEntry($0.name) }.sorted { naturalOrder($0.name, $1.name) }
        let infoData = preferredComicInfo(zip.entries, name: \.name).flatMap { try? zip.read($0) }
        return try makeDocument(format: .cbz, fileName: fileName, infoData: infoData,
                                images: images.map { e in (e.name, { try zip.read(e) }) })
    }

    // MARK: - RAR

    /// RAR 書庫を開く。エントリは要求のたびに unrar で展開する (書庫全体をメモリに載せない)。
    public static func loadRar(_ url: URL) throws -> ComicDocument {
        let archive: Archive
        let allEntries: [Entry]
        do {
            archive = try Archive(fileURL: url)
            if archive.isHeaderEncrypted {
                throw BookError.unsupported(Localized.string("This comic archive is password protected."))
            }
            allEntries = try archive.entries()
        } catch let error as BookError {
            throw error
        } catch {
            throw BookError.invalidData("Could not open RAR archive \(url.lastPathComponent): \(error)")
        }
        let candidates = allEntries.filter { !$0.directory && isPageEntry(normalizedEntryName($0.fileName)) }
        let images = candidates.filter { !$0.encrypted }
            .sorted { naturalOrder(normalizedEntryName($0.fileName), normalizedEntryName($1.fileName)) }
        if images.isEmpty && !candidates.isEmpty {
            throw BookError.unsupported(Localized.string("This comic archive is password protected."))
        }
        let infoData = preferredComicInfo(allEntries.filter { !$0.directory && !$0.encrypted }, name: \.fileName)
            .flatMap { try? archive.extract($0) }
        // ソリッド書庫では目的のエントリまで順に展開されるので、同じ書庫への並行展開は避ける
        let lock = NSLock()
        return try makeDocument(format: .cbr, fileName: url.lastPathComponent, infoData: infoData,
                                images: images.map { e in
                                    (normalizedEntryName(e.fileName), {
                                        lock.lock()
                                        defer { lock.unlock() }
                                        return try archive.extract(e)
                                    })
                                })
    }

    // MARK: - フォルダー

    /// フォルダー内の画像 (サブフォルダーも含む) を相対パスの自然順で並べる。
    public static func loadFolder(_ url: URL) throws -> ComicDocument {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw BookError.fileNotFound(url.path)
        }
        let basePath = url.standardizedFileURL.path
        var files: [(relative: String, url: URL)] = []
        var infoFiles: [(relative: String, url: URL)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            var rel = fileURL.standardizedFileURL.path
            if rel.hasPrefix(basePath) { rel = String(rel.dropFirst(basePath.count)) }
            if rel.hasPrefix("/") { rel.removeFirst() }
            if isImage(fileURL.lastPathComponent) {
                files.append((rel, fileURL))
            } else if isComicInfoEntry(rel) {
                infoFiles.append((rel, fileURL))
            }
        }
        files.sort { naturalOrder($0.relative, $1.relative) }
        let infoData = preferredComicInfo(infoFiles, name: \.relative).flatMap { try? Data(contentsOf: $0.url) }
        return try makeDocument(format: .folder, fileName: url.lastPathComponent, infoData: infoData,
                                images: files.map { f in (f.relative, { try Data(contentsOf: f.url) }) })
    }

    static func titleFromFileName(_ fileName: String) -> String {
        let ext = PathUtil.getExtension(fileName)
        return ext.isEmpty ? fileName : String(fileName.dropLast(ext.count))
    }
}
