import Foundation

/// EPUB 2 / 3 を読み込んで BookDocument を作る。
public enum EpubLoader {
    static let nsContainer = "urn:oasis:names:tc:opendocument:xmlns:container"
    static let nsOpf = "http://www.idpf.org/2007/opf"
    static let nsDc = "http://purl.org/dc/elements/1.1/"
    static let nsNcx = "http://www.daisy.org/z3986/2005/ncx/"
    static let nsXhtml = "http://www.w3.org/1999/xhtml"
    static let nsEpub = "http://www.idpf.org/2007/ops"
    static let nsEnc = "http://www.w3.org/2001/04/xmlenc#"

    static let idpfObfuscation = "http://www.idpf.org/2008/embedding"
    static let adobeObfuscation = "http://ns.adobe.com/pdf/enc#RC"

    public static func load(url: URL) throws -> BookDocument {
        try load(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func load(data: Data) throws -> BookDocument {
        let zip = try ZipArchive(data: data)
        return try loadCore(zip)
    }

    private static func loadCore(_ zip: ZipArchive) throws -> BookDocument {
        var entries: [String: ZipArchive.Entry] = [:]
        for e in zip.entries where !e.name.hasSuffix("/") {
            entries[PathUtil.normalize(e.name)] = e
        }

        // container.xml → OPF
        let opfPath = try findOpfPath(zip, entries)
        let opfDir = PathUtil.getDirectory(opfPath)
        guard let package = loadXml(zip, entries, opfPath) else {
            throw BookError.invalidData("Cannot read OPF: " + opfPath)
        }
        let ns = package.namespace

        // メタデータ
        var metadata = BookMetadata()
        let meta = package.element(ns, "metadata")
        if let meta {
            metadata.title = meta.elements(nsDc, "title").map { $0.value.trimmed }.first { !$0.isEmpty } ?? ""
            metadata.author = meta.elements(nsDc, "creator").map { $0.value.trimmed }.filter { !$0.isEmpty }.joined(separator: ", ")
            metadata.publisher = meta.element(nsDc, "publisher")?.value.trimmed ?? ""
            metadata.language = meta.element(nsDc, "language")?.value.trimmed ?? ""
            metadata.description = meta.element(nsDc, "description")?.value.trimmed ?? ""
            let uid = package.attr("unique-identifier")
            metadata.identifier = meta.elements(nsDc, "identifier").first { uid != nil && $0.attr("id") == uid }?.value.trimmed
                ?? meta.element(nsDc, "identifier")?.value.trimmed ?? ""
        }

        // 暗号化 (DRM / フォント難読化)
        let (obfuscated, hasDrm) = readEncryption(zip, entries)
        if hasDrm {
            throw BookError.drmProtected
        }

        // manifest
        struct ManifestItem { let path: String; let mediaType: String; let properties: String }
        var manifest: [String: ManifestItem] = [:]
        var manifestOrder: [ManifestItem] = []
        var coverPath: String?
        var navPath: String?
        for item in package.element(ns, "manifest")?.elements(ns, "item") ?? [] {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            let path = resolveHref(opfDir, href)
            let mediaType = item.attr("media-type") ?? PathUtil.mediaType(fromExtension: path)
            let properties = item.attr("properties") ?? ""
            let mi = ManifestItem(path: path, mediaType: mediaType, properties: properties)
            manifest[id] = mi
            manifestOrder.append(mi)
            let props = properties.split(separator: " ").map(String.init)
            if props.contains("cover-image") { coverPath = path }
            if props.contains("nav") { navPath = path }
        }
        if coverPath == nil, let meta {
            if let coverId = meta.elements(ns, "meta").first(where: { $0.attr("name") == "cover" })?.attr("content"),
               let cov = manifest[coverId] {
                coverPath = cov.path
            }
        }

        // spine
        let spineEl = package.element(ns, "spine")
        var spine: [SpineItem] = []
        for itemref in spineEl?.elements(ns, "itemref") ?? [] {
            guard let idref = itemref.attr("idref"), let m = manifest[idref] else { continue }
            let linear = !(itemref.attr("linear")?.equalsIgnoringCase("no") ?? false)
            spine.append(SpineItem(path: m.path, mediaType: m.mediaType, linear: linear))
        }
        if spine.isEmpty {
            // spine が壊れている場合は manifest 内の HTML を順に並べる
            for m in manifestOrder.filter({ PathUtil.isHtmlMediaType($0.mediaType) }).sorted(by: { $0.path < $1.path }) {
                spine.append(SpineItem(path: m.path, mediaType: m.mediaType))
            }
        }

        // 組方向: spine の page-progression-direction / primary-writing-mode メタ / CSS
        var writingMode = WritingMode.unknown
        if let ppd = spineEl?.attr("page-progression-direction") {
            if ppd.equalsIgnoringCase("rtl") { writingMode = .vertical }
            else if ppd.equalsIgnoringCase("ltr") { writingMode = .horizontal }
        }
        if let meta, let pwm = meta.elements(ns, "meta").first(where: { $0.attr("name") == "primary-writing-mode" })?.attr("content") {
            if pwm.hasPrefixIgnoringCase("vertical") { writingMode = .vertical }
            else if pwm.hasPrefixIgnoringCase("horizontal") { writingMode = .horizontal }
        }

        // リソース (遅延読み込み)
        var resources: [String: BookResource] = [:]
        var manifestByPath: [String: String] = [:]
        for m in manifestOrder { manifestByPath[m.path] = m.mediaType }
        let uid = metadata.identifier
        for (path, entry) in entries {
            let mediaType = manifestByPath[path] ?? PathUtil.mediaType(fromExtension: path)
            let algorithm = obfuscated[path]
            resources[path] = BookResource(path: path, mediaType: mediaType) {
                let data = try zip.read(entry)
                guard let algorithm else { return data }
                return Data(deobfuscate([UInt8](data), algorithm: algorithm, uniqueIdentifier: uid))
            }
        }

        if writingMode == .unknown {
            writingMode = detectWritingModeFromCss(resources)
        }

        // 目次: EPUB3 nav → NCX
        var toc: [TocEntry] = []
        if let navPath, let nav = loadXml(zip, entries, navPath) {
            parseNav(nav, navPath: navPath, into: &toc)
        }
        if toc.isEmpty {
            var ncxPath: String?
            if let ncxId = spineEl?.attr("toc"), let item = manifest[ncxId] { ncxPath = item.path }
            else { ncxPath = manifestOrder.first { $0.mediaType == "application/x-dtbncx+xml" }?.path }
            if let ncxPath, let ncx = loadXml(zip, entries, ncxPath) {
                parseNcx(ncx, ncxPath: ncxPath, into: &toc)
            }
        }

        return BookDocument(format: .epub, metadata: metadata, spine: spine, toc: toc, resources: resources,
                            declaredWritingMode: writingMode, coverPath: coverPath)
    }

    private static func findOpfPath(_ zip: ZipArchive, _ entries: [String: ZipArchive.Entry]) throws -> String {
        var path: String?
        if let container = loadXml(zip, entries, "META-INF/container.xml") {
            path = container.descendants(nsContainer, "rootfile").compactMap { $0.attr("full-path") }.first { !$0.isEmpty }
        }
        if path == nil {
            // container.xml が無い/壊れている場合は .opf を探す
            path = entries.keys.sorted().first { $0.lowercased().hasSuffix(".opf") }
        }
        guard let p = path else { throw BookError.invalidData("OPF file not found in EPUB.") }
        return PathUtil.normalize(p)
    }

    private static func resolveHref(_ opfDir: String, _ href: String) -> String {
        PathUtil.normalize(opfDir.isEmpty ? href : opfDir + "/" + href)
    }

    private static func loadXml(_ zip: ZipArchive, _ entries: [String: ZipArchive.Entry], _ path: String) -> XMLNode? {
        guard let entry = entries[PathUtil.normalize(path)] else { return nil }
        guard let data = try? zip.read(entry) else { return nil }
        return XMLDocumentLite.parse(data)
    }

    /// META-INF/encryption.xml を読み、難読化フォントの一覧と DRM の有無を返す。
    private static func readEncryption(_ zip: ZipArchive, _ entries: [String: ZipArchive.Entry]) -> ([String: String], Bool) {
        var result: [String: String] = [:]
        var hasDrm = false
        guard let enc = loadXml(zip, entries, "META-INF/encryption.xml") else { return (result, false) }
        for data in enc.descendants(nsEnc, "EncryptedData") {
            let algorithm = data.element(nsEnc, "EncryptionMethod")?.attr("Algorithm")
            guard let uri = data.descendants(nsEnc, "CipherReference").compactMap({ $0.attr("URI") }).first else { continue }
            let path = PathUtil.normalize(uri)
            if algorithm == idpfObfuscation || algorithm == adobeObfuscation {
                result[path] = algorithm
            } else {
                hasDrm = true
            }
        }
        return (result, hasDrm)
    }

    /// IDPF / Adobe 方式のフォント難読化を解除する。
    static func deobfuscate(_ data: [UInt8], algorithm: String, uniqueIdentifier: String) -> [UInt8] {
        let key: [UInt8]
        let length: Int
        if algorithm == idpfObfuscation {
            let id = String(uniqueIdentifier.trimmed.filter { !$0.isWhitespace })
            key = SHA1.hash(Array(id.utf8))
            length = 1040
        } else {
            var hex = uniqueIdentifier.trimmed
            if hex.hasPrefixIgnoringCase("urn:uuid:") { hex = String(hex.dropFirst(9)) }
            hex = hex.replacingOccurrences(of: "-", with: "")
            guard hex.count >= 32, let k = hexToBytes(String(hex.prefix(32))) else { return data }
            key = k
            length = 1024
        }
        guard !key.isEmpty else { return data }
        var result = data
        let n = min(length, result.count)
        for i in 0..<n { result[i] ^= key[i % key.count] }
        return result
    }

    private static func hexToBytes(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var chars = Array(s.utf8)
        if chars.count % 2 != 0 { chars.removeLast() }
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }

    private static func detectWritingModeFromCss(_ resources: [String: BookResource]) -> WritingMode {
        for r in resources.values.sorted(by: { $0.path < $1.path }) where r.mediaType == "text/css" {
            guard let data = try? r.getData() else { continue }
            let css = String(decoding: data, as: UTF8.self)
            var searchRange = css.startIndex..<css.endIndex
            while let idx = css.range(of: "writing-mode", options: .caseInsensitive, range: searchRange) {
                let end = css[idx.upperBound...].firstIndex { $0 == ";" || $0 == "}" } ?? css.endIndex
                let decl = css[idx.lowerBound..<end]
                if decl.range(of: "vertical", options: .caseInsensitive) != nil { return .vertical }
                searchRange = idx.upperBound..<css.endIndex
            }
        }
        return .unknown
    }

    private static func parseNav(_ nav: XMLNode, navPath: String, into toc: inout [TocEntry]) {
        let navs = nav.descendants(nsXhtml, "nav")
        let tocNav = navs.first { $0.attributes["epub:type"] == "toc" || $0.attr("type") == "toc" } ?? navs.first
        guard let ol = tocNav?.element(nsXhtml, "ol") else { return }
        parseNavList(ol, navPath: navPath, into: &toc)
    }

    private static func parseNavList(_ ol: XMLNode, navPath: String, into target: inout [TocEntry]) {
        for li in ol.elements(nsXhtml, "li") {
            let a = li.element(nsXhtml, "a") ?? li.element(nsXhtml, "span")
            let title = normalizeTitle(a?.value ?? li.firstDirectText ?? "")
            let (path, fragment) = splitHref(basePath: navPath, href: a?.attr("href"))
            let entry = TocEntry(title: title, path: path, fragment: fragment)
            if let child = li.element(nsXhtml, "ol") {
                parseNavList(child, navPath: navPath, into: &entry.children)
            }
            target.append(entry)
        }
    }

    private static func parseNcx(_ ncx: XMLNode, ncxPath: String, into toc: inout [TocEntry]) {
        guard let navMap = ncx.descendants(nsNcx, "navMap").first else { return }
        parseNavPoints(navMap, ncxPath: ncxPath, into: &toc)
    }

    private static func parseNavPoints(_ parent: XMLNode, ncxPath: String, into target: inout [TocEntry]) {
        for np in parent.elements(nsNcx, "navPoint") {
            let title = normalizeTitle(np.element(nsNcx, "navLabel")?.element(nsNcx, "text")?.value ?? "")
            let src = np.element(nsNcx, "content")?.attr("src")
            let (path, fragment) = splitHref(basePath: ncxPath, href: src)
            let entry = TocEntry(title: title, path: path, fragment: fragment)
            parseNavPoints(np, ncxPath: ncxPath, into: &entry.children)
            target.append(entry)
        }
    }

    static func splitHref(basePath: String, href: String?) -> (String?, String?) {
        guard var href = href?.trimmed, !href.isEmpty else { return (nil, nil) }
        var fragment: String?
        if let hash = href.firstIndex(of: "#") {
            let f = String(href[href.index(after: hash)...])
            fragment = f.removingPercentEncoding ?? f
            href = String(href[..<hash])
        }
        let path = href.isEmpty ? PathUtil.normalize(basePath) : PathUtil.resolve(basePath: basePath, href: href)
        return (path, (fragment?.isEmpty ?? true) ? nil : fragment)
    }

    static func normalizeTitle(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
