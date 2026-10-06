import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 目次パネル (サイドバー)。
struct TocView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.bookTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                if !model.bookAuthor.isEmpty {
                    Text(model.bookAuthor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if model.isComic {
                // コミックは目次の代わりにページのサムネイルを並べる
                ComicThumbnailsView(model: model)
            } else {
                List(model.tocItems, selection: $model.selectedTocId) { item in
                    Text(item.title)
                        .padding(.leading, CGFloat(item.depth) * 16)
                        .padding(.vertical, 2)
                        .tag(item.id)
                }
                .listStyle(.sidebar)
                .onChange(of: model.selectedTocId) { _, newValue in
                    guard let id = newValue, let item = model.tocItems.first(where: { $0.id == id }) else { return }
                    model.selectToc(item)
                    #if !os(macOS)
                    // iPhone (シート表示) では選択後に本文へ戻る
                    if UIDevice.current.userInterfaceIdiom == .phone { model.setTocOpen(false) }
                    #endif
                }
                .overlay {
                    if model.tocItems.isEmpty {
                        Text("Open a book to see its table of contents.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(model.isComic ? Text("Pages") : Text("Table of Contents"))
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 220, ideal: 320, max: 480)
        #endif
    }
}
