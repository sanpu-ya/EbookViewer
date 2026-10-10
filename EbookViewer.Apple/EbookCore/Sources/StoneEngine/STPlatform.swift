//
//  STPlatform.swift
//  EbookViewer
//
//  stone_engine (https://github.com/sanpu-ya/stone_engine) は UIKit 専用なので、
//  macOS でも同じソースをビルドできるように UIKit の名前を AppKit に橋渡しする。
//  Upstream/ 以下のファイルはこのシムに頼ることで、import 行以外ほぼ無変更で使える。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit

/// UIColor 相当。semantic color は NSColor の対応するものに読み替える。
public typealias UIColor = NSColor

extension NSColor {
    /// UIColor.label 相当。
    static var label: NSColor { .labelColor }
    /// UIColor.link 相当。
    static var link: NSColor { .linkColor }
    /// UIColor.systemBackground 相当 (文字を置く面の色)。
    static var systemBackground: NSColor { .textBackgroundColor }
}

/// UIGraphicsGetCurrentContext() 相当。draw(_:) の中から呼ぶ。
func UIGraphicsGetCurrentContext() -> CGContext? {
    NSGraphicsContext.current?.cgContext
}
#endif

// MARK: - ビューの土台

/// STLabel の基底クラス。UIView と NSView の差 (座標系・再描画要求・レイアウト通知) をここで埋める。
///
/// stone_engine は y 軸が下向き (UIKit) の座標系で組版し、グリフも y を反転した CTFont で描く。
/// そのため macOS では isFlipped を true にして UIKit と同じ座標系にする。
#if canImport(UIKit)
open class STPlatformView: UIView {}
#else
open class STPlatformView: NSView {
    /// UIKit と同じ y 軸下向きの座標系にする。
    open override var isFlipped: Bool { true }

    /// UIView.backgroundColor 相当。
    open var backgroundColor: NSColor? {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = backgroundColor?.cgColor
        }
    }

    open func setNeedsLayout() {
        needsLayout = true
    }

    open func setNeedsDisplay() {
        needsDisplay = true
    }

    /// UIView.layoutSubviews 相当。
    open func layoutSubviews() {}

    /// UIView.sizeThatFits(_:) 相当。
    open func sizeThatFits(_ size: CGSize) -> CGSize { .zero }

    open override func layout() {
        super.layout()
        layoutSubviews()
    }

    /// 再レイアウトのたびに描き直す (レイヤーの中身をキャッシュしない)。
    open override var wantsUpdateLayer: Bool { false }
}
#endif
