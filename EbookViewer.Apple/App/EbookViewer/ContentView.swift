import SwiftUI
import UniformTypeIdentifiers
import EbookCore

/// 対応ファイルの UTType。mobi / azw3 などは Info.plist の UTImportedTypeDeclarations で宣言している。
enum BookTypes {
    static let mobi = UTType(importedAs: "com.amazon.mobi-ebook")
    static let azw3 = UTType(importedAs: "com.amazon.azw3-ebook")
    static let azw = UTType(importedAs: "com.amazon.azw-ebook")
    static let all: [UTType] = [.epub, mobi, azw3, azw]
}

struct ContentView: View {
    @Bindable var model: ReaderModel
    @State private var showOpenPanel = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    #if !os(macOS)
    @State private var barsHidden = false
    #endif

    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            splitLayout
            #else
            if sizeClass == .compact {
                compactLayout
            } else {
                splitLayout
            }
            #endif
        }
        .onAppear {
            columnVisibility = model.tocOpen ? .all : .detailOnly
            model.openRequested = { showOpenPanel = true }
            #if !os(macOS)
            model.tapCenter = { withAnimation { barsHidden.toggle() } }
            #endif
        }
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: BookTypes.all, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.openFile(url) }
            }
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
    }

    /// Mac / iPad: 目次をサイドバーに出す。
    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TocView(model: model)
        } detail: {
            reader
                .navigationTitle(model.windowTitle)
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
                #endif
                .toolbar { toolbarContent }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: model.tocOpen) { _, open in
            columnVisibility = open ? .all : .detailOnly
        }
        .onChange(of: columnVisibility) { _, v in
            let open = v != .detailOnly
            if open != model.tocOpen { model.setTocOpen(open) }
        }
    }

    #if !os(macOS)
    /// iPhone: 本文を全面に出し、目次はシートで表示する。
    private var compactLayout: some View {
        NavigationStack {
            reader
                .navigationTitle(model.book == nil ? "EbookViewer" : model.bookTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(barsHidden ? .hidden : .visible, for: .navigationBar)
                .toolbar { toolbarContent }
        }
        .sheet(isPresented: Binding(get: { model.tocOpen }, set: { model.setTocOpen($0) })) {
            NavigationStack {
                TocView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { model.setTocOpen(false) }
                        }
                    }
            }
        }
    }
    #endif

    // MARK: - 本文

    private var reader: some View {
        VStack(spacing: 0) {
            ZStack {
                BookWebView(model: model)
                    .opacity(model.book == nil ? 0 : 1)
                if model.book == nil {
                    emptyState
                }
                if model.isLoading {
                    loadingOverlay
                }
            }
            #if os(macOS)
            statusBar
            #else
            if !barsHidden { statusBar }
            #endif
        }
        .background(Color(hex: model.settings.themeColors.background))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image("AppIconPreview")
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
            Text("Ebook Viewer")
                .font(.title.weight(.semibold))
            Text("Drop an EPUB / MOBI / AZW3 file here or choose one with Open. Japanese books are shown in vertical writing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open File…") { showOpenPanel = true }
            #if os(macOS)
            Text("Turn pages: ← → / Page Up Page Down / Space / scroll wheel / click the left or right edge")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
            #else
            Text("Turn pages: tap the left or right edge / swipe")
                .font(.caption)
                .foregroundStyle(.tertiary)
            #endif
        }
        .frame(maxWidth: 480)
        .padding()
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(model.loadingText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: model.settings.themeColors.background).opacity(0.85))
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack {
            Text(model.statusLeft)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(model.statusRight)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .navigation) {
            Button { showOpenPanel = true } label: { Label("Open", systemImage: "folder") }
                .help("Open File (⌘O)")
            recentMenu
            Toggle(isOn: Binding(get: { model.tocOpen }, set: { model.setTocOpen($0) })) {
                Label("Contents", systemImage: "list.bullet")
            }
            .help("Show Table of Contents (⌘T)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.prevPage() } label: { Label("Previous", systemImage: "chevron.backward") }
                .help("Previous Page")
                .disabled(model.book == nil)
            Button { model.nextPage() } label: { Label("Next", systemImage: "chevron.forward") }
                .help("Next Page")
                .disabled(model.book == nil)
            writingModeMenu
            Button { model.fontDown() } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                .help("Decrease Text Size (⌘-)")
            Button { model.fontUp() } label: { Label("Larger", systemImage: "textformat.size.larger") }
                .help("Increase Text Size (⌘+)")
            displayMenu
        }
        #else
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { model.setTocOpen(!model.tocOpen) } label: { Label("Contents", systemImage: "list.bullet") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showOpenPanel = true } label: { Label("Open", systemImage: "folder") }
            recentMenu
            writingModeMenu
            displayMenu
        }
        #endif
    }

    private var recentMenu: some View {
        Menu {
            let recents = model.existingRecentFiles
            if recents.isEmpty {
                Text("(No Recent Files)")
            } else {
                ForEach(recents) { r in
                    Button(r.name) { model.openRecent(r) }
                }
            }
        } label: {
            Label("Recent", systemImage: "clock")
        }
        .help("Recently Opened Files")
    }

    /// 組方向を直接選ぶメニュー (自動 / 縦書き / 横書き)。
    private var writingModeMenu: some View {
        Menu {
            Picker("Writing Mode", selection: Binding(get: { model.settings.writingMode }, set: { model.setWritingMode($0) })) {
                ForEach(ReaderModel.writingModes, id: \.key) { m in
                    Text(m.label).tag(m.key)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.writingModeLabel, systemImage: "text.alignright")
        }
        .help("Writing Mode (Auto / Vertical / Horizontal)")
    }

    private var displayMenu: some View {
        Menu {
            Picker("Theme", selection: Binding(get: { model.settings.theme }, set: { model.setTheme($0) })) {
                Text("Light").tag("light")
                Text("Sepia").tag("sepia")
                Text("Dark").tag("dark")
            }
            Picker("Font", selection: Binding(get: { model.settings.fontKey == "gothic" ? "gothic" : "mincho" }, set: { model.setFont($0) })) {
                Text("Mincho (Serif)").tag("mincho")
                Text("Gothic (Sans-serif)").tag("gothic")
            }
            Picker("Line Spacing", selection: Binding(get: { Self.lineHeightKey(model.settings.lineHeight) }, set: { model.setLineHeight($0) })) {
                Text("Tight (1.6)").tag(1.6)
                Text("Normal (1.9)").tag(1.9)
                Text("Loose (2.2)").tag(2.2)
            }
            Picker("Margins", selection: Binding(get: { Self.paddingKey(model.settings.paddingPx) }, set: { model.setPadding($0) })) {
                Text("Narrow").tag(16)
                Text("Normal").tag(36)
                Text("Wide").tag(64)
            }
            #if !os(macOS)
            Divider()
            Button { model.fontDown() } label: { Label("Decrease Text Size", systemImage: "textformat.size.smaller") }
            Button { model.fontUp() } label: { Label("Increase Text Size", systemImage: "textformat.size.larger") }
            #endif
        } label: {
            Label("Display", systemImage: "gearshape")
        }
        .help("Theme, Font, Line Spacing")
    }

    static func lineHeightKey(_ lh: Double) -> Double {
        lh < 1.75 ? 1.6 : (lh < 2.05 ? 1.9 : 2.2)
    }

    static func paddingKey(_ pad: Int) -> Int {
        pad < 26 ? 16 : (pad < 50 ? 36 : 64)
    }

    // MARK: - ドロップ

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url, BookLoader.isSupported(url) else { return }
            Task { @MainActor in await model.openFile(url) }
        }
        return true
    }
}

extension Color {
    /// "#rrggbb" から Color を作る。
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
