import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// XMLParser で組み立てる軽量 DOM。iOS には XMLDocument が無いので自前で持つ (C# の XDocument の代替)。
final class XMLNode {
    let name: String
    let namespace: String
    let attributes: [String: String]
    private(set) var children: [XMLNode] = []
    /// 直接の子テキストノード (要素の間のテキストを順に保持)。
    private(set) var textParts: [(index: Int, text: String)] = []
    weak var parent: XMLNode?

    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    fileprivate func append(_ child: XMLNode) {
        child.parent = self
        children.append(child)
    }

    fileprivate func appendText(_ s: String) {
        if let last = textParts.last, last.index == children.count {
            textParts[textParts.count - 1].text += s
        } else {
            textParts.append((children.count, s))
        }
    }

    /// 属性 (名前空間接頭辞は無視して局所名で探す)。
    func attr(_ localName: String) -> String? {
        if let v = attributes[localName] { return v }
        for (k, v) in attributes {
            if let colon = k.lastIndex(of: ":"), k[k.index(after: colon)...] == localName { return v }
        }
        return nil
    }

    /// 要素直下のテキストと子孫のテキストを連結したもの (XElement.Value 相当)。
    var value: String {
        var s = ""
        var ti = 0
        for (i, c) in children.enumerated() {
            while ti < textParts.count, textParts[ti].index <= i { s += textParts[ti].text; ti += 1 }
            s += c.value
        }
        while ti < textParts.count { s += textParts[ti].text; ti += 1 }
        return s
    }

    /// 最初の直接テキスト (子要素より前)。
    var firstDirectText: String? {
        textParts.first?.text
    }

    func element(_ ns: String, _ name: String) -> XMLNode? {
        children.first { $0.name == name && $0.namespace == ns }
    }

    func elements(_ ns: String, _ name: String) -> [XMLNode] {
        children.filter { $0.name == name && $0.namespace == ns }
    }

    func descendants(_ ns: String?, _ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        func walk(_ n: XMLNode) {
            for c in n.children {
                if c.name == name && (ns == nil || c.namespace == ns!) { out.append(c) }
                walk(c)
            }
        }
        walk(self)
        return out
    }
}

/// XMLParser を使った DOM 構築。整形式でなければ nil。
final class XMLDocumentLite: NSObject, XMLParserDelegate {
    private(set) var root: XMLNode?
    private var stack: [XMLNode] = []
    private var failed = false

    static func parse(_ data: Data) -> XMLNode? {
        let d = XMLDocumentLite()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        #if canImport(Darwin)
        // DOCTYPE の外部 DTD (w3.org / daisy.org) を取りに行かない
        parser.externalEntityResolvingPolicy = .never
        #endif
        let ok = parser.parse()
        return ok && !d.failed ? d.root : nil
    }

    /// 整形式かどうかだけを調べる (DTD は読まない)。
    static func isWellFormed(_ data: Data) -> Bool {
        let d = XMLDocumentLite()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        #if canImport(Darwin)
        parser.externalEntityResolvingPolicy = .never
        #endif
        return parser.parse() && !d.failed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = XMLNode(name: elementName, namespace: namespaceURI ?? "", attributes: attributes)
        if let top = stack.last { top.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.appendText(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}
