/*
STFontManager.swift

Author: Makoto Kinoshita (mkino@hmdt.jp)

Copyright 2024 Nihon Design Center. All rights reserved.
This software is licensed under the MIT License. See LICENSE for details.
*/

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

open class STFontManager {
    public static let fontNamesNeedToFlip = [
        "AppleColorEmoji", 
    ]
    
    // Font name
    private let defaultFontName = "HelveticaNeue"
    private var scriptFontNames: [STScript: [String]] = [
        .latin: ["HelveticaNeue"], 
        .japanese: ["HiraginoSans-W3"],
        .emoji: ["AppleColorEmoji", "ArialUnicodeMS", "MS-Gothic", "Menlo-Regular"],  
    ]
    private var possibleFontNames = [String]()
    private var possibleScripts = [STScript]()
    /// システムに探してもらった書体の font ID (EbookViewer)。refresh のたびに捨てる。
    private var fallbackFontIds = [Character: Int]()
    
    // Font scale
    private var scriptFontScales: [STScript: CGFloat] = [
        .latin: 0.95, 
        .japanese: 1.0, 
        .emoji: 1.0, 
    ]
    
    // CT fonts cache
    static private var fontIdCtFonts = [Int: CTFont]()
    
    // Styled fonts cache (EbookViewer)
    fileprivate struct StyledFontKey: Hashable {
        let name: String
        let size: CGFloat
        let transform: CGAffineTransform
        let style: STTextStyle
    }
    fileprivate var styledFonts = [StyledFontKey: CTFont]()
}

extension STFontManager {
    //--------------------------------------------------------------//
    // MARK: - Font
    //--------------------------------------------------------------//
    
    func fontId(char: Character) -> Int {
        // Get script
        let script = char.unicodeScalars.first?.script

        // Decide font ID
        if let script, let index = fontId(char: char, script: script) { return index }

        // その文字種のフォントに無ければ、ほかの文字種のフォントも試す (EbookViewer)。
        // 記号のように、ひとつの書体では足りない文字があるため
        for other in STScript.allCases where other != script {
            if let index = fontId(char: char, script: other) { return index }
        }

        // それでも無ければ、システムに書体を探してもらう (EbookViewer)
        if let index = fallbackFontId(char: char, script: script) { return index }

        // Use default font ID
        return 0
    }

    /// その文字種のフォントのうち、この文字を描けるものの font ID (EbookViewer)。
    private func fontId(char: Character, script: STScript) -> Int? {
        for fontName in scriptFontNames[script] ?? [] {
            guard Self.hasGlyph(char: char, fontName: fontName) else { continue }
            if let index = fontId(name: fontName, script: script) { return index }
        }
        return nil
    }

    /// 名前と文字種の両方が合う font ID (EbookViewer)。
    ///
    /// upstream は名前だけで引いていたが、同じフォントを 2 つの文字種に使う
    /// (和欧で書体をそろえる) と、日本語の文字がラテン文字の font ID になってしまう。
    /// すると縦書きでラテン文字あつかいになり、字が横に倒れてしまう。
    private func fontId(name: String, script: STScript) -> Int? {
        possibleFontNames.indices.first { possibleFontNames[$0] == name && possibleScripts[$0] == script }
    }

    /// 名前で引いたフォントが、この文字のグリフを持っているか (EbookViewer)。
    ///
    /// `CTFontCreateWithName` は名前が見つからないと黙って別のフォントを返すので、
    /// 入っていない書体を「あった」と思い込まないよう、書体そのものも確かめる。
    /// そうしないと、取れたグリフ番号が別の書体のものになり、描くと違う字が出る。
    static func hasGlyph(char: Character, fontName: String) -> Bool {
        let ctFont = CTFontCreateWithName(fontName as CFString, 17, nil)
        guard isSameFont(ctFont, named: fontName) else { return false }
        // その書体がほんとうに持っている文字か。絵文字の書体は、持っていない文字にも
        // 同じ 1 つのグリフ (豆腐) を返すことがあるので、グリフ番号だけでは足りない
        let covered = CTFontCopyCharacterSet(ctFont) as CharacterSet
        guard char.unicodeScalars.allSatisfy({ covered.contains($0) }) else { return false }
        let chars = uniChars(char: char)
        guard !chars.isEmpty else { return false }
        // サロゲートペアは 2 つの UTF-16 から 1 つのグリフになり、戻り値は false になるので、
        // 戻り値ではなく先頭のグリフを見る (upstream は 1 つぶんの領域に chars.count 個
        // 書き込ませていた)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(ctFont, chars, &glyphs, chars.count)
        return glyphs[0] > 0
    }

    /// 作られたフォントが、頼んだ書体そのものか (PostScript 名かファミリー名が合うか)。
    private static func isSameFont(_ font: CTFont, named fontName: String) -> Bool {
        let wanted = fontName.lowercased()
        if (CTFontCopyPostScriptName(font) as String).lowercased() == wanted { return true }
        if (CTFontCopyFamilyName(font) as String).lowercased() == wanted { return true }
        return false
    }

    /// どの書体にも無い文字を、システムに探してもらう (EbookViewer)。
    /// 見つかった書体は font ID の一覧に足して、以降は同じ ID で引けるようにする。
    private func fallbackFontId(char: Character, script: STScript?) -> Int? {
        if let cached = fallbackFontIds[char] { return cached }
        let text = String(char) as CFString
        let base = CTFontCreateWithName(defaultFontName as CFString, 17, nil)
        let found = CTFontCreateForString(base, text, CFRange(location: 0, length: CFStringGetLength(text)))
        let name = CTFontCopyPostScriptName(found) as String
        guard Self.hasGlyph(char: char, fontName: name) else { return nil }
        // 文字種が分からない記号は、縦書きで倒さずに正立させたいので日本語として扱う
        let script = script ?? .japanese
        let index: Int
        if let existing = fontId(name: name, script: script) {
            index = existing
        } else {
            possibleFontNames.append(name)
            possibleScripts.append(script)
            index = possibleFontNames.count - 1
        }
        fallbackFontIds[char] = index
        return index
    }
    
    func ctFont(fontId: Int, size: CGFloat, isClockwise: Bool = false, style: STTextStyle = []) -> CTFont {
        // Get font name and script
        let fontName = possibleFontNames[fontId]
        let script = possibleScripts[fontId]
        
        // Decide font size
        let fontScale = scriptFontScales[script]!
        let size = size * fontScale
        
        // Decide transform
        var transform: CGAffineTransform = .identity
        transform = transform.scaledBy(x: 1, y: -1)
        if isClockwise {
            transform = transform.rotated(by: .pi * -0.5)
        }
        
        // Create font
        let font = CTFontCreateWithName(fontName as CFString, size, &transform)
        
        // For plain
        guard !style.isEmpty else { return font }
        
        // Get styled font (EbookViewer)
        return styledFont(font, name: fontName, size: size, transform: transform, style: style)
    }
    
    /// 太字・斜体にしたフォント (EbookViewer の追加)。
    /// 日本語フォントのように対応する字面が無ければ、元のフォントをそのまま返す。
    /// 1 文字ごとに作ると重いので覚えておく。
    private func styledFont(_ font: CTFont, name: String, size: CGFloat, transform: CGAffineTransform, style: STTextStyle) -> CTFont {
        let key = StyledFontKey(name: name, size: size, transform: transform, style: style)
        if let cached = styledFonts[key] { return cached }
        
        var traits: CTFontSymbolicTraits = []
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        var transform = transform
        let styled = CTFontCreateCopyWithSymbolicTraits(font, size, &transform, traits, traits) ?? font
        styledFonts[key] = styled
        
        return styled
    }
    
    func ascent(fontId: Int, size: CGFloat) -> CGFloat {
        // Get descent
        return CTFontGetAscent(ctFont(fontId: fontId, size: size))
    }
    
    func descent(fontId: Int, size: CGFloat) -> CGFloat {
        // Get descent
        return CTFontGetDescent(ctFont(fontId: fontId, size: size))
    }
    
    //--------------------------------------------------------------//
    // MARK: - Font name
    //--------------------------------------------------------------//
    
    func fontNames(script: STScript) -> [String] {
        // Get font names
        return scriptFontNames[script]!
    }
    
    func setFontNames(_ fontNames: [String], script: STScript) {
        // Set font name
        scriptFontNames[script] = fontNames
    }
    
    func fontName(fontId: Int) -> String {
        // Get font name
        return possibleFontNames[fontId]
    }
    
    //--------------------------------------------------------------//
    // MARK: - Font scale
    //--------------------------------------------------------------//
    
    func fontScale(script: STScript) -> CGFloat {
        // Get font scale
        return scriptFontScales[script]!
    }
    
    func setFontScale(_ fontScale: CGFloat, script: STScript) {
        // Set font scale
        scriptFontScales[script] = fontScale
    }
    
    func fontScale(fontId: Int) -> CGFloat {
        // Get font scale with script
        return fontScale(script: script(fontId: fontId))
    }
    
    //--------------------------------------------------------------//
    // MARK: - Script
    //--------------------------------------------------------------//
    
    func script(fontId: Int) -> STScript {
        // Get script
        return possibleScripts[fontId]
    }
    
    //--------------------------------------------------------------//
    // MARK: - Drawing properties
    //--------------------------------------------------------------//
    
    func needsToFlip(fontId: Int) -> Bool {
        // Get font name
        let fontName = fontName(fontId: fontId)
        
        // Check needs to flip
        return Self.fontNamesNeedToFlip.contains(fontName)
    }
    
    //--------------------------------------------------------------//
    // MARK: - Ellipsis
    //--------------------------------------------------------------//
    
    static let horizontalEllipsis = "…" // HORIZONTAL ELLIPSIS, U+2026
    static let middleHorizontalEllipsis = "⋯" // MIDDLE HORIZONTAL ELLIPSIS, U+22ef
    static let verticalEllipsis = "⋮" // VERTICAL ELLIPSIS, U+22ee
    static let presentationVerticalEllipsis = "︙" // PRESENTATION FORM FOR VERTICAL HORIZONTAL ELLIPSIS, U+fe19
    
    func ellipsisGlyph(fontId: Int, direction: STDirection) -> CGGlyph {
        // Get ct font
        let ctFont = ctFont(fontId: fontId, size: 17)
        
        // Get ellipsis glyph
        var glyph: CGGlyph = 0
        var buf = [UniChar]()
        switch direction {
        case .lrTb:
            buf = uniChars(string: Self.horizontalEllipsis)
            if CTFontGetGlyphsForCharacters(ctFont, &buf, &glyph, buf.count), glyph > 0 { return glyph }
            buf = uniChars(string: Self.middleHorizontalEllipsis)
            if CTFontGetGlyphsForCharacters(ctFont, &buf, &glyph, buf.count), glyph > 0 { return glyph }
        case .tbRl:
            buf = uniChars(string: Self.verticalEllipsis)
            if CTFontGetGlyphsForCharacters(ctFont, &buf, &glyph, buf.count), glyph > 0 { return glyph }
            buf = uniChars(string: Self.presentationVerticalEllipsis)
            if CTFontGetGlyphsForCharacters(ctFont, &buf, &glyph, buf.count), glyph > 0 { return glyph }
        }
        
        // For not found
        return 0
    }
    
    //--------------------------------------------------------------//
    // MARK: - Refresh
    //--------------------------------------------------------------//
    
    func refresh() {
        // Refresh possible font names and scripts
        var possibleFontNames = [String]()
        var possibleScripts = [STScript]()
        for script in STScript.allCases {
            guard let fontNames = scriptFontNames[script] else { continue }
            for fontName in fontNames {
                possibleFontNames.append(fontName)
                possibleScripts.append(script)
            }
        }
        self.possibleFontNames = possibleFontNames
        self.possibleScripts = possibleScripts
        fallbackFontIds = [:]
    }
}

private func uniChars(string: String) -> [UniChar] {
    // Get unichars
    var buf = Array<UniChar>(repeating: 0, count: string.utf16.count)
    for (i, c) in string.utf16.enumerated() { buf[i] = c }
    
    return buf
}

private func uniChars(char: Character) -> [UniChar] {
    // Get unichars
    var buf = Array<UniChar>(repeating: 0, count: char.utf16.count)
    for (i, c) in char.utf16.enumerated() { buf[i] = c }
    
    return buf
}
