import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import EbookCore

/// PDF をコミック (ページ画像の列) として開く。各ページは要求時に PDFKit で描画し、JPEG にして返す。
enum PdfComicLoader {
    /// 描画するページの長辺 (ピクセル)。
    static let renderMaxPixel: CGFloat = 2400
    /// 同じ PDFDocument への並行アクセスは不安定なので描画を直列化する。
    private static let renderLock = NSLock()

    static func load(url: URL) throws -> ComicDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BookError.fileNotFound(url.path) }
        // セキュリティスコープ付き URL でもアクセス終了後に描画できるよう、メモリに読み切ってから開く
        let data = try Data(contentsOf: url)
        guard let doc = PDFDocument(data: data) else {
            throw BookError.invalidData("Could not parse PDF: " + url.lastPathComponent)
        }
        if doc.isLocked { throw BookError.unsupported(String(localized: "This PDF is password protected.")) }
        guard doc.pageCount > 0 else { throw BookError.unsupported(String(localized: "The PDF has no pages.")) }

        var pages: [ComicPage] = []
        for i in 0..<doc.pageCount {
            let known = pageSize(doc.page(at: i)).map { ComicPageSize(width: Double($0.width), height: Double($0.height)) }
            pages.append(ComicPage(name: "page-\(i + 1)", mediaType: "image/jpeg", knownSize: known) { try render(doc, index: i) })
        }
        let attrTitle = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = attrTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : attrTitle
        return ComicDocument(format: .pdf, title: title, pages: pages)
    }

    /// ページの回転を反映した表示サイズ (ポイント)。
    static func pageSize(_ page: PDFPage?) -> CGSize? {
        guard let page else { return nil }
        let b = page.bounds(for: .cropBox)
        let rotated = ((page.rotation / 90) % 2) != 0
        return rotated ? CGSize(width: b.height, height: b.width) : b.size
    }

    static func render(_ doc: PDFDocument, index: Int) throws -> Data {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let page = doc.page(at: index), let size = pageSize(page), size.width > 0, size.height > 0 else {
            throw BookError.invalidData("PDF page \(index + 1) could not be read.")
        }
        let scale = renderMaxPixel / max(size.width, size.height)
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let image = page.thumbnail(of: pixels, for: .cropBox)
        #if os(macOS)
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        let cg = image.cgImage
        #endif
        guard let cg else { throw BookError.invalidData("PDF page \(index + 1) could not be rendered.") }
        guard let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BookError.invalidData("PDF page \(index + 1) could not be encoded.")
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BookError.invalidData("PDF page \(index + 1) could not be encoded.") }
        return out as Data
    }
}
