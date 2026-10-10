import Foundation
import EbookCore

/// stone_engine (STLabel) で本文を表示する経路。
/// WebView 経路と違って本文ドキュメントは HTML としてではなくプレーンテキストとして渡すので、
/// ここで XHTML からテキストとアンカー (目次のリンク先) の位置を取り出す。
extension ReaderModel {
    /// spine の index 番目の章を STLabel に表示する。
    func showSpineAsText(_ index: Int, initial: InitialPosition) {
        guard let book, index >= 0, index < book.spine.count else { return }
        showText(path: book.spine[index].path, initial: initial, spine: index)
    }

    /// 本文ドキュメント 1 件を STLabel に表示する。
    /// - Parameter spine: 表示し終えたときに章が変わっていないかを確かめるための spine 番号 (spine 外のファイルなら nil)。
    func showText(path: String, initial: InitialPosition, spine: Int? = nil) {
        guard let book, let text else { return }
        textLoadTask?.cancel()
        // 取り出しは本文の長さに比例して時間がかかるので、メインスレッドから外す
        textLoadTask = Task { [weak self] in
            let extracted = await Self.extractText(book: book, path: path)
            guard !Task.isCancelled, let self else { return }
            // 待っている間にページを送られていたら捨てる
            if let spine, self.spineIndex != spine { return }
            guard self.usesStoneEngine else { return }
            if extracted.text.isEmpty {
                AppDirectories.trace("stone: no text in \(path)")
            }
            text.show(extracted, initial: initial)
            text.focus()
        }
    }

    private static func extractText(book: BookDocument, path: String) async -> ExtractedText {
        await Task.detached(priority: .userInitiated) {
            guard let resource = book.findResource(path) else {
                AppDirectories.trace("stone: resource not found \(path)")
                return ExtractedText(text: "", anchors: [:])
            }
            do {
                let data = try resource.getData()
                return PlainTextExtractor.extract(data, mediaType: resource.mediaType)
            } catch {
                AppDirectories.logError("stone: read \(path): \(error)")
                return ExtractedText(text: "", anchors: [:])
            }
        }.value
    }
}
