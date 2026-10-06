import SwiftUI
import EbookCore
#if canImport(UIKit)
import UIKit
#endif

/// コミックのページ一覧 (サイドバー)。ComicInfo のブックマークがあれば先頭に並べ、その下にサムネイルを出す。
/// タップするとそのページへ移動する。
struct ComicThumbnailsView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if let store = model.comicImages {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let comic = model.comic, !comic.bookmarks.isEmpty {
                            bookmarks(comic.bookmarks)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 8)], spacing: 10) {
                            ForEach(0..<store.pageCount, id: \.self) { i in
                                thumbnail(i, store: store)
                                    .id(i)
                                    .onTapGesture { select(i) }
                            }
                        }
                    }
                    .padding(10)
                }
                .onAppear { proxy.scrollTo(model.comicPage, anchor: .center) }
                .onChange(of: model.comicPage) { _, p in
                    withAnimation { proxy.scrollTo(p, anchor: .center) }
                }
            }
        }
    }

    private func select(_ page: Int) {
        model.goToComicPage(page)
        #if !os(macOS)
        // iPhone (シート表示) では選択後に本文へ戻る
        if UIDevice.current.userInterfaceIdiom == .phone { model.setTocOpen(false) }
        #endif
    }

    /// ComicInfo の Bookmark (章など) の一覧。
    private func bookmarks(_ items: [ComicBookmark]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bookmarks")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(Array(items.enumerated()), id: \.offset) { item in
                let current = model.currentComicSpread.contains(item.element.pageIndex)
                Button {
                    select(item.element.pageIndex)
                } label: {
                    HStack {
                        Text(item.element.title)
                            .lineLimit(2)
                        Spacer()
                        Text("\(item.element.pageIndex + 1)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(current ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
                .padding(.top, 6)
        }
    }

    private func thumbnail(_ i: Int, store: ComicImageStore) -> some View {
        let current = model.currentComicSpread.contains(i)
        return VStack(spacing: 4) {
            Group {
                if let cg = store.thumbnail(i) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .aspectRatio(0.7, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(current ? Color.accentColor : Color.clear, lineWidth: 3))
            Text("\(i + 1)")
                .font(.caption2)
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
    }
}
