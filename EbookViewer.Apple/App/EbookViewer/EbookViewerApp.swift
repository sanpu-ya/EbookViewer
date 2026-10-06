import SwiftUI
import EbookCore

@main
struct EbookViewerApp: App {
    @State private var model = ReaderModel()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(macOS)
        // 起動引数にファイルパスが渡されたら開く
        if let path = CommandLine.arguments.dropFirst().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            model.requestOpen(URL(fileURLWithPath: path))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { url in
                    // Finder / Files からの「このアプリで開く」
                    if ReaderModel.canOpen(url) { model.requestOpen(url) }
                }
                #if os(macOS)
                .onAppear { appDelegate.attach(model) }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 820)
        .windowToolbarStyle(.unified)
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { model.persistAll() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.openRequested?() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    let recents = model.existingRecentFiles
                    if recents.isEmpty {
                        Text("(No Recent Files)")
                    } else {
                        ForEach(recents) { r in
                            Button(r.name) { model.openRecent(r) }
                        }
                    }
                }
            }
            CommandGroup(after: .sidebar) {
                Button(model.tocOpen ? "Hide Table of Contents" : "Show Table of Contents") { model.setTocOpen(!model.tocOpen) }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Next Page") { model.nextPage() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.hasContent)
                Button("Previous Page") { model.prevPage() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.hasContent)
                Divider()
                Picker("Writing Mode", selection: Binding(get: { model.settings.writingMode }, set: { model.setWritingMode($0) })) {
                    ForEach(ReaderModel.writingModes, id: \.key) { m in
                        Text(m.label).tag(m.key)
                    }
                }
                Button("Cycle Writing Mode") { model.cycleWritingMode() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Increase Text Size") { model.fontUp() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Text Size") { model.fontDown() }
                    .keyboardShortcut("-", modifiers: .command)
            }
            CommandMenu("Display") {
                Picker("Theme", selection: Binding(get: { model.settings.theme }, set: { model.setTheme($0) })) {
                    Text("Light").tag("light")
                    Text("Sepia").tag("sepia")
                    Text("Dark").tag("dark")
                }
                Picker("Font", selection: Binding(get: { model.settings.fontKey == "gothic" ? "gothic" : "mincho" }, set: { model.setFont($0) })) {
                    Text("Mincho (Serif)").tag("mincho")
                    Text("Gothic (Sans-serif)").tag("gothic")
                }
                Picker("Line Spacing", selection: Binding(get: { ContentView.lineHeightKey(model.settings.lineHeight) }, set: { model.setLineHeight($0) })) {
                    Text("Tight (1.6)").tag(1.6)
                    Text("Normal (1.9)").tag(1.9)
                    Text("Loose (2.2)").tag(2.2)
                }
                Picker("Margins", selection: Binding(get: { ContentView.paddingKey(model.settings.paddingPx) }, set: { model.setPadding($0) })) {
                    Text("Narrow").tag(16)
                    Text("Normal").tag(36)
                    Text("Wide").tag(64)
                }
            }
            CommandMenu("Comic") {
                Picker("Reading Direction", selection: Binding(get: { model.settings.comicDirection }, set: { model.setComicDirection($0) })) {
                    ForEach(ReaderModel.comicDirections, id: \.key) { d in
                        Text(d.label).tag(d.key)
                    }
                }
                Button("Toggle Reading Direction") { model.toggleComicDirection() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Picker("Layout", selection: Binding(get: { model.settings.comicLayout }, set: { model.setComicLayout($0) })) {
                    ForEach(ReaderModel.comicLayouts, id: \.key) { l in
                        Text(l.label).tag(l.key)
                    }
                }
                Toggle("Show Cover Alone", isOn: Binding(get: { model.settings.comicCoverAlone }, set: { model.setComicCoverAlone($0) }))
                Button("Forward One Page") { model.comicShiftOnePage(forward: true) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(!model.isComic)
                Button("Back One Page") { model.comicShiftOnePage(forward: false) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(!model.isComic)
                Divider()
                Picker("Zoom", selection: Binding(get: { model.settings.comicFit }, set: { model.setComicFit($0) })) {
                    ForEach(ReaderModel.comicFits, id: \.key) { f in
                        Text(f.label).tag(f.key)
                    }
                }
                Button("Reset Zoom") { model.comicZoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!model.isComic)
                Divider()
                Toggle("Invert Colors", isOn: Binding(get: { model.settings.comicInvert }, set: { model.setComicInvert($0) }))
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Toggle("Grayscale", isOn: Binding(get: { model.settings.comicGrayscale }, set: { model.setComicGrayscale($0) }))
                Picker("Background", selection: Binding(get: { model.settings.comicBackground }, set: { model.setComicBackground($0) })) {
                    ForEach(ReaderModel.comicBackgrounds, id: \.key) { b in
                        Text(b.label).tag(b.key)
                    }
                }
                Divider()
                Button("First Page") { model.comicFirstPage() }
                    .disabled(!model.isComic)
                Button("Last Page") { model.comicLastPage() }
                    .disabled(!model.isComic)
            }
        }
    }
}

#if os(macOS)
import AppKit

/// Finder からのファイルオープンと終了時の保存。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: ReaderModel?
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ReaderModel.canOpen($0) }) else { return }
        if let model {
            model.requestOpen(url)
        } else {
            pendingURLs = [url]
        }
    }

    /// ビューが出たらモデルを結び付け、起動時に受け取っていたファイルを開く。
    func attach(_ model: ReaderModel) {
        self.model = model
        if let url = pendingURLs.first {
            pendingURLs.removeAll()
            model.requestOpen(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.persistAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif
