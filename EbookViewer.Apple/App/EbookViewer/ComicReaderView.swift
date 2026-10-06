import SwiftUI
import EbookCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// コミックのページ表示。単ページ / 見開き / 縦スクロール (Webtoon)、幅・高さ・全体へのフィット、ピンチ拡大に対応する。
/// ページ送りはキーボード、画面端のタップ / クリック、スワイプ、(Mac では) スクロールホイールで行う。
struct ComicReaderView: View {
    @Bindable var model: ReaderModel
    @State private var magnifyBase: Double = 1
    @State private var webtoonPosition: Int?
    @FocusState private var focused: Bool

    private var store: ComicImageStore? { model.comicImages }

    var body: some View {
        GeometryReader { geo in
            Group {
                if model.comicIsWebtoon {
                    webtoon(viewport: geo.size)
                } else {
                    paged(viewport: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: geo.size, initial: true) { _, size in model.comicViewport = size }
        }
        .background(Color(hex: model.comicBackgroundColorHex))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear { focused = true }
        .gesture(
            MagnifyGesture()
                .onChanged { v in model.comicZoom = min(5, max(0.5, magnifyBase * v.magnification)) }
                .onEnded { _ in
                    if model.comicZoom < 1.05 { model.comicZoom = 1 }
                    magnifyBase = model.comicZoom
                }
        )
    }

    // MARK: - 単ページ / 見開き

    @ViewBuilder
    private func paged(viewport: CGSize) -> some View {
        let spread = model.currentComicSpreadDisplayOrder
        let layout = pageLayout(spread: spread, viewport: viewport)
        let fits = layout.total.width <= viewport.width + 0.5 && layout.total.height <= viewport.height + 0.5
        ScrollView([.horizontal, .vertical], showsIndicators: !fits) {
            HStack(spacing: 0) {
                ForEach(Array(spread.enumerated()), id: \.element) { item in
                    pageImage(item.element)
                        .frame(width: layout.sizes[item.offset].width, height: layout.sizes[item.offset].height)
                }
            }
            .frame(width: max(layout.total.width, viewport.width), height: max(layout.total.height, viewport.height))
        }
        .scrollDisabled(fits)
        .defaultScrollAnchor(scrollAnchor)
        // ページが変わったらスクロール位置を初期位置に戻す
        .id("spread-\(spread.map(String.init).joined(separator: "-"))")
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleZoom() }
        .onTapGesture(count: 1, coordinateSpace: .local) { point in handleTap(point, viewport: viewport) }
        .simultaneousGesture(swipeGesture(enabled: fits))
        #if os(macOS)
        .background { ScrollWheelCatcher(enabled: fits) { forward in forward ? model.comicNext() : model.comicPrev() } }
        #endif
    }

    /// 見開き内の各ページの表示サイズと全体のサイズ。縦横比は既知の寸法から求め、未知なら 0.7 とする。
    private func pageLayout(spread: [Int], viewport: CGSize) -> (sizes: [CGSize], total: CGSize) {
        guard !spread.isEmpty, viewport.width > 0, viewport.height > 0 else { return ([], .zero) }
        let aspects = spread.map { store?.aspectRatio($0) ?? 0.7 }
        let sum = aspects.reduce(0, +)
        var height: CGFloat
        switch model.settings.comicFit {
        case "width": height = viewport.width / sum
        case "height": height = viewport.height
        default: height = min(viewport.height, viewport.width / sum)
        }
        height = (height * model.comicZoom).rounded(.down)
        let sizes = aspects.map { CGSize(width: ($0 * height).rounded(.down), height: height) }
        return (sizes, CGSize(width: sizes.reduce(0) { $0 + $1.width }, height: height))
    }

    private var scrollAnchor: UnitPoint {
        switch model.settings.comicFit {
        case "width": return .top
        case "height": return model.comicReadsRightToLeft ? .trailing : .leading
        default: return .center
        }
    }

    // MARK: - 縦スクロール (Webtoon)

    @ViewBuilder
    private func webtoon(viewport: CGSize) -> some View {
        let count = model.comic?.pageCount ?? 0
        let width = (viewport.width * model.comicZoom).rounded(.down)
        ScrollView(model.comicZoom > 1 ? [.vertical, .horizontal] : .vertical) {
            LazyVStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    pageImage(i)
                        .frame(width: width, height: (width / (store?.aspectRatio(i) ?? 0.7)).rounded(.down))
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $webtoonPosition)
        .onAppear { webtoonPosition = model.comicPage }
        .onChange(of: webtoonPosition) { _, p in
            if let p, p != model.comicPage { model.setComicPage(p, fromScroll: true) }
        }
        .onChange(of: model.comicPage) { _, p in
            if webtoonPosition != p { webtoonPosition = p }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggleZoom() }
        .onTapGesture(count: 1, coordinateSpace: .local) { point in handleTapWebtoon(point, viewport: viewport) }
    }

    // MARK: - ページ画像

    @ViewBuilder
    private func pageImage(_ index: Int) -> some View {
        if let store, let cg = store.image(index) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .grayscale(model.settings.comicGrayscale ? 1 : 0)
                .colorInverted(model.settings.comicInvert)
        } else {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                ProgressView()
            }
        }
    }

    // MARK: - 操作

    /// 左右の端 (3 割) で前後のページ、中央はツールバーの表示切替 (iOS)。
    private func handleTap(_ point: CGPoint, viewport: CGSize) {
        focused = true
        let rtl = model.comicReadsRightToLeft
        if point.x < viewport.width * 0.3 {
            rtl ? model.comicNext() : model.comicPrev()
        } else if point.x > viewport.width * 0.7 {
            rtl ? model.comicPrev() : model.comicNext()
        } else {
            #if !os(macOS)
            model.tapCenter?()
            #endif
        }
    }

    /// 縦スクロールでは上下の端で前後のページ、中央はツールバーの表示切替 (iOS)。
    private func handleTapWebtoon(_ point: CGPoint, viewport: CGSize) {
        focused = true
        if point.y < viewport.height * 0.25 {
            model.comicPrev()
        } else if point.y > viewport.height * 0.75 {
            model.comicNext()
        } else {
            #if !os(macOS)
            model.tapCenter?()
            #endif
        }
    }

    private func toggleZoom() {
        model.comicZoom = model.comicZoom > 1.05 ? 1 : 2
        magnifyBase = model.comicZoom
    }

    /// 横スワイプでページ送り (ページが画面に収まっていてスクロールしないときだけ)。
    private func swipeGesture(enabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 40).onEnded { v in
            guard enabled else { return }
            let dx = v.translation.width
            let dy = v.translation.height
            guard abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
            // 指を左へ動かす = 右側にあるページを見に行く
            let towardRight = dx < 0
            if towardRight == !model.comicReadsRightToLeft { model.comicNext() } else { model.comicPrev() }
        }
    }

    /// キー操作。⌘ 付きはメニューコマンドに任せる。
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        let rtl = model.comicReadsRightToLeft
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        // Shift + 矢印は見開きの組み合わせを 1 ページ分ずらす
        case .leftArrow: shift ? model.comicShiftOnePage(forward: rtl) : (rtl ? model.comicNext() : model.comicPrev())
        case .rightArrow: shift ? model.comicShiftOnePage(forward: !rtl) : (rtl ? model.comicPrev() : model.comicNext())
        case .downArrow, .pageDown: model.comicNext()
        case .upArrow, .pageUp: model.comicPrev()
        case .space: press.modifiers.contains(.shift) ? model.comicPrev() : model.comicNext()
        case .home: model.comicFirstPage()
        case .end: model.comicLastPage()
        case .escape:
            guard model.tocOpen else { return .ignored }
            model.setTocOpen(false)
        default:
            switch press.characters {
            case "t", "T": model.setTocOpen(!model.tocOpen)
            case "+", "=": model.comicZoomIn()
            case "-": model.comicZoomOut()
            case "0": model.comicZoomReset()
            case "d", "D": model.toggleComicDirection()
            default: return .ignored
            }
        }
        return .handled
    }
}

private extension View {
    @ViewBuilder
    func colorInverted(_ on: Bool) -> some View {
        if on { colorInvert() } else { self }
    }
}

#if os(macOS)
/// スクロールホイール / トラックパッドのスクロールでページ送りするための透明ビュー。
/// クリックは通す (hitTest で nil) ので、上に重ねても SwiftUI のジェスチャーを邪魔しない。
struct ScrollWheelCatcher: NSViewRepresentable {
    var enabled: Bool
    /// true なら次のページ、false なら前のページ。
    var onPage: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.enabled = enabled
        view.onPage = onPage
    }

    final class CatcherView: NSView {
        var enabled = false
        var onPage: ((Bool) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var firedInGesture = false
        private var lastWheelFire = Date.distantPast

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) {
            guard enabled, let window, event.window === window else { return }
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // 慣性スクロールは無視する (1 回のスワイプで何ページも進まないように)
            guard event.momentumPhase.isEmpty else { return }
            // 縦のスクロールを優先し、横だけならそれを使う。負が下 / 右方向 = 次のページ
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            if event.phase.isEmpty {
                // ホイール付きマウス: イベントごとに判定し、連続入力を間引く
                guard delta != 0, Date().timeIntervalSince(lastWheelFire) > 0.2 else { return }
                lastWheelFire = Date()
                onPage?(delta < 0)
                return
            }
            if event.phase.contains(.began) {
                accumulated = 0
                firedInGesture = false
            }
            accumulated += delta
            if !firedInGesture && abs(accumulated) >= 12 {
                firedInGesture = true
                onPage?(accumulated < 0)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulated = 0
                firedInGesture = false
            }
        }
    }
}
#endif
