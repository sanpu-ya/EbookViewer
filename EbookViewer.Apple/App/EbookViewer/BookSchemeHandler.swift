import Foundation
import WebKit
import EbookCore

/// 本文を配信する独自スキーム。WKWebView は https の仮想ホストに応答を差し替えられないので、
/// "ebook://book/<書籍内パス>" を WKURLSchemeHandler で処理する。
enum BookScheme {
    static let scheme = "ebook"
    static let host = "book"
    static let baseURL = "ebook://book/"

    /// 書籍内パス → URL。各セグメントをパーセントエンコードする。
    static func url(forPath path: String) -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let encoded = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: baseURL + encoded) ?? URL(string: baseURL)!
    }
}

/// スキームハンドラーが本文を組み立てるのに必要な情報の提供元。
@MainActor
protocol BookContentProvider: AnyObject {
    var currentBook: BookDocument? { get }
    func makeViewerOptions() -> ViewerOptions
}

final class BookSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var provider: BookContentProvider?
    /// 進行中のタスク。stop 後に didReceive を呼ぶと例外になるため追跡する。
    private var active: [ObjectIdentifier: WKURLSchemeTask] = [:]
    private let queue = DispatchQueue(label: "EbookViewer.BookScheme", qos: .userInitiated, attributes: .concurrent)

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        active[id] = urlSchemeTask
        guard let url = urlSchemeTask.request.url else {
            finish(id, status: 400, contentType: "text/plain", data: Data())
            return
        }
        // 書籍と表示設定はメインスレッド (start はメインで呼ばれる) で確定し、展開と注入はバックグラウンドで行う
        let (book, options): (BookDocument?, ViewerOptions) = MainActor.assumeIsolated {
            (provider?.currentBook, provider?.makeViewerOptions() ?? ViewerOptions())
        }
        let path = PathUtil.normalize(url.path)
        let started = Date()
        AppDirectories.trace("resource start \(url.absoluteString) book=\(book != nil)")
        queue.async { [weak self] in
            var data: Data?
            var contentType = "application/octet-stream"
            var status = 200
            if path.hasPrefix(ContentPreparer.assetPrefix) {
                let name = String(path.dropFirst(ContentPreparer.assetPrefix.count))
                data = ContentPreparer.asset(named: name)
                contentType = ContentPreparer.assetMediaType(name)
            } else if let book, let res = book.findResource(path) {
                do {
                    let raw = try res.getData()
                    if PathUtil.isHtmlMediaType(res.mediaType) {
                        let prepared = ContentPreparer.prepare(raw, mediaType: res.mediaType, options: options)
                        data = prepared.body
                        contentType = prepared.contentType
                    } else {
                        data = raw
                        contentType = res.mediaType
                    }
                } catch {
                    let msg = String(describing: error)
                        .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    data = Data("<html><body><pre>\(msg)</pre></body></html>".utf8)
                    contentType = "text/html; charset=utf-8"
                    status = 500
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    AppDirectories.trace("resource done \(path) status=\(status) type=\(contentType) bytes=\(data?.count ?? -1) \(ms)ms self=\(self != nil)")
                    guard let self else { return }
                    if let data {
                        self.finish(id, status: status, contentType: contentType, data: data)
                    } else {
                        self.finish(id, status: 404, contentType: "text/plain", data: Data("Not Found".utf8))
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        AppDirectories.trace("resource stop \(urlSchemeTask.request.url?.absoluteString ?? "-")")
        active.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }

    private func finish(_ id: ObjectIdentifier, status: Int, contentType: String, data: Data) {
        guard let task = active.removeValue(forKey: id), let url = task.request.url else {
            AppDirectories.trace("resource finish skipped (task already stopped)")
            return
        }
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
