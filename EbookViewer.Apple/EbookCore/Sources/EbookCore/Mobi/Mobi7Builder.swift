import Foundation

/// 旧形式 MOBI (KF7) から BookDocument を組み立てる。本文は 1 つの HTML になる。
public final class Mobi7Builder {
    static let textPath = "Text/book.html"

    private let db: PalmDatabase
    private let header: MobiHeader
    private let headerRecord: Int
    private let resourceBase: Int
    private let resourceEnd: Int

    private static let fileposRegex = Rx(#"filepos\s*=\s*["']?(\d+)"#, .caseInsensitive)
    private static let fileposAttrRegex = Rx(#"\sfilepos\s*=\s*["']?(\d+)["']?"#, .caseInsensitive)
    private static let fileposPlaceholderRegex = Rx(#"\sfilepos\s*=\s*["']?X+["']?"#, .caseInsensitive)
    private static let recindexRegex = Rx(#"\s(?:hi|lo)?recindex\s*=\s*(["']?)(\d+)\1"#, .caseInsensitive)
    private static let pageBreakRegex = Rx(#"<mbp:pagebreak\s*/?>(?:\s*</mbp:pagebreak>)?"#, .caseInsensitive)
    private static let mbpTagRegex = Rx(#"</?mbp:[a-zA-Z]+[^>]*>"#, .caseInsensitive)
    private static let guideRegex = Rx(#"<guide>.*?</guide>"#, [.caseInsensitive, .dotMatchesLineSeparators])
    private static let referenceRegex = Rx(#"<reference[^>]*title\s*=\s*["']([^"']*)["'][^>]*href\s*=\s*["']([^"']*)["'][^>]*>"#, .caseInsensitive)

    public init(db: PalmDatabase, header: MobiHeader, headerRecord: Int, resourceBase: Int, resourceEnd: Int) {
        self.db = db
        self.header = header
        self.headerRecord = headerRecord
        self.resourceBase = resourceBase
        self.resourceEnd = resourceEnd
    }

    public func build() throws -> BookDocument {
        let raw = try MobiText.readRawText(db, header: header, headerRecord: headerRecord)
        let (resourceMap, _) = MobiResources.collect(db, firstResource: resourceBase, end: resourceEnd)

        // NCX (あれば) の filepos を集める
        var ncxEntries: [(title: String, pos: Int64, parent: Int)] = []
        if header.ncxIndex != MobiHeader.nullIndex && header.headerLength >= 0xE4 {
            let ncx = MobiIndex.read(db, indexRecord: headerRecord + Int(header.ncxIndex))
            for e in ncx.entries {
                let labelIdx = e.tag(3) ?? -1
                let title = labelIdx >= 0 && ncx.cncx[labelIdx] != nil ? String(decoding: ncx.cncx[labelIdx]!, as: UTF8.self) : e.labelText
                let pos = e.tag(1) ?? -1
                let parent = Int(e.tag(21) ?? -1)
                ncxEntries.append((title.trimmed, pos, parent))
            }
        }

        // filepos 参照位置にアンカーを挿入する
        var positions = Set<Int64>()
        for m in Self.fileposRegex.matches(in: TextEncoding.latin1.decode(raw)) {
            if let p = Int64(m.group(1)) { positions.insert(p) }
        }
        for e in ncxEntries where e.pos >= 0 { positions.insert(e.pos) }

        let enc = header.textEncodingObject
        var html = ""
        var cursor = 0
        for p in positions.sorted() {
            var pos = Int(min(p, Int64(raw.count)))
            pos = Self.adjustAnchorPosition(raw, pos)
            if pos < cursor { continue }
            html += enc.decode(raw.slice(cursor, pos - cursor))
            html += "<a id=\"filepos\(p)\"></a>"
            cursor = pos
        }
        html += enc.decode(raw.slice(cursor, raw.count - cursor))

        // filepos=NNN → href="#fileposNNN"。kindlegen が未解決リンクに残す filepos=XXXXXXXXXX は除去する
        html = Self.fileposAttrRegex.replace(html) { " href=\"#filepos" + $0.group(1) + "\"" }
        html = Self.fileposPlaceholderRegex.replace(html, with: "")

        // <img recindex="00003"> → 画像パス
        var resources: [String: BookResource] = [:]
        for r in resourceMap.values {
            resources[r.path] = BookResource(path: r.path, mediaType: r.mediaType, data: Data(r.data))
        }
        html = Self.recindexRegex.replace(html) { m in
            if let n = Int(m.group(2)), let res = resourceMap[n] {
                return " src=\"" + PathUtil.makeRelative(from: Self.textPath, to: res.path) + "\""
            }
            return m.value
        }

        // <guide> の参照は目次の代替として使うので、削除する前に拾っておく
        let guideToc = Self.extractTocFromGuide(html)

        // mbp:pagebreak → 改ページ、その他の mbp: タグは除去
        html = Self.pageBreakRegex.replace(html, with: "<div class=\"__ev-pagebreak\"></div>")
        html = Self.mbpTagRegex.replace(html, with: "")
        html = Self.guideRegex.replace(html, with: "")

        if !html.containsIgnoringCase("<html") {
            html = "<html><head><meta charset=\"utf-8\"/></head><body>" + html + "</body></html>"
        }
        if !html.containsIgnoringCase("charset") {
            html = html.replacingOccurrences(of: "<head>", with: "<head><meta charset=\"utf-8\"/>", options: .caseInsensitive)
        }

        resources[Self.textPath] = BookResource(path: Self.textPath, mediaType: "text/html", data: Data(html.utf8))
        let spine = [SpineItem(path: Self.textPath, mediaType: "text/html")]

        var metadata = BookMetadata()
        metadata.title = header.exthString(503) ?? header.fullName
        metadata.author = header.exthStrings(100).joined(separator: ", ")
        metadata.publisher = header.exthString(101) ?? ""
        metadata.language = header.exthString(524) ?? ""
        metadata.description = header.exthString(103) ?? ""
        metadata.identifier = header.exthString(104) ?? header.exthString(113) ?? ""
        if metadata.title.trimmed.isEmpty { metadata.title = db.name }

        var writingMode = WritingMode.unknown
        if let pwm = header.exthString(525), pwm.hasPrefixIgnoringCase("vertical") { writingMode = .vertical }
        else if header.exthString(527)?.equalsIgnoringCase("rtl") == true { writingMode = .vertical }

        var coverPath: String?
        if let coverOffset = header.exthUInt32(201), let cover = resourceMap[Int(coverOffset) + 1] { coverPath = cover.path }

        // 目次
        var toc: [TocEntry] = []
        var nodes: [(entry: TocEntry, parent: Int)] = []
        for e in ncxEntries {
            nodes.append((TocEntry(title: e.title, path: Self.textPath, fragment: e.pos >= 0 ? "filepos\(e.pos)" : nil), e.parent))
        }
        for (i, node) in nodes.enumerated() {
            if node.parent >= 0 && node.parent < nodes.count && node.parent != i {
                nodes[node.parent].entry.children.append(node.entry)
            } else {
                toc.append(node.entry)
            }
        }
        if toc.isEmpty { toc.append(contentsOf: guideToc) }

        return BookDocument(format: .mobi7, metadata: metadata, spine: spine, toc: toc, resources: resources,
                            declaredWritingMode: writingMode, coverPath: coverPath)
    }

    /// タグの途中やマルチバイト文字の途中にアンカーを入れないよう位置を調整する。
    private static func adjustAnchorPosition(_ raw: [UInt8], _ posIn: Int) -> Int {
        var pos = posIn
        if pos >= raw.count { return raw.count }
        if raw[pos] == 0x3C { return pos } // '<'
        // 直前 256 バイト以内で '<' があり、その後に '>' が無ければタグの途中 → タグ先頭へ
        var i = pos - 1
        while i >= 0 && i >= pos - 256 {
            if raw[i] == 0x3E { break } // '>'
            if raw[i] == 0x3C { return i }
            i -= 1
        }
        // UTF-8 継続バイトの途中なら文字の先頭へ
        while pos > 0 && (raw[pos] & 0xC0) == 0x80 { pos -= 1 }
        return pos
    }

    private static func extractTocFromGuide(_ html: String) -> [TocEntry] {
        // <reference type="toc" title="目次" filepos=...> は href に変換済みなので拾う
        referenceRegex.matches(in: html).map { m in
            var href = m.group(2)
            while href.hasPrefix("#") { href.removeFirst() }
            return TocEntry(title: m.group(1), path: textPath, fragment: href)
        }
    }
}
