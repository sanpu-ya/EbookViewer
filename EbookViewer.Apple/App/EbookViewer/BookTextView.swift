import SwiftUI
import EbookCore
import StoneEngine
#if os(macOS)
import AppKit
private typealias ReaderColor = NSColor
#else
import UIKit
private typealias ReaderColor = UIColor
#endif

/// 表示領域か総ページ数が変わったことを知らせる STLabel。
/// STLabel は bounds に収まらない行も組んだままにするので、ページ数はレイアウト後に確定する。
final class PagedTextLabel: STLabel {
    /// 表示領域か総ページ数が変わったときに呼ばれる。
    var onLayout: (() -> Void)?

    private var reported: (size: CGSize, pageCount: Int)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let state = (size: bounds.size, pageCount: pageCount)
        guard reported == nil || reported! != state else { return }
        reported = state
        onLayout?()
    }
}

/// STLabel と ReaderModel をつなぐ。ページ送りと読書位置のやり取りを受け持つ。
@MainActor
final class TextViewCoordinator: TextBridge {
    private let model: ReaderModel
    let label = PagedTextLabel(frame: .zero)

    /// 本文中のアンカー (id / name) → 文字位置。
    private var anchors: [String: Int] = [:]
    /// 表示領域が決まるまで待っている初期位置。
    private var pendingInitial: InitialPosition?
    private var currentPage = 0
    private var currentPages = 1
    /// SwiftUI 側へフォーカスを戻すためのフック。
    var requestFocus: (() -> Void)?

    init(model: ReaderModel) {
        self.model = model
        label.isPaged = true
        label.textAlign = .leading
        label.directionAlign = .start
        label.punctuationMode = .stone
        label.isKinsokuAvailable = true
        label.isDividedByWords = true
        label.isAllowedTateChuYoko = true
        label.onLayout = { [weak self] in self?.layoutChanged() }
        model.text = self
        model.textDidAttach()
    }

    // MARK: - 表示設定

    func applyAppearance(settings: ReaderSettings, vertical: Bool) {
        label.direction = vertical ? .tbRl : .lrTb
        label.fontSize = settings.fontSizePx
        label.lineHeightScale = settings.lineHeight
        label.textColor = ReaderColor(hex: settings.themeColors.foreground)
        label.backgroundColor = ReaderColor(hex: settings.themeColors.background)
        label.setFontNames(settings.stoneJapaneseFontNames, script: .japanese)
        label.setFontNames(settings.stoneLatinFontNames, script: .latin)
    }

    // MARK: - TextBridge

    func show(text: String, anchors: [String: Int], initial: InitialPosition) {
        self.anchors = anchors
        label.text = text
        pendingInitial = initial
        applyPendingInitial(needsLayout: true)
    }

    func clear() {
        anchors = [:]
        pendingInitial = nil
        currentPage = 0
        currentPages = 1
        label.text = nil
        label.pageIndex = 0
    }

    func next() {
        guard currentPage + 1 < label.pageCount else {
            model.contentWantsNextChapter()
            return
        }
        goTo(page: currentPage + 1)
    }

    func prev() {
        guard currentPage > 0 else {
            model.contentWantsPrevChapter()
            return
        }
        goTo(page: currentPage - 1)
    }

    func goTo(page: Int) {
        show(page: page, isReady: false)
    }

    func goTo(anchor: String) {
        guard let offset = anchors[anchor] else { return }
        show(page: label.page(ofCharacterAt: offset), isReady: false)
    }

    func focus() {
        requestFocus?()
    }

    // MARK: - ページ

    private func show(page: Int, isReady: Bool) {
        let count = max(1, label.pageCount)
        let clamped = min(max(0, page), count - 1)
        label.pageIndex = clamped
        currentPage = clamped
        currentPages = count
        if isReady {
            model.contentReady(page: clamped, pages: count)
        } else {
            model.contentPageChanged(page: clamped, pages: count)
        }
    }

    /// 初期位置を適用する。表示領域がまだ決まっていなければ、決まったとき (layoutChanged) に出し直す。
    private func applyPendingInitial(needsLayout: Bool) {
        guard let initial = pendingInitial else { return }
        guard label.bounds.width > 1, label.bounds.height > 1 else { return }
        // 総ページ数はレイアウトしないと分からないので、ここで組版を済ませる
        // (setNeedsLayout + layoutIfNeeded と違い、呼んだ時点で確実に終わる)
        if needsLayout { label.layoutSubviews() }
        pendingInitial = nil
        let count = max(1, label.pageCount)
        let target: Int
        switch initial {
        case .page(let p): target = p
        case .end: target = count - 1
        case .fraction(let f): target = Int((f * Double(count - 1)).rounded())
        case .anchor(let id): target = anchors[id].map { label.page(ofCharacterAt: $0) } ?? 0
        }
        show(page: target, isReady: true)
    }

    /// 文字サイズや表示領域が変わってページ数が変わったとき。
    private func layoutChanged() {
        if pendingInitial != nil {
            applyPendingInitial(needsLayout: false)
            return
        }
        guard label.text?.isEmpty == false else { return }
        // だいたい同じ位置になるページを出し直す
        let fraction = currentPages > 1 ? Double(currentPage) / Double(currentPages - 1) : 0
        let count = max(1, label.pageCount)
        show(page: Int((fraction * Double(count - 1)).rounded()), isReady: false)
    }
}

// MARK: - SwiftUI への橋渡し

#if os(macOS)
private struct StoneTextLabel: NSViewRepresentable {
    let model: ReaderModel
    let requestFocus: () -> Void

    func makeCoordinator() -> TextViewCoordinator { TextViewCoordinator(model: model) }

    func makeNSView(context: Context) -> PagedTextLabel { context.coordinator.label }

    func updateNSView(_ nsView: PagedTextLabel, context: Context) {
        context.coordinator.requestFocus = requestFocus
        context.coordinator.applyAppearance(settings: model.settings, vertical: model.isVerticalEffective)
    }
}
#else
private struct StoneTextLabel: UIViewRepresentable {
    let model: ReaderModel
    let requestFocus: () -> Void

    func makeCoordinator() -> TextViewCoordinator { TextViewCoordinator(model: model) }

    func makeUIView(context: Context) -> PagedTextLabel { context.coordinator.label }

    func updateUIView(_ uiView: PagedTextLabel, context: Context) {
        context.coordinator.requestFocus = requestFocus
        context.coordinator.applyAppearance(settings: model.settings, vertical: model.isVerticalEffective)
    }
}
#endif

/// stone_engine (STLabel) による本文表示。ページ送りはキーボード、画面端のタップ / クリック、
/// スワイプ、(Mac では) スクロールホイールで行う。操作の向きは WebView 表示と揃えている。
struct BookTextView: View {
    @Bindable var model: ReaderModel
    @FocusState private var focused: Bool

    private var vertical: Bool { model.isVerticalEffective }

    var body: some View {
        GeometryReader { geo in
            StoneTextLabel(model: model, requestFocus: { focused = true })
                .padding(CGFloat(model.settings.paddingPx))
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 1, coordinateSpace: .local) { point in handleTap(point, viewport: geo.size) }
                .simultaneousGesture(swipeGesture)
        }
        .background(Color(hex: model.settings.themeColors.background))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { focused = true }
        #if os(macOS)
        .background {
            ScrollWheelCatcher(enabled: true) { forward in
                forward ? model.nextPage() : model.prevPage()
            }
        }
        #endif
    }

    // MARK: - 操作

    /// 左右の端 (1/4) で前後のページ、中央はツールバーの表示切替 (iOS)。
    /// 縦書きでは左が「次」になる (右綴じ)。
    private func handleTap(_ point: CGPoint, viewport: CGSize) {
        focused = true
        if point.x < viewport.width * 0.25 {
            vertical ? model.nextPage() : model.prevPage()
        } else if point.x > viewport.width * 0.75 {
            vertical ? model.prevPage() : model.nextPage()
        } else {
            #if !os(macOS)
            model.tapCenter?()
            #endif
        }
    }

    /// 右へ払う = 縦書きなら次のページ (右綴じ)、横書きなら前のページ。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { v in
            let dx = v.translation.width
            let dy = v.translation.height
            if abs(dx) > abs(dy) * 1.5, abs(dx) > 40 {
                if dx > 0 {
                    vertical ? model.nextPage() : model.prevPage()
                } else {
                    vertical ? model.prevPage() : model.nextPage()
                }
            } else if abs(dy) > abs(dx) * 1.5, abs(dy) > 40 {
                dy < 0 ? model.nextPage() : model.prevPage()
            }
        }
    }

    /// キー操作。⌘ 付きはメニューコマンドに任せる。
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .leftArrow: vertical ? model.nextPage() : model.prevPage()
        case .rightArrow: vertical ? model.prevPage() : model.nextPage()
        case .downArrow, .pageDown, .return: model.nextPage()
        case .upArrow, .pageUp, .delete: model.prevPage()
        case .space: press.modifiers.contains(.shift) ? model.prevPage() : model.nextPage()
        case .home: model.firstPageOfChapter()
        case .end: model.lastPageOfChapter()
        case .escape:
            guard model.tocOpen else { return .ignored }
            model.setTocOpen(false)
        default:
            switch press.characters {
            case "t", "T": model.setTocOpen(!model.tocOpen)
            case "+", "=": model.fontUp()
            case "-": model.fontDown()
            default: return .ignored
            }
        }
        return .handled
    }
}

private extension ReaderColor {
    /// "#rrggbb" から色を作る。
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xFFFFFF
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}
