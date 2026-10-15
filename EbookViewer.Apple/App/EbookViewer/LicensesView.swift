import SwiftUI

/// 同梱しているソフトウェアの 1 件分。原文は Licenses/<id>.txt をそのまま読む。
struct LicenseEntry: Identifiable {
    let id: String
    let name: String
    let note: LocalizedStringKey
    let copyright: String

    static let all: [LicenseEntry] = [
        LicenseEntry(id: "EbookViewer", name: "EbookViewer",
                     note: "This app",
                     copyright: "MIT License · Copyright (c) 2026 Naomichi Nonaka / Sanpu-ya"),
        LicenseEntry(id: "StoneEngine", name: "stone_engine",
                     note: "Japanese typesetting engine",
                     copyright: "MIT License · Copyright (c) 2024 Nihon Design Center"),
        LicenseEntry(id: "Unrar.swift", name: "Unrar.swift",
                     note: "CBR (RAR) extraction",
                     copyright: "MIT License · Copyright (c) 2021 mtgto"),
        LicenseEntry(id: "unrar", name: "unrar",
                     note: "RAR decompression, bundled with Unrar.swift",
                     copyright: "UnRAR license · Copyright (c) Alexander L. Roshal"),
    ]

    /// バンドルに同梱した原文。読めなかったときは空にする。
    var text: String {
        guard let url = Bundle.main.url(forResource: id, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

/// ライセンス一覧。選ぶと原文を表示する。
struct LicensesView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List(LicenseEntry.all) { entry in
                NavigationLink {
                    LicenseTextView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.body.weight(.medium))
                        Text(entry.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.copyright)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(Text("Licenses"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 440)
        #endif
    }
}

/// ライセンス原文。等幅で表示し、選択してコピーできるようにする。
private struct LicenseTextView: View {
    let entry: LicenseEntry

    var body: some View {
        ScrollView {
            Text(entry.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(entry.name)
    }
}
