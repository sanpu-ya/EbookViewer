# EbookViewer

EPUB / MOBI / AZW3 とコミック (CBZ / CBR / PDF / 画像フォルダー) に対応した、縦書き日本語対応の電子書籍ビューアーです。
Swift / SwiftUI で作られており、1 つのマルチプラットフォーム App ターゲットで macOS 14 以降と iOS / iPadOS 17 以降に対応します。

## 対応形式

### 電子書籍

| 形式 | 拡張子 | 備考 |
|---|---|---|
| EPUB 2 / 3 | `.epub` | nav.xhtml / NCX 目次、IDPF・Adobe 方式のフォント難読化解除に対応 |
| KF8 | `.azw3` `.kf8` | スケルトン／フラグメント索引から XHTML を再構成。`kindle:pos:fid` / `kindle:embed` / `kindle:flow` を解決 |
| ハイブリッド MOBI | `.mobi` | KF8 部があればそちらを優先。無ければ旧形式 (KF7) として読む |
| 旧形式 MOBI | `.mobi` `.prc` `.azw` | `filepos` / `recindex` / `mbp:pagebreak` を変換 |

PalmDOC 圧縮・HUFF/CDIC 圧縮の両方を展開できます。DRM 付きのファイルは開けません (エラーになります)。

文字コードは UTF-8 / UTF-16 / CP1252 / Latin-1 に加え、Foundation が扱える Shift_JIS・EUC-JP・ISO-2022-JP に対応します。

### コミック

[OpenComic](https://github.com/ollm/OpenComic) を参考にしたコミックリーダーを内蔵しています。

| 形式 | 備考 |
|---|---|
| `.cbz` / `.zip` | 自前の `ZipArchive` で展開。ファイル名の自然順 (`2.jpg` < `10.jpg`) に並べ、`__MACOSX` や隠しファイルは除外 |
| `.cbr` / `.rar` | [Unrar.swift](https://github.com/mtgto/Unrar.swift) (unrar 同梱) で展開。RAR 4 / 5 に対応、ページは要求時に取り出す (パスワード付き・分割書庫は不可) |
| 画像フォルダー | サブフォルダーも含めて相対パスの自然順に並べる。JPEG / PNG / GIF / WebP / BMP / TIFF / HEIC / AVIF / JXL |
| `.pdf` | PDFKit で各ページを描画して画像として表示 (パスワード付きは不可) |
| `.cb7` / `.cbt` | 7z / tar は展開できないため、CBZ への変換を促すエラーを表示 |

機能: 右開き (マンガ) / 左開きの切替、単ページ・見開き (横長の画面では自動で見開き、横長ページと表紙は単独表示)・
縦スクロール (Webtoon)、ページ全体 / 幅 / 高さへのフィット、ピンチ・⌘+ ⌘- による拡大、色の反転・グレースケール・背景色、
サイドバーのサムネイル一覧、ページスライダー、読書位置の記憶。

書庫やフォルダーに [ComicInfo.xml](https://github.com/anansi-project/comicinfo) (スキーマ v2.0 / v2.1) があれば読み取り、次のように使います。

| ComicInfo | 反映先 |
|---|---|
| `Series` / `Number` / `Volume` / `Title` | 表示タイトル (`Series #3 – Title`) |
| `Writer` / `Penciller` / `Inker` / `CoverArtist` | サイドバーの作者行 |
| `Manga` | 読み方向が「自動」のとき、`YesAndRightToLeft` なら右開き、`Yes` / `No` なら左開き (未指定なら右開き) |
| `Pages/Page` の `Type="FrontCover"` `"BackCover"` | 見開きにせず単独表示 (「表紙を単独で表示」が有効なとき) |
| `Pages/Page` の `DoublePage="true"` | 見開きにせず単独表示 |
| `Pages/Page` の `Type="Deleted"` | ページから除外 |
| `Pages/Page` の `Bookmark` | サイドバー先頭のブックマーク一覧 (章ジャンプ) |

`Page` の `Image` は書庫内の画像をファイル名順に並べたときの 0 始まりの番号として解釈します。複数の ComicInfo.xml があれば最も浅い階層のものを使います。

## 縦書き表示のしくみ

本文を組む「本文エンジン」を 2 つ持っていて、「表示」メニューで切り替えられます (⌘⇧E)。

| エンジン | 組版 | 画像・ルビ・強調 | 既定 |
|---|---|---|---|
| stone_engine | [stone_engine](https://github.com/sanpu-ya/stone_engine) の `STLabel` (禁則処理・約物半角・縦中横・文字種ごとのフォント) | 表示しない (画像は `［画像］`、ルビは親文字だけ) | ○ |
| WebView | WKWebView + CSS の多段組み | そのまま表示する | |

組方向は「自動 → 縦書き → 横書き」の順で切り替えられます (どちらのエンジンでも同じ)。「自動」では、書籍側の宣言
(`page-progression-direction="rtl"`、`primary-writing-mode`、CSS の `writing-mode: vertical-*`、
KF8 の EXTH 525/527) を優先し、宣言が無ければ日本語の本を縦書きにします。

### stone_engine (既定)

日本語組版エンジン [stone_engine](https://github.com/sanpu-ya/stone_engine) の `STLabel` で本文を描きます。
`STLabel` は UIKit 専用なので、macOS でも使えるようソースを
[`EbookCore/Sources/StoneEngine/`](EbookViewer.Apple/EbookCore/Sources/StoneEngine/) に取り込み、AppKit 向けのシムと
ページ分割を足しています (変更点は [同ディレクトリーの README](EbookViewer.Apple/EbookCore/Sources/StoneEngine/README.md))。

`STLabel` は文字列しか受け取らないので、本文ドキュメントは `PlainTextExtractor` でプレーンテキストに変換します。
ブロック要素の境目を改行にし (見出し・表・水平線の前後は空行)、`<ruby>` の親文字は残して `<rt>` のふりがなは落とし、
`<img>` は `［画像］` (alt があればその文字列) に置き換えます。全角文字に挟まれた原文の改行は、CSS の
segment break transformation rules と同じく空白にせず詰めます。`id` / `name` 属性の位置も覚えておき、
目次のリンク先 (`#fragment`) から表示ページを求めるのに使います。

ページ分割は、章全体を 1 回だけ組んでから行を block 方向 (縦書きなら右から左) に区切って行います。
ページを送るときは描画位置をずらすだけなので、組み直しは起きません。

画像・ルビ・強調をそのまま見たいときは「表示」メニューで WebView に切り替えてください。

### WebView

本文は WKWebView で描画します。本文ドキュメントに `viewer.css` / `viewer.js` を注入し、
`body` を `writing-mode: vertical-rl` の多段組みコンテナ (`column-width` = 表示領域の高さ) にすることで、
1 段 = 1 ページとして行が途中で切れないページ分割を行っています。縦書きではページが縦方向に積まれるため
縦スクロール、横書きでは横スクロールでページを送ります。

本文・画像・CSS は独自スキーム `ebook://book/` (`WKURLSchemeHandler`) で WKWebView に配信します。
本文の展開と CSS/JS 注入はバックグラウンドキューで行い、応答はメインスレッドで返します。
iOS では WKWebView のネイティブスクロールを止め、`viewer.js` の touch ハンドラーでスワイプ / タップによるページ送りを行います。
⌘ キー付きのショートカットは JS 側で無視し、SwiftUI のメニューコマンドに任せます。

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
| 本文エンジン | 「表示」メニュー / ⌘⇧E (stone_engine ⇄ WebView) | ツールバー「表示」 |
| テーマ・フォント・行間・余白 | ツールバー「表示」または「表示」メニュー | ツールバー「表示」 |
| ツールバーを隠す | — | 画面中央をタップ |

本文の既定フォントは Hiragino Mincho ProN (明朝) / Hiragino Sans (ゴシック) です。

コミック表示中の操作:

| 操作 | Mac | iPhone / iPad |
|---|---|---|
| 次 / 前のページ | ← → (読み方向に従う)、PageDown / PageUp、Space / Shift+Space、↓ / ↑、ホイール、画面端クリック、⌘] / ⌘[ | 画面端タップ、スワイプ |
| 最初 / 最後のページ | Home / End | ページスライダー、ページ一覧 |
| 読み方向 | ツールバー、`d`、⌘⇧D | ツールバー「コミック」 |
| ページ配置 (単ページ / 見開き / 縦スクロール) | ツールバー、「コミック」メニュー | ツールバー「コミック」 |
| 見開きを 1 ページずらす (1 ページ進む / 戻る) | ツールバー (見開き時)、Shift+← →、⌘⇧] / ⌘⇧[ | ツールバー「コミック」→「ページ配置」 |
| 拡大 | ⌘+ / ⌘- / ⌘0、ピンチ、ダブルクリック | ピンチ、ダブルタップ |
| 色の反転 / グレースケール / 背景 | ツールバー「画像」、⌘⇧I | ツールバー「コミック」 |
| ページ一覧 | ⌘T / `t` (サイドバー) | ツールバー「ページ一覧」 |

読書位置 (章とページ位置) と設定は `~/Library/Application Support/EbookViewer/` の `positions.json` `settings.json` に保存され
(サンドボックス内では `~/Library/Containers/com.sanpu-ya.EbookViewer/Data/Library/Application Support/EbookViewer/`)、
次回同じファイルを開くと復元されます。「最近開いたファイル」はセキュリティスコープ付きブックマークで保持するので、サンドボックス内でも再度開けます。

## ビルド

必要なもの: Xcode 15 以降 (macOS 14 SDK)。

1. `EbookViewer.Apple/EbookViewer.xcodeproj` を開く
2. 署名の Team を設定する (Signing & Capabilities)
3. 実行先に "My Mac" または iOS シミュレーター / 実機を選んで Run

macOS 版は App Sandbox + Hardened Runtime で動作します。WKWebView が独自スキームの本文を読み込むために
`com.apple.security.network.client` (Outgoing Connections) の権限が必要です。

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

## 構成

```
EbookViewer.Apple/
  EbookViewer.xcodeproj      Xcode プロジェクト (xcodegen で project.yml から生成)
  project.yml                XcodeGen 定義
  App/EbookViewer/           SwiftUI アプリ (macOS / iOS 共通ソース)
    EbookViewerApp.swift     App、メニューコマンド、Finder からのオープン
    ContentView.swift        画面全体 (Mac/iPad: サイドバー + 本文、iPhone: 本文 + 目次シート)
    ReaderModel.swift        画面状態と操作 (開いている本、章・ページ、設定の反映)
    ReaderModel+Text.swift   STLabel 表示用に本文をプレーンテキストにして渡す
    BookTextView.swift       STLabel のラッパー (ページ送り、キー・タップ・スワイプ操作)
    BookWebView.swift        WKWebView のラッパーと JS ブリッジ
    BookSchemeHandler.swift  ebook:// スキームで本文・画像・CSS を配信
    ReaderSettings.swift     設定・読書位置・最近開いたファイルの保存
    TocView.swift            目次パネル (コミックではページ一覧)
    ReaderModel+Comic.swift  コミックの状態と操作 (見開きの組み立て、ページ送り、設定)
    ComicReaderView.swift    コミックのページ表示 (単ページ / 見開き / 縦スクロール、ジェスチャー、キー操作)
    ComicThumbnailsView.swift サイドバーのサムネイル一覧
    ComicImageStore.swift    ページ画像のデコード (ImageIO で縮小) とキャッシュ・先読み
    PdfComicLoader.swift     PDF を PDFKit でページ画像にする
    Info.plist / *.entitlements / Assets.xcassets
  EbookCore/                 形式非依存のコア (Swift Package、Linux でもテスト可能)
    Sources/EbookCore/
      Model/                 BookDocument / SpineItem / TocEntry / BookResource / PathUtil
      Comic/                 ComicDocument / ComicPage と ComicLoader (CBZ / ZIP / CBR / RAR / フォルダー)
      Epub/                  ZipArchive (自前の ZIP 読み込み) と EpubLoader
      Mobi/                  PalmDB, MOBI ヘッダー/EXTH, INDX, PalmDOC/HUFF-CDIC 展開, KF7/KF8 ビルダー
      Rendering/             ContentPreparer (CSS/JS 注入)、PlainTextExtractor (プレーンテキスト化) と Resources/viewer.css, viewer.js
      Support/               XML 簡易 DOM (XMLNode)、zlib、SHA-1、CP1252、HTML 実体、正規表現ヘルパー
    Sources/StoneEngine/     stone_engine (STLabel) の取り込み + AppKit シム + ページ分割
    Tests/EbookCoreTests/    XCTest / Swift Testing (サンプル書籍は青空文庫『機械』横光利一、『奇巌城』ルブラン/菊池寛訳 (図版 4 枚))
    Tests/StoneEngineTests/  STLabel のページ分割と描画 (AppKit 移植の確認)
design/icons/                アプリアイコンの SVG 原稿 (採用: 01_open-book.svg)
```

XML は `XMLParser` で組み立てる軽量 DOM (`XMLNode`) で扱います (iOS には `XMLDocument` が無いため)。
ZIP は自前の `ZipArchive` と zlib で読みます (Linux では zlib を直接リンクし、Apple では Compression framework を使います)。

## テストで確認していること

- EPUB (calibre 製横組み / AozoraConv 製縦書き / EPUB3 縦書き・複数ファイル・挿絵入り) のメタデータ、spine、目次、画像参照の解決
- ハイブリッド MOBI の KF8 部と旧形式 (KF7) 部の両方、および単独 AZW3 の本文再構成、目次ラベル (CNCX)、`kindle:embed` / `recindex` 画像参照、表紙
- ビューアー資産の注入 (script の除去、文字コード、XHTML 判定)
- プレーンテキスト化 (ブロック要素の改行、ルビ、画像、文字参照、CRLF、全角文字に挟まれた改行、アンカー位置)
- STLabel のページ分割 (縦書き / 横書きの 1 ページの行数、総ページ数、文字位置からのページ算出) と、実際にグリフが描かれること
- CBZ / フォルダーの画像列挙と自然順ソート、ComicInfo.xml の解釈
- ローカライズ文字列 (英語 / 日本語) の対応

## トラブルシューティング

ファイルを開けなかったときなどのエラーは Application Support/EbookViewer/ の `error.log` に追記されます。
動作解析用のトレース (ナビゲーションやリソース要求の時刻) は同じフォルダーの `trace.log` に記録されます。

本文を表示する WebKit のプロセスが繰り返し終了する場合は、macOS 版の App Sandbox に
`com.apple.security.network.client` の権限があるか Xcode の Signing & Capabilities で確認してください。

本文に画像・ルビ・強調が出ない場合は、本文エンジンが stone_engine になっています。
「表示」メニュー (⌘⇧E) で WebView に切り替えてください。

## 利用しているソフトウェア

- [stone_engine](https://github.com/sanpu-ya/stone_engine) (MIT License, Copyright (c) 2024 Nihon Design Center) —
  日本語組版エンジン。`STLabel` の表示に必要な部分を
  [`EbookCore/Sources/StoneEngine/`](EbookViewer.Apple/EbookCore/Sources/StoneEngine/) に取り込んでいます
- [Unrar.swift](https://github.com/mtgto/Unrar.swift) — CBR (RAR) の展開。SwiftPM の依存として取得します
