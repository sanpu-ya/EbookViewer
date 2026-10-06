import Foundation

/// KF8 (AZW3 / ハイブリッド mobi の KF8 部) から BookDocument を組み立てる。KindleUnpack の mobi_k8proc.py 相当。
final class Kf8Builder {
    private struct Part {
        let fileNumber: Int
        let fileName: String
        let start: Int
        let end: Int
        let html: String
    }

    private struct Fragment {
        let insertPos: Int64
        let idText: String
        let fileNumber: Int
        let seq: Int
        let start: Int64
        let length: Int64
    }

    private let db: PalmDatabase
    private let header: MobiHeader
    private let headerRecord: Int
    private let rawText: [UInt8]
    private var flows: [(start: Int, end: Int)] = []
    private var parts: [Part] = []
    private var fragments: [Fragment] = []
    private let resources: [Int: MobiResources.Resource]
    private let resc: String?

    private static let posFidRegex = Rx(#"(<[^>]*?\s(?:href|src)\s*=\s*)(["'])kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)\2"#, .caseInsensitive)
    private static let embedRegex = Rx(#"kindle:embed:([0-9A-V]+)(?:\?mime=[^"'\)\s>]*)?"#, .caseInsensitive)
    private static let flowRegex = Rx(#"kindle:flow:([0-9A-V]+)(?:\?mime=[^"'\)\s>]*)?"#, .caseInsensitive)
    private static let idAttrRegex = Rx(#"\sid\s*=\s*["']([^"']+)["']"#, .caseInsensitive)
    private static let aidAttrRegex = Rx(#"\said\s*=\s*["']([^"']+)["']"#, .caseInsensitive)
    private static let tagWithAidRegex = Rx(#"<[a-zA-Z][^>]*?\said\s*=\s*["']([^"']+)["'][^>]*>"#, .caseInsensitive)

    init(db: PalmDatabase, header: MobiHeader, headerRecord: Int, resourceBase: Int, resourceEnd: Int) throws {
        self.db = db
        self.header = header
        self.headerRecord = headerRecord
        rawText = try MobiText.readRawText(db, header: header, headerRecord: headerRecord)
        let collected = MobiResources.collect(db, firstResource: resourceBase, end: resourceEnd)
        resources = collected.resources
        resc = collected.rescXml
    }

    func build() -> BookDocument {
        readFlows()
        readFragmentsAndSkeletons()

        var result: [String: BookResource] = [:]
        for r in resources.values {
            result[r.path] = BookResource(path: r.path, mediaType: r.mediaType, data: Data(r.data))
        }

        // フロー 1 以降: CSS / SVG など。kindle:embed / kindle:flow 参照を書き換える
        var flowPaths: [Int: String] = [:]
        if flows.count > 1 {
            for i in 1..<flows.count {
                let (s, e) = flows[i]
                let text = String(decoding: rawText.slice(s, e - s), as: UTF8.self)
                let trimmed = String(text.drop { $0.isWhitespace || $0.isNewline }.prefix(16))
                let isSvg = trimmed.hasPrefixIgnoringCase("<?xml") || trimmed.hasPrefixIgnoringCase("<svg")
                flowPaths[i] = isSvg ? String(format: "Images/flow%04d.svg", i) : String(format: "Styles/flow%04d.css", i)
            }
            for i in 1..<flows.count {
                let (s, e) = flows[i]
                var text = String(decoding: rawText.slice(s, e - s), as: UTF8.self)
                let path = flowPaths[i]!
                text = rewriteKindleUrls(text, ownPath: path, flowPaths: flowPaths)
                result[path] = BookResource(path: path, mediaType: PathUtil.mediaType(fromExtension: path), data: Data(text.utf8))
            }
        }

        // 本文パート
        var spine: [SpineItem] = []
        for part in parts {
            let path = "Text/" + part.fileName
            var html = rewriteKindleUrls(part.html, ownPath: path, flowPaths: flowPaths)
            html = Self.convertAidToId(html)
            result[path] = BookResource(path: path, mediaType: "application/xhtml+xml", data: Data(html.utf8))
            spine.append(SpineItem(path: path, mediaType: "application/xhtml+xml"))
        }

        var metadata = BookMetadata()
        metadata.title = header.exthString(503) ?? header.fullName
        metadata.author = header.exthStrings(100).joined(separator: ", ")
        metadata.publisher = header.exthString(101) ?? ""
        metadata.language = header.exthString(524) ?? ""
        metadata.description = header.exthString(103) ?? ""
        metadata.identifier = header.exthString(104) ?? header.exthString(113) ?? ""
        if metadata.title.trimmed.isEmpty { metadata.title = db.name }

        var writingMode = WritingMode.unknown
        if let pwm = header.exthString(525) {
            if pwm.hasPrefixIgnoringCase("vertical") { writingMode = .vertical }
            else if pwm.hasPrefixIgnoringCase("horizontal") { writingMode = .horizontal }
        }
        if writingMode == .unknown, header.exthString(527)?.equalsIgnoringCase("rtl") == true {
            writingMode = .vertical
        }
        if writingMode == .unknown, let resc {
            if resc.containsIgnoringCase("vertical-rl") || resc.containsIgnoringCase("page-progression-direction=\"rtl\"") {
                writingMode = .vertical
            }
        }

        var coverPath: String?
        if let coverOffset = header.exthUInt32(201), let cover = resources[Int(coverOffset) + 1] { coverPath = cover.path }

        let toc = buildToc()

        return BookDocument(format: .kf8, metadata: metadata, spine: spine, toc: toc, resources: result,
                            declaredWritingMode: writingMode, coverPath: coverPath)
    }

    private func readFlows() {
        flows.removeAll()
        if header.fdstIndex != MobiHeader.nullIndex && header.fdstIndex != 0 {
            let fdst = db.record(headerRecord + Int(header.fdstIndex))
            if fdst.count >= 12 && fdst.startsWith("FDST") {
                let count = Int(fdst.u32BE(8))
                var i = 0
                while i < count && 12 + i * 8 + 8 <= fdst.count {
                    var s = Int(fdst.u32BE(12 + i * 8))
                    var e = Int(fdst.u32BE(16 + i * 8))
                    s = max(0, min(s, rawText.count))
                    e = max(s, min(e, rawText.count))
                    flows.append((s, e))
                    i += 1
                }
            }
        }
        if flows.isEmpty { flows.append((0, rawText.count)) }
    }

    private func readFragmentsAndSkeletons() {
        fragments.removeAll()
        if header.fragmentIndex != MobiHeader.nullIndex {
            let frag = MobiIndex.read(db, indexRecord: headerRecord + Int(header.fragmentIndex))
            for e in frag.entries {
                let insertPos = Int64(e.labelText) ?? 0
                let cncxIdx = e.tag(2) ?? -1
                let idText = cncxIdx >= 0 && frag.cncx[cncxIdx] != nil ? String(decoding: frag.cncx[cncxIdx]!, as: UTF8.self) : ""
                let fileNumber = Int(e.tag(3) ?? 0)
                let seq = Int(e.tag(4) ?? 0)
                let start = e.tag(6, 0) ?? 0
                let length = e.tag(6, 1) ?? 0
                fragments.append(Fragment(insertPos: insertPos, idText: idText, fileNumber: fileNumber, seq: seq, start: start, length: length))
            }
        }

        var skeletons: [(number: Int, name: String, fragCount: Int, pos: Int64, length: Int64)] = []
        if header.skeletonIndex != MobiHeader.nullIndex {
            let skel = MobiIndex.read(db, indexRecord: headerRecord + Int(header.skeletonIndex))
            for (i, e) in skel.entries.enumerated() {
                skeletons.append((i, e.labelText, Int(e.tag(1) ?? 0), e.tag(6, 0) ?? 0, e.tag(6, 1) ?? 0))
            }
        }

        parts.removeAll()
        let (flowStart, flowEnd) = flows[0]
        if skeletons.isEmpty {
            // スケルトン情報が無い場合は本文フロー全体を 1 ファイルとして扱う
            let html = String(decoding: rawText.slice(flowStart, flowEnd - flowStart), as: UTF8.self)
            parts.append(Part(fileNumber: 0, fileName: "part0000.xhtml", start: flowStart, end: flowEnd, html: html))
            return
        }

        var fragPtr = 0
        for sk in skeletons {
            var basePtr = sk.pos + sk.length
            if sk.pos < 0 || basePtr > Int64(rawText.count) { continue }
            var skeleton = rawText.slice(Int(sk.pos), Int(sk.length))
            var fileName = String(format: "part%04d.xhtml", sk.number)
            var i = 0
            while i < sk.fragCount && fragPtr < fragments.count {
                let f = fragments[fragPtr]
                if i == 0 { fileName = String(format: "part%04d.xhtml", f.fileNumber) }
                var length = f.length
                if basePtr + length > Int64(rawText.count) { length = Int64(rawText.count) - basePtr }
                let slice = rawText.slice(Int(basePtr), Int(max(0, length)))
                let ip = Int(max(0, min(f.insertPos - sk.pos, Int64(skeleton.count))))
                skeleton.insert(contentsOf: slice, at: ip)
                basePtr += length
                i += 1
                fragPtr += 1
            }
            let html = String(decoding: skeleton, as: UTF8.self)
            parts.append(Part(fileNumber: sk.number, fileName: fileName, start: Int(sk.pos), end: Int(basePtr), html: html))
        }
        if parts.isEmpty {
            let html = String(decoding: rawText.slice(flowStart, flowEnd - flowStart), as: UTF8.self)
            parts.append(Part(fileNumber: 0, fileName: "part0000.xhtml", start: flowStart, end: flowEnd, html: html))
        }
    }

    /// kindle:pos:fid:XXXX:off:YYYY を "partNNNN.xhtml#id" に解決する。
    private func resolvePosFid(_ fidBase32: String, _ offBase32: String) -> (fileName: String, id: String)? {
        let row = MobiResources.fromBase32(fidBase32)
        let off = MobiResources.fromBase32(offBase32)
        guard row >= 0, row < Int64(fragments.count), off >= 0 else { return nil }
        return resolvePosition(fragments[Int(row)].insertPos + off)
    }

    /// 本文フロー内の絶対位置から、含まれるパートとその直前の id / aid を求める。
    private func resolvePosition(_ pos: Int64) -> (fileName: String, id: String)? {
        for part in parts {
            if pos < Int64(part.start) || pos >= Int64(part.end) { continue }
            // 位置はパート内の生バイト位置だが、フラグメント挿入後の文字列とは一致しないため生テキストから直接 id を探す
            var npos = Int(pos)
            let pgt = rawText[npos...].firstIndex(of: 0x3E) ?? -1 // '>'
            let plt = rawText[npos...].firstIndex(of: 0x3C) ?? -1 // '<'
            if plt == npos || (pgt >= 0 && (plt < 0 || pgt < plt)) { npos = pgt + 1 }
            if npos < part.start { npos = part.start }
            let textBefore = String(decoding: rawText.slice(part.start, max(0, min(npos, part.end) - part.start)), as: UTF8.self)
            return (part.fileName, Self.findLastId(textBefore))
        }
        return nil
    }

    private static func findLastId(_ textBefore: String) -> String {
        var s = Substring(textBefore)
        while let lt = s.lastIndex(of: "<") {
            let after = s[lt...]
            let tag: Substring
            if let gt = after.firstIndex(of: ">") { tag = after[...gt] } else { tag = after }
            let t = String(tag)
            if let m = idAttrRegex.firstMatch(in: t) { return m.group(1) }
            if let m = aidAttrRegex.firstMatch(in: t) { return "aid_" + m.group(1) }
            s = s[..<lt]
        }
        return ""
    }

    private func rewriteKindleUrls(_ input: String, ownPath: String, flowPaths: [Int: String]) -> String {
        var text = Self.posFidRegex.replace(input) { m in
            guard let target = resolvePosFid(m.group(3), m.group(4)) else {
                return m.group(1) + m.group(2) + "#" + m.group(2)
            }
            var href = target.fileName
            if !target.id.isEmpty { href += "#" + target.id }
            return m.group(1) + m.group(2) + href + m.group(2)
        }
        text = Self.embedRegex.replace(text) { m in
            let n = MobiResources.fromBase32(m.group(1))
            if n > 0, let res = resources[Int(n)] {
                return PathUtil.makeRelative(from: ownPath, to: res.path)
            }
            return m.value
        }
        text = Self.flowRegex.replace(text) { m in
            let n = MobiResources.fromBase32(m.group(1))
            if n > 0, let path = flowPaths[Int(n)] {
                return PathUtil.makeRelative(from: ownPath, to: path)
            }
            return m.value
        }
        return text
    }

    /// aid 属性を持ち id を持たない要素に id="aid_XXX" を付ける (リンク先として使うため)。
    private static func convertAidToId(_ html: String) -> String {
        tagWithAidRegex.replace(html) { m in
            let tag = m.value
            if idAttrRegex.isMatch(tag) { return tag }
            let aid = m.group(1)
            guard let insert = tag.range(of: " aid=") ?? tag.range(of: "\taid=") else { return tag }
            return String(tag[..<insert.lowerBound]) + " id=\"aid_" + aid + "\"" + String(tag[insert.lowerBound...])
        }
    }

    private func buildToc() -> [TocEntry] {
        var toc: [TocEntry] = []
        guard header.ncxIndex != MobiHeader.nullIndex else { return toc }
        let ncx = MobiIndex.read(db, indexRecord: headerRecord + Int(header.ncxIndex))
        var nodes: [(entry: TocEntry, parent: Int)] = []
        for e in ncx.entries {
            let labelIdx = e.tag(3) ?? -1
            let title = labelIdx >= 0 && ncx.cncx[labelIdx] != nil ? String(decoding: ncx.cncx[labelIdx]!, as: UTF8.self) : e.labelText
            var path: String?
            var fragment: String?
            if let posFid = e.tags[6], posFid.count >= 2 {
                let pos: Int64 = posFid[0] >= 0 && posFid[0] < Int64(fragments.count) ? fragments[Int(posFid[0])].insertPos + posFid[1] : -1
                if pos >= 0, let target = resolvePosition(pos) {
                    path = "Text/" + target.fileName
                    fragment = target.id.isEmpty ? nil : target.id
                }
            } else if let filepos = e.tag(1), let target = resolvePosition(filepos) {
                path = "Text/" + target.fileName
                fragment = target.id.isEmpty ? nil : target.id
            }
            let parent = Int(e.tag(21) ?? -1)
            nodes.append((TocEntry(title: title.trimmed, path: path, fragment: fragment), parent))
        }
        for (i, node) in nodes.enumerated() {
            if node.parent >= 0 && node.parent < nodes.count && node.parent != i {
                nodes[node.parent].entry.children.append(node.entry)
            } else {
                toc.append(node.entry)
            }
        }
        return toc
    }
}
