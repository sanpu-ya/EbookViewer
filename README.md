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

| エンジン | 組版 | ルビ | 強調 | 画像 | 既定 |
|---|---|---|---|---|---|
| stone_engine | [stone_engine](https://github.com/sanpu-ya/stone_engine) の `STLabel` (禁則処理・約物半角・縦中横・文字種ごとのフォント) | 表示する | 圏点・太字・斜体・下線 | 表示する | ○ |
| WebView | WKWebView + CSS の多段組み | 表示する | 本文の CSS に従う | 表示する | |

組方向は「自動 → 縦書き → 横書き」の順で切り替えられます (どちらのエンジンでも同じ)。「自動」では、書籍側の宣言
(`page-progression-direction="rtl"`、`primary-writing-mode`、CSS の `writing-mode: vertical-*`、
KF8 の EXTH 525/527) を優先し、宣言が無ければ日本語の本を縦書きにします。

### stone_engine (既定)

日本語組版エンジン [stone_engine](https://github.com/sanpu-ya/stone_engine) の `STLabel` で本文を描きます。
`STLabel` は UIKit 専用なので、macOS でも使えるようソースを
[`EbookCore/Sources/StoneEngine/`](EbookViewer.Apple/EbookCore/Sources/StoneEngine/) に取り込み、AppKit 向けのシムと
ページ分割を足しています (変更点は [同ディレクトリーの README](EbookViewer.Apple/EbookCore/Sources/StoneEngine/README.md))。

`STLabel` は文字列しか受け取らないので、本文ドキュメントは `PlainTextExtractor` でプレーンテキストに変換します。
ブロック要素の境目を改行にし (見出し・表・水平線の前後は空行)、全角文字に挟まれた原文の改行は、CSS の
segment break transformation rules と同じく空白にせず詰めます。`id` / `name` 属性の位置も覚えておき、
目次のリンク先 (`#fragment`) から表示ページを求めるのに使います。

ページ分割は、章全体を 1 回だけ組んでから行を block 方向 (縦書きなら右から左) に区切って行います。
ページを送るときは描画位置をずらすだけなので、組み直しは起きません。

ルビ (`<ruby>` / `<rt>`) は親文字の位置とともに取り出し、`STLabel` に渡して縦書きなら親文字の右、
横書きなら上の行間に組みます。「承 (うけたまわ)」のようにルビのほうが長いときは、まず隣の仮名へ
掛け (JIS X 4051 のルビの掛け。掛けるのは隣が仮名のときだけ、ルビ 1 文字ぶんまで)、それでも
収まらないぶんだけ親文字の字間を広げて長さをそろえます (外側の空きは内側の半分)。
親文字が行をまたぐときはルビも分けて付けます。二段ルビ (`<rtc>`) は 2 段目を親文字の反対側 — 縦書きなら左、横書きなら下 —
に置きます (しくみは [StoneEngine の README](EbookViewer.Apple/EbookCore/Sources/StoneEngine/README.md))。

強調は次のように割り当てます。日本語には斜体が無いので、`<em>` / `<i>` は圏点 (傍点) にします。

| 本文 | 表示 |
|---|---|
| `<strong>` `<b>` | 太字 (Hiragino なら W6) |
| `<em>` `<i>` で全角文字を含む範囲 | 圏点 (ゴマ点) |
| `<em>` `<i>` で欧文だけの範囲 | 斜体 |
| `<u>` `<ins>` | 傍線 |
| `<s>` `<strike>` `<del>` | 取り消し線 |

[青空文庫の注記](https://www.aozora.gr.jp/annotation/)から変換された本文は、class でも読み取ります。

| class | 表示 |
|---|---|
| `futoji` / `shatai` | 太字 / 斜体 |
| `sesame_dot` `white_sesame_dot` `black_circle` `white_circle` `black_up-pointing_triangle` `white_up-pointing_triangle` `bullseye` `fisheye` `saltire` | 傍点 (ゴマ点 ﹅ 白ゴマ ﹆ 黒丸 ● 白丸 ○ 黒三角 ▲ 白三角 △ 二重丸 ◎ 蛇の目 ◉ ばつ ×) |
| 上記 + `_after` | 左に傍点 (縦書きでは左、横書きでは下) |
| `underline_solid` `_double` `_dotted` `_dashed` `_wave` | 傍線・二重傍線・鎖線・破線・波線 |
| `overline_*` | 左傍線 (同じ 5 種) |
| `strike` / `dbl_strike` | 取り消し線 / 二重取り消し線 |
| `tcy` | 縦中横 |
| `dai1`〜`dai5` / `sho1`〜`sho5` | 大きな文字 / 小さな文字 (1 段階ごとに 1.2 倍 / 0.9 倍) |
| `font1`〜`font6` / `font-1`〜`font-6` | 110%〜160% / 90%〜62% |
| `o-midashi` `naka-midashi` `ko-midashi` (`chap1`〜`chap3`) | 大見出し 140% / 中見出し 120% / 小見出し 110% |
| `notes` `caption` `kaeriten` `okurigana` `superscript` `subscript` `warichu` | 小さめ (83%) |
| `jisage_3` (`jisage`) | 3 字下げ (ブロック全体。折り返した行も同じ位置から始まる) |
| `chitsuki_0` / `chitsuki_2` | 地付き / 地から 2 字上げ |
| `warichu` | 割り注 (本文 1 行ぶんの幅に、半分の大きさで 2 行に組む) |
| `keigakomi` / `border` / `dashed_border` | 罫囲み (実線 / 実線 / 破線) |

`<h1>`〜`<h6>` と `style="font-size: 140%"` (`1.4em` も) からも大きさを読みます。字下げは
`style="margin-left: 3em"` (縦書きの `margin-right`、`text-indent` も) から読みます。
`style` の指定は class より優先します。

圏点はルビと同じ行間に置きます。同じ文字にルビもあるときは、CSS の `text-emphasis` と同じく
圏点を反対側へ逃がします。傍線を引く側 (縦書きでは右、横書きでは下) は WebKit が縦組みで引く側に
合わせてあり、WebView 表示と見た目がそろいます。

2 桁の数字は注記が無くてもエンジンが自動で縦中横にします。`tcy` の指定は、1 文字ぶんに収まる
長さのときだけ従います (stone_engine は字を詰めないので、長いまとまりを横に並べると隣の行に
はみ出すため)。

文字の大きさを変えても**行送りは変わりません**。隣の行とぶつからないよう、行送り
(「表示」→「行間」の倍率、既定 1.9) を超える大きさにはしません。小さな文字は行の中央にそろえます。

割り注が 1 行に収まらないとき (行をまたぐとき) は、積み直すと読み順が崩れるので、半分の
大きさのまま 1 行に流します。

罫囲みは、囲む文字をまとめて 1 つの矩形で囲みます (何行にもわたる罫囲みは、その範囲全体を
1 つの枠で囲みます)。

**まだ対応していない注記**: 凹凸の複雑な字下げ (「折り返して N 字下げ」。折り返した行も 1 行目と
同じ位置から始まります)、上付き・下付きの位置 (大きさだけ変えます)、横組み (縦組み中の横組み)。
いずれも 1 行の中での入れ子や、行ごとに違う字下げが必要で、stone_engine が 1 本の流れとして
組む作りになっているためです。これらが必要なときは WebView 表示に切り替えてください。

画像 (`<img>`) は本文に置き場所を 1 文字だけ残して取り出し、ImageIO でデコードして描きます。
段落に 1 つだけ置かれた挿絵は 1 ページを使って表示し、本文に挟まれた小さな画像 (外字など) は
行の中に収めます。読めなかった画像のところは空白になります。

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
    Sources/StoneEngine/     stone_engine (STLabel) の取り込み + AppKit シム + ページ分割 + ルビ
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
- プレーンテキスト化 (ブロック要素の改行、文字参照、CRLF、全角文字に挟まれた改行、アンカー位置)
- 画像の取り出し (置き場所、挿絵と行内の画像の見分け、SVG の参照、src の無い画像)
- ルビの取り出し (親文字との対応、`<rb>` で区切られた形、二段ルビ `<rtc>` の対応付け、`<rp>` の除去、本文中の位置)
- 強調の取り出し (太字・斜体・圏点・傍線の振り分け、青空文庫の注記クラス 9 種の傍点と 5 種の線、左傍点・左傍線、縦中横、入れ子、本文中の位置)
- 文字サイズの取り出し (青空文庫の段階つきクラス、見出し、インライン style の % と em)
- 字下げ・地付き・割り注・罫囲みの取り出し (`jisage_N` / `chitsuki_N` / `warichu` / `keigakomi`、margin の style、ブロック全体にかかること)
- STLabel のページ分割 (縦書き / 横書きの 1 ページの行数、総ページ数、文字位置からのページ算出) と、実際にグリフが描かれること
- STLabel のルビ (縦書きなら親文字の右・横書きなら上に付くこと、中央そろえ、行またぎの分割、行からはみ出さないこと、ページ追従)
- ルビに合わせた親文字の広げ方 (広げる量、広げないケース、後続の文字のずれ、広げたぶんを含めた行分割)
- 二段ルビ (縦横それぞれで反対側に付くこと、両側ぶんの空きの確保、長いほうに合わせた親文字の広げ方)
- ルビの掛け (隣の仮名へ掛かること、漢字・他のルビ・行の境には掛けないこと、掛けたぶん親文字を広げずに済むこと)
- 強調表示 (太字で別の字面が使われること、字幅が変わって行分割に反映されること、重ねがけ、圏点が 1 文字ずつ中央に打たれること)
- 傍線 (縦横それぞれで引かれる側と長さ、5 種の線の描き分け、左傍線・取り消し線、行ごとに切れること、はみ出さないための空きの確保)
- 縦中横 (横に並ぶこと、行が短くなること、長すぎるまとまりはそのままにすること)
- 文字サイズ (大小が字送りと行分割に反映されること、小さな文字が行の中央に来ること、行送りで頭打ちになること)
- 字下げ・地付き (折り返した行も同じ位置から始まること、指定した範囲だけに効くこと、地付き・地寄せの位置、地寄せで早く折り返すこと)
- 割り注 (2 行に積まれること、本文 1 文字ぶんの幅に収まること、字送りが半分で済むこと、奇数なら 1 行目が 1 文字多いこと、行をまたぐときは積まないこと)
- 罫囲み (文字より外側に罫が出ること、囲んでいない文字には出ないこと、両側に空きを取ること、罫の種類の描き分け)
- 画像 (挿絵が 1 ページを占めること、縦横比を保って収まること、行内の画像が字送りに反映されること)
- CBZ / フォルダーの画像列挙と自然順ソート、ComicInfo.xml の解釈
- ローカライズ文字列 (英語 / 日本語) の対応

## トラブルシューティング

ファイルを開けなかったときなどのエラーは Application Support/EbookViewer/ の `error.log` に追記されます。
動作解析用のトレース (ナビゲーションやリソース要求の時刻) は同じフォルダーの `trace.log` に記録されます。

本文を表示する WebKit のプロセスが繰り返し終了する場合は、macOS 版の App Sandbox に
`com.apple.security.network.client` の権限があるか Xcode の Signing & Capabilities で確認してください。

ルビが隣の行と重なる場合は、行間が狭すぎます。「表示」メニューの「行間」を「標準」以上にしてください。

## 利用しているソフトウェア

- [stone_engine](https://github.com/sanpu-ya/stone_engine) (MIT License, Copyright (c) 2024 Nihon Design Center) —
  日本語組版エンジン。`STLabel` の表示に必要な部分を
  [`EbookCore/Sources/StoneEngine/`](EbookViewer.Apple/EbookCore/Sources/StoneEngine/) に取り込んでいます
- [Unrar.swift](https://github.com/mtgto/Unrar.swift) — CBR (RAR) の展開。SwiftPM の依存として取得します
