/*
STContext.swift

Author: Makoto Kinoshita (mkino@hmdt.jp)

Copyright 2024 Nihon Design Center. All rights reserved.
This software is licensed under the MIT License. See LICENSE for details.
*/

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

open class STContext {
    public static let cursorWide: CGFloat = 2

    // Runs
    public var runs = [STRun]()
    public var tokens = [STToken]()
    public var lineCount = 0

    // Font
    public let fontManager = STFontManager()

    // Layout
    public var fontSize: CGFloat = 17
    public var lineHeightScale: CGFloat = 1.0
    public var lineHeight: CGFloat { fontSize * lineHeightScale }
    public var lineGapHeight: CGFloat { fontSize * (lineHeightScale - 1) }
    public var textAlign: STTextAlign = .leading
    public var directionAlign: STDirectionAlign = .start
    public var direction: STDirection = .lrTb
    public var isAllowedTateChuYoko: Bool = true
    public var adjustsFontSizeToFitWidth: Bool = false
    public var minimumScaleFactor: CGFloat = 0

    // Layout for adjusting
    public var adjustFontScale: CGFloat = 1.0
    public var adjustFontSize: CGFloat { fontSize * adjustFontScale }
    public var adjustLineHeight: CGFloat { adjustFontSize * lineHeightScale }

    // Color
    public var textColor: UIColor = .label
    public var selectedAreaColor: UIColor = .link

    // Features
    public var punctuationMode: STPunctuationMode = .stone
    //var isHalfPunctuation = true
    public var isKinsokuAvailable = true
    public var isDividedByWords = true

    // Render
    public var renderSize: CGSize = .zero
    public var renderedSize: CGSize = .zero

    // Spacing (EbookViewer)
    /// run ごとに前後へ足す空き。ルビが親文字より長いときに親文字を広げるのに使う。
    /// 添字は run の添字。空なら字間を足さない。
    public var spacings: [STSpacing] = []

    /// runId の run の前後に足す空き。
    public func spacing(at runId: Int) -> STSpacing {
        runId >= 0 && runId < spacings.count ? spacings[runId] : .zero
    }
    
    // Style (EbookViewer)
    /// 文字ごとの字面の変化 (太字・斜体)。添字は run の添字。空なら変化なし。
    public var styles: [STTextStyle] = []
    
    /// runId の run の字面。
    public func style(at runId: Int) -> STTextStyle {
        runId >= 0 && runId < styles.count ? styles[runId] : []
    }
    
    // Indent (EbookViewer)
    /// 文字ごとの字下げ。その文字から行が始まるときに、行の始まりへ空ける長さ。
    public var indents: [CGFloat] = []
    /// 文字ごとの、折り返した行の字下げ (青空文庫の「折り返して N 字下げ」)。
    /// nil なら折り返した行も `indents` と同じだけ下げる。
    public var hangingIndents: [CGFloat?] = []
    /// 文字ごとの地付き・地寄せ。nil なら寄せない。値は行の終わりへ空ける長さ。
    public var trailingGaps: [CGFloat?] = []
    
    /// runId の run から行が始まるときの字下げ。
    public func indent(at runId: Int) -> CGFloat {
        guard runId >= 0, runId < indents.count else { return 0 }
        return max(0, indents[runId])
    }
    
    /// runId の run から行が始まるときの字下げ。`isWrapped` は、改行ではなく
    /// 行が折り返して始まる行かどうか。折り返した行には hangingIndents を使う。
    public func indent(at runId: Int, isWrapped: Bool) -> CGFloat {
        if isWrapped, runId >= 0, runId < hangingIndents.count, let hanging = hangingIndents[runId] {
            return max(0, hanging)
        }
        return indent(at: runId)
    }
    
    /// runId の run から始まる行を、行末へ寄せるか (寄せるなら行末に空ける長さ)。
    public func trailingGap(at runId: Int) -> CGFloat? {
        guard runId >= 0, runId < trailingGaps.count else { return nil }
        return trailingGaps[runId].map { max(0, $0) }
    }
    
    // Font size (EbookViewer)
    /// 文字ごとの大きさ (1.0 = fontSize)。添字は run の添字。空なら全部 1.0。
    public var sizeScales: [CGFloat] = []
    
    /// 行送りより大きな文字は隣の行とぶつかるので、これ以上は大きくしない。
    public var maxSizeScale: CGFloat { max(1, lineHeightScale) }
    
    /// runId の run の大きさ (1.0 = fontSize)。
    public func sizeScale(at runId: Int) -> CGFloat {
        guard runId >= 0, runId < sizeScales.count else { return 1 }
        return min(max(0.2, sizeScales[runId]), maxSizeScale)
    }
    
    // Superscript and subscript (EbookViewer)
    /// 文字ごとの、1 文字ぶんの枠の中で寄せる側。nil なら中央にそろえる (ふつうの文字)。
    /// 添字は run の添字。
    public var shifts: [STRubyPosition?] = []
    
    /// runId の run を枠のどちら側へ寄せるか。
    public func shift(at runId: Int) -> STRubyPosition? {
        guard runId >= 0, runId < shifts.count else { return nil }
        return shifts[runId]
    }
    
    // Tate chu yoko (EbookViewer)
    /// 数字でなくても縦中横にする run の添字 (青空文庫の「縦組み中で横に並んだ文字」)。
    public var forcedTateChuYoko: Set<Int> = []
    
    /// 縦中横にしてよい長さ (1 文字ぶんに対する比)。stone_engine は字を詰めないので、
    /// これを超える長さのまとまりは横に並べると隣の行にはみ出してしまう。
    static let tateChuYokoLimit: CGFloat = 1.5
    
    /// run が、指定された縦中横のまとまりに入っているか。
    /// 1 文字ぶんに収まらないほど長いまとまりは、横に並べずそのままにする。
    func isForcedTateChuYoko(run: STRun) -> Bool {
        guard !forcedTateChuYoko.isEmpty, run.tokenId < tokens.count else { return false }
        let range = tokens[run.tokenId].runIdRange
        guard range.allSatisfy({ forcedTateChuYoko.contains($0) }) else { return false }
        let total = range.reduce(CGFloat.zero) { $0 + runs[$1].advance.width }
        return total <= adjustFontSize * Self.tateChuYokoLimit
    }
    
    //--------------------------------------------------------------//
    // MARK: - Advance
    //--------------------------------------------------------------//
    
    public func advance(token: STToken) -> CGFloat {
        // Calc with runs (EbookViewer: 親文字を広げたぶんも足す)
        return token.runIdRange.reduce(0) { $0 + runs[$1].advance.width + spacing(at: $1).total }
    }
    
    //--------------------------------------------------------------//
    // MARK: - Token and run
    //--------------------------------------------------------------//
    
    public func isLastInToken(run: STRun) -> Bool {
        // Check token run index
        return run.tokenRunIndex >= tokens[run.tokenId].runIdRange.count - 1
    }
    
    public func runIndexes(line: Int) -> Range<Int>? {
        // Find runs at line
        var lower: Int = -1
        var upper: Int = -1
        for (index, run) in runs.enumerated() {
            // For found
            if run.line == line {
                if lower == -1 { lower = index }
                upper = index
            }
            // For over
            else if run.line > line {
                break
            }
        }
        
        // Create range
        guard lower != -1 || upper == -1 else { return nil }
        return lower ..< upper + 1
    }
    
    public func line(at runId: Int) -> Int {
        // Get line
        guard runs.count > 0 else { return 0 }
        if runId < runs.count - 1 { return runs[runId].line }
        else { return runs.last!.line }
    }
    
    public func isNewline(at runId: Int) -> Bool {
        // Check newline
        guard runs.count > 0 else { return false }
        if runId < runs.count - 1 { return runs[runId].char.isNewline }
        else { return runs.last!.char.isNewline }
    }
    
    public func tokenString(runId: Int) -> String? {
        // Get token string
        guard runId < runs.count - 1 else { return nil }
        return tokenString(tokenId: runs[runId].tokenId)
    }
    
    public func tokenString(tokenId: Int) -> String? {
        // Get token string
        guard tokenId < tokens.count - 1 else { return nil }
        return tokens[tokenId].runIdRange.reduce("") { "\($0!)\(runs[$1].char)" }
    }
    
    //--------------------------------------------------------------//
    // MARK: - Geometry
    //--------------------------------------------------------------//
    
    public func firstRunFrame(line: Int) -> CGRect {
        // Decide run rect
        var rect: CGRect = .zero
        switch direction {
        case .lrTb:
            rect.size.width = 0
            rect.size.height = fontSize
            rect.origin.x = 0
            rect.origin.y = CGFloat(line) * lineHeight
        case .tbRl:
            rect.size.width = fontSize
            rect.size.height = 0
            rect.origin.x = renderedSize.width - (CGFloat(line) * lineHeight) - rect.width
            rect.origin.y = 0
        }
        
        return rect
    }
    
    public func runFrameWithLineGap(at index: Int) -> CGRect {
        // For line 0
        if runs[index].line == 0 { return runs[index].frame }
        
        // Swtich by direction
        var runFrame: CGRect = .zero
        switch direction {
        case .lrTb:
            runFrame.origin.x = runs[index].frame.minX
            runFrame.origin.y = runs[index].frame.minY - lineGapHeight
            runFrame.size.width = runs[index].frame.width
            runFrame.size.height = runs[index].frame.height + lineGapHeight
        case .tbRl:
            runFrame.origin.x = runs[index].frame.minX
            runFrame.origin.y = runs[index].frame.minY
            runFrame.size.width = runs[index].frame.width + lineGapHeight
            runFrame.size.height = runs[index].frame.height
        }
        
        return runFrame
    }
    
    public func cursorFrame(at index: Int) -> CGRect {
        // Decide cursor frame
        var cursorFrame: CGRect = .zero
        switch direction {
        case .lrTb:
            if runs.count == 0 {
                let runFrame = firstRunFrame(line: 0)
                cursorFrame.size.width = Self.cursorWide
                cursorFrame.size.height = runFrame.height
                cursorFrame.origin.x = runFrame.minX - cursorFrame.width * 0.5
                cursorFrame.origin.y = runFrame.minY
            }
            else if index < runs.count {
                let runFrame = runs[index].frame
                cursorFrame.size.width = Self.cursorWide
                cursorFrame.size.height = runFrame.height
                cursorFrame.origin.x = runFrame.minX - cursorFrame.width * 0.5
                cursorFrame.origin.y = runFrame.minY
            }
            else {
                let runFrame = runs[runs.count - 1].frame
                cursorFrame.size.width = Self.cursorWide
                cursorFrame.size.height = runFrame.height
                cursorFrame.origin.x = runFrame.maxX - cursorFrame.width * 0.5
                cursorFrame.origin.y = runFrame.minY
            }
        case .tbRl:
            if runs.count == 0 {
                let runFrame = firstRunFrame(line: 0)
                cursorFrame.size.width = runFrame.width
                cursorFrame.size.height = Self.cursorWide
                cursorFrame.origin.x = runFrame.minX
                cursorFrame.origin.y = runFrame.minY - cursorFrame.height * 0.5
            }
            else if index < runs.count {
                let runFrame = runs[index].frame
                
                // For tate chu yoko
                if isTateChuYoko(run: runs[index]) {
                    cursorFrame.size.width = Self.cursorWide
                    cursorFrame.size.height = runFrame.height
                    cursorFrame.origin.x = runFrame.minX - cursorFrame.width * 0.5
                    cursorFrame.origin.y = runFrame.minY
                }
                // For other
                else {
                    cursorFrame.size.width = runFrame.width
                    cursorFrame.size.height = Self.cursorWide
                    cursorFrame.origin.x = runFrame.minX
                    cursorFrame.origin.y = runFrame.minY - cursorFrame.height * 0.5
                }
            }
            else {
                let runFrame = runs[runs.count - 1].frame
                cursorFrame.size.width = runFrame.width
                cursorFrame.size.height = Self.cursorWide
                cursorFrame.origin.x = runFrame.minX
                cursorFrame.origin.y = runFrame.maxY - cursorFrame.height * 0.5
            }
        }
        
        return cursorFrame
    }
    
    private func dx(from rect: CGRect, to point: CGPoint) -> CGFloat {
        // Calc distance X
        let dx = point.x - rect.midX
        return sqrt(dx * dx)
    }
    
    private func dy(from rect: CGRect, to point: CGPoint) -> CGFloat {
        // Calc distance Y
        let dy = point.y - rect.midY
        return sqrt(dy * dy)
    }
    
    private func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        // Calc distance
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return sqrt(dx * dx + dy * dy)
    }
    
    private func closestRunIndexH(to point: CGPoint, range: Range<Int>?) -> Int {
        // Decide range
        let isAll = range == nil
        let range = range ?? 0 ..< runs.count
        
        // Decide closest line
        var minDy: CGFloat = .greatestFiniteMagnitude
        var line = -1
        for i in range {
            // Check run
            guard runs[i].line != line else { continue }
            
            // Get first run frame
            let runFrame = firstRunFrame(line: runs[i].line)
            
            // Check dy
            let dy = dy(from: runFrame, to: point)
            guard dy < minDy else { continue }
            minDy = dy
            line = runs[i].line
        }
        if line == -1 { line = 0 }
        
        // Check last new line
        if isAll, isNewline(at: range.upperBound), line < lineCount {
            // Get first run frame for last line
            let runFrame = firstRunFrame(line: lineCount - 1)
            
            // Check dy
            let dy = dy(from: runFrame, to: point)
            if dy < minDy {
                minDy = dy
                line = lineCount - 1
            }
        }
        
        // Decide closest run
        var minDistance: CGFloat = .greatestFiniteMagnitude
        var index = 0
        for i in range {
            // Check line
            guard runs[i].line >= line - 1 && runs[i].line <= line + 1 else { continue }
            let runFrame = runs[i].frame
            
            // For new line
            if runs[i].char.isNewline {
                // Calc distance
                let d = distance(from: runFrame, to: point)
                if d < minDistance {
                    minDistance = d
                    index = i
                }
            }
            // For other
            else {
                // Calc dx for first half
                let firstHalfRect: CGRect = .init(x: runFrame.minX, y: runFrame.minY, width: runFrame.width * 0.5, height: runFrame.height)
                let fd = distance(from: firstHalfRect, to: point)
                if fd < minDistance {
                    minDistance = fd
                    index = i
                }
                
                // Calc dx for second half
                let secondHalfRect: CGRect = .init(x: runFrame.midX, y: runFrame.minY, width: runFrame.width * 0.5, height: runFrame.height)
                let sd = distance(from: secondHalfRect, to: point)
                if sd < minDistance {
                    minDistance = sd
                    index = i + 1
                }
            }
        }
        
        // For not found
        if minDistance == .greatestFiniteMagnitude {
            // Use last
            index = runs.count
        }
        
        return index
    }
    
    private func closestRunIndexV(to point: CGPoint, range: Range<Int>?) -> Int {
        // Decide range
        let isAll = range == nil
        let range = range ?? 0 ..< runs.count
        
        // Decide closest line
        var minDx: CGFloat = .greatestFiniteMagnitude
        var line = -1
        for i in range {
            // Check run
            guard i < runs.count else { break }
            guard runs[i].line != line else { continue }
            
            // Get first run frame
            let runFrame = firstRunFrame(line: runs[i].line)
            
            // Check dx
            let dx = dx(from: runFrame, to: point)
            guard dx < minDx else { continue }
            minDx = dx
            line = runs[i].line
        }
        if line == -1 { line = 0 }
        
        // Check last new line
        if isAll, isNewline(at: range.upperBound), line < lineCount {
            // Get first run rect for last line
            let runFrame = firstRunFrame(line: lineCount - 1)
            
            // Check dx
            let dx = dx(from: runFrame, to: point)
            if dx < minDx {
                minDx = dx
                line = lineCount - 1
            }
        }
        
        // Decide closest run
        var minDistance: CGFloat = .greatestFiniteMagnitude
        var index = 0
        for i in range {
            // Check run
            guard runs[i].line >= line - 1 && runs[i].line <= line + 1 else { continue }
            let runFrame = runs[i].frame
            
            // For new line
            if runs[i].char.isNewline {
                // Calc distance
                let d = distance(from: runFrame, to: point)
                if d < minDistance {
                    minDistance = d
                    index = i
                }
            }
            // For other
            else {
                // Calc distance for first half
                let firstHalfRect: CGRect = .init(x: runFrame.minX, y: runFrame.minY, width: runFrame.width, height: runFrame.height * 0.5)
                let fd = distance(from: firstHalfRect, to: point)
                if fd < minDistance {
                    minDistance = fd
                    index = i
                }
                
                // Calc distance for second half
                let secondHalfRect: CGRect = .init(x: runFrame.minX, y: runFrame.midY, width: runFrame.width, height: runFrame.height * 0.5)
                let sd = distance(from: secondHalfRect, to: point)
                if sd < minDistance {
                    minDistance = sd
                    index = i + 1
                }
            }
        }
        
        // For not found
        if minDistance == .greatestFiniteMagnitude {
            // Use last
            index = runs.count
        }
        
        return index
    }
    
    public func closestRunIndex(to point: CGPoint, range: Range<Int>? = nil) -> Int {
        // Check run count
        guard runs.count > 0 else { return 0 }
        
        // Switch by direction
        switch direction {
        case .lrTb: return closestRunIndexH(to: point, range: range)
        case .tbRl: return closestRunIndexV(to: point, range: range)
        }
    }
    
    private func hitRunIndexH(to point: CGPoint, range: Range<Int>?) -> Int? {
        // Decide range
        let range = range ?? 0 ..< runs.count
        
        // Decide hit run
        if runs.count == 0 {
            var runFrame = firstRunFrame(line: 0)
            runFrame.size.width = 8
            runFrame.origin.x -= runFrame.width * 0.5
            return runFrame.contains(point) ? 0 : nil
        }
        else {
            for i in range {
                // Check run frame
                let runFrame = runs[i].frame
                if runFrame.contains(point) { return i }
            }
        }
        
        return nil
    }
    
    private func hitRunIndexV(to point: CGPoint, range: Range<Int>?) -> Int? {
        // Decide range
        let range = range ?? 0 ..< runs.count
        
        // Decide hit run
        for i in range {
            // Check run frame
            let runFrame = runs[i].frame
            if runFrame.contains(point) { return i }
        }
        
        return nil
    }
    
    public func hitRunIndex(to point: CGPoint, range: Range<Int>? = nil) -> Int? {
        // Switch by direction
        switch direction {
        case .lrTb: return hitRunIndexH(to: point, range: range)
        case .tbRl: return hitRunIndexV(to: point, range: range)
        }
    }
    
    //--------------------------------------------------------------//
    // MARK: - Tate chu yoko
    //--------------------------------------------------------------//
    
    public func isTateChuYoko(token: STToken) -> Bool {
        // Check with first run
        guard let runId = token.runIdRange.first, runId < runs.count else { return false }
        return isTateChuYoko(run: runs[runId])
    }
    
    public func isTateChuYoko(run: STRun) -> Bool {
        // Check flag
        guard isAllowedTateChuYoko else { return false }
        
        // Check direction
        guard direction == .tbRl else { return false }
        
        // 指定された範囲は、数字でなくても縦中横にする (EbookViewer)
        if isForcedTateChuYoko(run: run) { return true }
        
        // Check script
        guard !fontManager.script(fontId: run.fontId).notNeedsToClockwiseInTbRl else { return false }
        
        // For number token
        if tokens[run.tokenId].runIdRange.map({ runs[$0] }).first(where: { !$0.char.isNumber }) == nil {
            // 欧文の語や式の中の数字は、まわりの欧文と同じく倒す (EbookViewer)
            guard !isInLatinWord(token: tokens[run.tokenId]) else { return false }
            
            // Check token count
            return tokens[run.tokenId].runIdRange.count <= 2
        }
        
        return false
    }
    
    /// 欧文の語や式の中の数字か (H2O の 2、x2 の 2 など)。
    ///
    /// 日本語の文の中の数字は縦中横にして正立させるが、欧文の中の数字をそうすると、
    /// 隣の欧文だけが倒れて組みがちぐはぐになる。隣が欧文の文字ならまとめて倒す。
    private func isInLatinWord(token: STToken) -> Bool {
        isLatinLetter(at: token.runIdRange.lowerBound - 1)
            || isLatinLetter(at: token.runIdRange.upperBound)
    }
    
    /// その run が、縦書きで倒して組む文字種の文字か。
    private func isLatinLetter(at runId: Int) -> Bool {
        guard runId >= 0, runId < runs.count else { return false }
        let run = runs[runId]
        guard run.char.isLetter else { return false }
        return !fontManager.script(fontId: run.fontId).notNeedsToClockwiseInTbRl
    }
    
    //--------------------------------------------------------------//
    // MARK: - Clockwise rotation
    //--------------------------------------------------------------//
    
    public func isClockwise(run: STRun) -> Bool {
        // Check script
        guard !fontManager.script(fontId: run.fontId).notNeedsToClockwiseInTbRl else { return false }
        
        // Check direction
        guard direction == .tbRl else { return false }
        
        // Check tate chu yoko
        return !isTateChuYoko(run: run)
    }
    
    //--------------------------------------------------------------//
    // MARK: - Adjust
    //--------------------------------------------------------------//
    
    public var isTruncated: Bool {
        // Check visibility
        for run in runs.reversed() {
            if run.visibility == .invisible || run.visibility == .ellipsis { return true }
        }
        
        return false
    }
}
