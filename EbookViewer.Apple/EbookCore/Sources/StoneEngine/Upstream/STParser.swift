/*
STParser.swift

Author: Makoto Kinoshita (mkino@hmdt.jp)

Copyright 2024 Nihon Design Center. All rights reserved.
This software is licensed under the MIT License. See LICENSE for details.
*/

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

class STParser {
    static let willParse = Notification.Name("STParserWillParse")
    static let didParse = Notification.Name("STParserDidParse")
    
    // Context
    let context: STContext
    
    // Run
    var runs = [STRun]()
    var tokens = [STToken]()
    
    //--------------------------------------------------------------//
    // MARK: - Initialize
    //--------------------------------------------------------------//
    
    init(context: STContext) {
        self.context = context
    }
    
    //--------------------------------------------------------------//
    // MARK: - Parse
    //--------------------------------------------------------------//
    
    private func createRun(char: Character, tokenId: Int, tokenRunIndex: Int) -> STRun {
        // Get style and size of this character (EbookViewer)
        let style = context.style(at: runs.count)
        let fontSize = context.adjustFontSize * context.sizeScale(at: runs.count)
        let orientation = context.orientation(at: runs.count)
        
        // 異体字セレクタのような、それ自体は字を持たない文字 (EbookViewer)。
        //
        // 単語で区切ると親字と離れて 1 つの run になることがあり、そのままだと字幅のある
        // 空白に見えてしまう。電書連 EPUB 3 制作ガイドの「今後の RS に期待する項目」も、
        // 字形選択子そのものを空白や他の文字として表示しないことを求めている。
        if char.unicodeScalars.allSatisfy({ $0.properties.isDefaultIgnorableCodePoint }) {
            return STRun(
                tokenId: tokenId, tokenRunIndex: tokenRunIndex, fontId: runs.last?.fontId ?? 0,
                style: style, fontSize: fontSize, char: char, punctuation: .whole, glyph: 0,
                advance: .zero, boundingRect: .zero, position: .zero, frame: .zero,
                visibility: .visible, line: 0)
        }
        
        // Decide font ID
        let fontId: Int
        if char.isNewline {
            fontId = runs.last?.fontId ?? 0
        }
        else {
            fontId = context.fontManager.fontId(char: char)
        }
        
        // Get CT font
        let ctFont = context.fontManager.ctFont(fontId: fontId, size: fontSize, style: style)
        
        // Get glyphs
        var buf = Array<UniChar>(repeating: 0, count: char.utf16.count)
        for (i, c) in char.utf16.enumerated() { buf[i] = c }
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(ctFont, &buf, &glyph, char.utf16.count)
        
        // For Japanese TbRl (EbookViewer: 倒す指定のときは縦書き用の字形に替えない)
        if char.unicodeScalars.first?.script == .japanese, context.direction == .tbRl,
            orientation != .sideways {
            // Get vertical glyphs
            let fontName = CTFontCopyFullName(ctFont) as String
            let vertGlyph = STTextVerticalSubstitutionGlyphWithGlyph(fontName: fontName, glyph: glyph)
            if vertGlyph != 0 { glyph = vertGlyph }
        }
        
        // Get advances
        var advance: CGSize = .zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        
        // Get bounding rects
        var boundingRect: CGRect = .zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &boundingRect, 1)
        
        // Decide punctuation
        let punctuation = STPunctuation.valueOf(charatcter: char)
        
        // Create run
        return STRun(tokenId: tokenId, tokenRunIndex: tokenRunIndex, fontId: fontId, style: style, orientation: orientation, fontSize: fontSize, char: char, punctuation: punctuation, glyph: glyph, advance: advance, boundingRect: boundingRect, position: .zero, frame: .zero, visibility: .visible, line: 0)
    }
    
    private func appendRuns(string: String, tokenId: Int) {
        // Get chars
        var tokenRunIndex: Int = 0
        for char in string {
            // Create run
            runs.append(createRun(char: char, tokenId: tokenId, tokenRunIndex: tokenRunIndex))
            
            // Increment token run index
            tokenRunIndex += 1
        }
    }
    
    func parse(text: String?) {
        // Notify it
        NotificationCenter.default.post(name: Self.willParse, object: self)
        
        let text = text ?? ""
        runs = [STRun]()
        tokens = [STToken]()
        var tokenId: Int = 0
        var prevRange: Range<String.Index>?
        
        // Declare create runs closure
        let createRuns: ((String) -> Void) = { substring in
            // Append runs
            let runId = self.runs.count
            self.appendRuns(string: substring, tokenId: tokenId)
            
            // Add token and runs
            self.tokens.append(STToken(runIdRange: runId ..< self.runs.count))
            
            // Increment token ID
            tokenId += 1
        }
        
        // Enumerate substring
        let options: String.EnumerationOptions = context.isDividedByWords ? .byWords : .byComposedCharacterSequences
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: options) { substring, substringRange, enclosingRange, willStop in
            // Detect not enumerated substring
            if prevRange == nil, substringRange.lowerBound > text.startIndex {
                // Create runs
                let substring = String(text[text.startIndex ..< substringRange.lowerBound])
                createRuns(substring)
            }
            else if let prevRange = prevRange, prevRange.upperBound < substringRange.lowerBound {
                // Create runs
                let substring = String(text[prevRange.upperBound ..< substringRange.lowerBound])
                createRuns(substring)
            }
            
            // Create runs
            guard let substring = substring else { return }
            createRuns(substring)
            
            // Set previous range
            prevRange = substringRange
        }
        
        // Check last
        if prevRange == nil {
            createRuns(text)
        }
        else if let prevRange = prevRange, prevRange.upperBound < text.endIndex {
            // Create runs
            let substring = String(text[prevRange.upperBound ..< text.endIndex])
            createRuns(substring)
        }
        
        // Set runs
        context.runs = runs
        context.tokens = tokens
        context.lineCount = 0
        
        // Notify it
        NotificationCenter.default.post(name: Self.didParse, object: self)
    }
}
