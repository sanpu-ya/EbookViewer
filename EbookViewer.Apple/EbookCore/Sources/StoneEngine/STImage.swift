//
//  STImage.swift
//  EbookViewer
//
//  stone_engine に画像の表示を足すための追加。upstream には無い。
//
//  stone_engine は文字しか組まないので、画像は本文に置いた 1 文字 (全角空白) の場所を
//  目印にして、その上に描く。小さな画像は行の中に収め、段落に 1 つだけ置かれた挿絵は
//  1 ページを使って表示する。
//

import CoreGraphics

/// 本文に差し込む画像。
public struct STImageAnnotation {
    /// 本文中の位置 (STLabel.text の Character 単位)。その 1 文字が置き場所になる。
    public var offset: Int
    public var image: CGImage
    /// 1 ページを使って表示する挿絵か。false なら行の中に収める。
    public var isBlock: Bool

    public init(offset: Int, image: CGImage, isBlock: Bool) {
        self.offset = offset
        self.image = image
        self.isBlock = isBlock
    }

    /// 画像の縦横比 (幅 ÷ 高さ)。
    var aspectRatio: CGFloat {
        let height = CGFloat(image.height)
        guard height > 0 else { return 1 }
        return CGFloat(image.width) / height
    }

    /// 行の中に収めたときに、文字が進む向きで占める長さ。
    /// 行をまたいで大きくはできないので、行に直交する向きを 1 文字ぶんに合わせる。
    func inlineExtent(fontSize: CGFloat, direction: STDirection) -> CGFloat {
        let ratio = aspectRatio
        guard ratio > 0, ratio.isFinite else { return fontSize }
        switch direction {
        case .lrTb: return fontSize * ratio
        case .tbRl: return fontSize / ratio
        }
    }
}

extension STImageAnnotation: Equatable {
    public static func == (lhs: STImageAnnotation, rhs: STImageAnnotation) -> Bool {
        lhs.offset == rhs.offset && lhs.isBlock == rhs.isBlock && lhs.image === rhs.image
    }
}

extension CGContext {
    /// y 軸が下向きの座標系に、画像を上下そのままで描く。
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

extension CGRect {
    /// 縦横比を保ったまま rect に収めた大きさ、中央ぞろえ。
    static func fitting(aspectRatio: CGFloat, in rect: CGRect) -> CGRect {
        guard aspectRatio > 0, aspectRatio.isFinite, rect.width > 0, rect.height > 0 else { return rect }
        var size = CGSize(width: rect.width, height: rect.width / aspectRatio)
        if size.height > rect.height {
            size = CGSize(width: rect.height * aspectRatio, height: rect.height)
        }
        return CGRect(
            x: rect.midX - size.width * 0.5,
            y: rect.midY - size.height * 0.5,
            width: size.width,
            height: size.height)
    }
}
