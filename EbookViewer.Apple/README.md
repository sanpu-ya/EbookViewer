# EbookViewer (macOS / iOS 版)

Windows 版 (C# / WinUI 3) と同等の機能を持つ、EPUB / MOBI / AZW3 対応・縦書き日本語対応の電子書籍ビューアーの Swift 移植です。
1 つの SwiftUI マルチプラットフォーム App ターゲットで macOS 14 以降と iOS / iPadOS 17 以降に対応します。

## 対応形式

Windows 版と同じです (EPUB 2/3、KF8 `.azw3` `.kf8`、ハイブリッド / 旧形式 `.mobi` `.prc` `.azw`)。
PalmDOC / HUFF-CDIC 展開、IDPF・Adobe 方式のフォント難読化解除、`kindle:pos:fid` / `kindle:embed` / `kindle:flow` /
`filepos` / `recindex` / `mbp:pagebreak` の変換も同じロジックを Swift に移植しています。DRM 付きのファイルは開けません。

## 構成

```
EbookViewer.Apple/
  EbookViewer.xcodeproj      Xcode プロジェクト (xcodegen で project.yml から生成)
  project.yml                XcodeGen 定義
  App/EbookViewer/           SwiftUI アプリ (macOS / iOS 共通ソース)
    EbookViewerApp.swift     App、メニューコマンド、Finder からのオープン
    ContentView.swift        画面全体 (Mac/iPad: サイドバー + 本文、iPhone: 本文 + 目次シート)
    ReaderModel.swift        画面状態と操作 (Windows 版 MainWindow.xaml.cs 相当)
    BookWebView.swift        WKWebView のラッパーと JS ブリッジ
    BookSchemeHandler.swift  ebook:// スキームで本文・画像・CSS を配信 (WebResourceRequested 相当)
    ReaderSettings.swift     設定・読書位置・最近開いたファイルの保存
    TocView.swift            目次パネル
    Info.plist / *.entitlements / Assets.xcassets
  EbookCore/                 形式非依存のコア (Swift Package、Linux でもテスト可能)
    Sources/EbookCore/
      Model/                 BookDocument / SpineItem / TocEntry / BookResource / PathUtil
      Epub/                  ZipArchive (自前の ZIP 読み込み) と EpubLoader
      Mobi/                  PalmDB, MOBI ヘッダー/EXTH, INDX, PalmDOC/HUFF-CDIC 展開, KF7/KF8 ビルダー
      Rendering/             ContentPreparer (CSS/JS 注入) と Resources/viewer.css, viewer.js
      Support/               XML 簡易 DOM、zlib、SHA-1、CP1252、HTML 実体、正規表現ヘルパー
    Tests/EbookCoreTests/    XCTest (サンプル書籍は Windows 版と同じ『機械』『奇巌城』)
```

Windows 版との対応:

| Windows 版 | Apple 版 |
|---|---|
| WebView2 + 仮想ホスト `https://book.ebookviewer.invalid/` | WKWebView + 独自スキーム `ebook://book/` (`WKURLSchemeHandler`) |
| `window.chrome.webview.postMessage` | `window.webkit.messageHandlers.ev.postMessage` (viewer.js は両方に対応) |
| `System.IO.Compression.ZipArchive` | 自前の `ZipArchive` + zlib |
| `XDocument` | `XMLParser` で組み立てる軽量 DOM (`XMLNode`) — iOS には `XMLDocument` が無いため |
| `%LOCALAPPDATA%\EbookViewer\` | `~/Library/Application Support/EbookViewer/` (サンドボックス内は `~/Library/Containers/.../`) |
| Yu Mincho / Yu Gothic | Hiragino Mincho ProN / Hiragino Sans |

## 操作

| 操作 | Mac | iPhone / iPad |
|---|---|---|
| ファイルを開く | ⌘O、ウィンドウへドロップ、Finder で開く | ツールバー「開く」、Files アプリから共有 |
| 目次 | ⌘T (本文フォーカス時は `t`)、Esc で閉じる | ツールバー「目次」(iPhone はシート、iPad はサイドバー) |
| 次のページ | ← (縦書き) / → (横書き)、PageDown、Space、↓、ホイール、画面左端クリック、⌘] | 画面左端タップ (縦書き)、スワイプ |
| 前のページ | → (縦書き) / ← (横書き)、PageUp、Shift+Space、↑、画面右端クリック、⌘[ | 画面右端タップ (縦書き)、スワイプ |
| 章の先頭／末尾 | Home / End | — |
| 文字サイズ | ⌘+ / ⌘- | 「表示」メニュー |
| 組方向 | ツールバー / ⌘⇧W (自動 → 縦書き → 横書き) | ツールバー |
| テーマ・フォント・行間・余白 | ツールバー「表示」または「表示」メニュー | ツールバー「表示」 |
| ツールバーを隠す | — | 画面中央をタップ |

読書位置と設定は Application Support/EbookViewer/ の `positions.json` `settings.json` に保存され、次回同じファイルを開くと復元されます。
「最近開いたファイル」はセキュリティスコープ付きブックマークで保持するので、サンドボックス内でも再度開けます。

## ビルド

必要なもの: Xcode 15 以降 (macOS 14 SDK)。

1. `EbookViewer.xcodeproj` を開く
2. 署名の Team を設定する (Signing & Capabilities)
3. 実行先に "My Mac" または iOS シミュレーター / 実機を選んで Run

`project.yml` を変更したら [XcodeGen](https://github.com/yonaskolb/XcodeGen) で再生成します:

```bash
brew install xcodegen
cd EbookViewer.Apple && xcodegen generate
```

コアのテスト (Xcode 不要、macOS / Linux):

```bash
cd EbookViewer.Apple/EbookCore && swift test
```

Xcode で開いた場合は Package.swift をワークスペースに追加するか、`EbookCore` フォルダーを Xcode で開くとテストを実行できます。

## 実装メモ

- 本文のページ分割は Windows 版と同じ `viewer.css` / `viewer.js` (多段組み + `column-width`) で行います。
  WebKit でも `writing-mode: vertical-rl` の多段組みは動作します。
- iOS では WKWebView のネイティブスクロールを止め、`viewer.js` の touch ハンドラーでスワイプ / タップによるページ送りを行います。
- Cmd キー付きのショートカットは JS 側で無視し、SwiftUI のメニューコマンドに任せます。
- 文字コード: UTF-8 / UTF-16 / CP1252 (自前) / Latin-1 に加え、Apple の Foundation が扱える Shift_JIS・EUC-JP・ISO-2022-JP に対応します。
- 本文の展開と CSS/JS 注入は `BookSchemeHandler` がバックグラウンドキューで行い、応答はメインスレッドで返します。
- ファイルを開けなかったときのエラーは Application Support/EbookViewer/error.log に追記されます。
