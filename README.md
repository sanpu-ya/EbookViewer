# EbookViewer

EPUB / MOBI / AZW3 に対応した、縦書き日本語対応の電子書籍ビューアーです。
C# / .NET 10 / WinUI 3 (Windows App SDK 1.8) で作られています。

## 対応形式

| 形式 | 拡張子 | 備考 |
|---|---|---|
| EPUB 2 / 3 | `.epub` | nav.xhtml / NCX 目次、IDPF・Adobe 方式のフォント難読化解除に対応 |
| KF8 | `.azw3` `.kf8` | スケルトン／フラグメント索引から XHTML を再構成。`kindle:pos:fid` / `kindle:embed` / `kindle:flow` を解決 |
| ハイブリッド MOBI | `.mobi` | KF8 部があればそちらを優先。無ければ旧形式 (KF7) として読む |
| 旧形式 MOBI | `.mobi` `.prc` `.azw` | `filepos` / `recindex` / `mbp:pagebreak` を変換 |

PalmDOC 圧縮・HUFF/CDIC 圧縮の両方を展開できます。DRM 付きのファイルは開けません (エラーになります)。

## 縦書き表示のしくみ

本文は WebView2 (Chromium) で描画します。本文ドキュメントに `viewer.css` / `viewer.js` を注入し、
`body` を `writing-mode: vertical-rl` の多段組みコンテナ (`column-width` = 表示領域の高さ) にすることで、
1 段 = 1 ページとして行が途中で切れないページ分割を行っています。縦書きではページが縦方向に積まれるため
縦スクロール、横書きでは横スクロールでページを送ります。

組方向は「自動 → 縦書き → 横書き」の順で切り替えられます。「自動」では、書籍側の宣言
(`page-progression-direction="rtl"`、`primary-writing-mode`、CSS の `writing-mode: vertical-*`、
KF8 の EXTH 525/527) を優先し、宣言が無ければ日本語の本を縦書きにします。

## 操作

| 操作 | キー・マウス |
|---|---|
| ファイルを開く | Ctrl+O、ウィンドウへドロップ |
| 目次パネル | Ctrl+T (本文フォーカス時は `t`)、Esc で閉じる |
| 次のページ | ← (縦書き) / → (横書き)、PageDown、Space、↓、ホイール下、画面左端 (縦書き) クリック |
| 前のページ | → (縦書き) / ← (横書き)、PageUp、Shift+Space、↑、ホイール上、画面右端 (縦書き) クリック |
| 章の先頭／末尾 | Home / End |
| 文字サイズ | Ctrl + `+` / `-` |
| テーマ・フォント・行間・余白 | ツールバー「表示」 |

読書位置 (章とページ位置) と設定は `%LOCALAPPDATA%\EbookViewer\` に保存され、次回同じファイルを開くと復元されます。

## ビルド

必要なもの: .NET 10 SDK、Windows 10 SDK (10.0.19041 以降)、Microsoft Edge WebView2 ランタイム (Windows 10/11 には通常インストール済み)。

```bash
dotnet build EbookViewer.App/EbookViewer.App.csproj -c Release
```

出力: `EbookViewer.App/bin/Release/net10.0-windows10.0.22621.0/win-x64/EbookViewer.exe`
(`-p:Platform=x64` を付けた場合は `bin/x64/Release/...`)。未パッケージ・Windows App SDK 自己完結なので、そのまま実行できます。
ファイルパスを引数に渡すと起動時に開きます。

テスト:

```bash
dotnet test EbookViewer.Tests/EbookViewer.Tests.csproj
```

## 構成

```
EbookViewer.Core/          形式非依存の書籍モデルと各ローダー (net10.0 クラスライブラリ)
  Model/                   BookDocument / SpineItem / TocEntry / BookResource
  Epub/EpubLoader.cs       EPUB (container.xml → OPF → nav/NCX)
  Mobi/                    PalmDB, MOBI ヘッダー/EXTH, INDX, PalmDOC/HUFF-CDIC 展開, KF7/KF8 ビルダー
  Rendering/               本文への CSS/JS 注入 (ContentPreparer) と viewer.css / viewer.js
EbookViewer.App/           WinUI 3 アプリ (WebView2 に仮想ホストで本文を配信)。Assets/app.ico がアプリアイコン
design/icons/              アプリアイコンの SVG 原稿 (採用: 01_open-book.svg) と生成した app.ico
EbookViewer.Tests/         xunit テスト (サンプル書籍は青空文庫『機械』横光利一、『奇巌城』ルブラン/菊池寛訳 (図版 4 枚))
```

## テストで確認していること

- EPUB (calibre 製横組み / AozoraConv 製縦書き / EPUB3 縦書き・複数ファイル・挿絵入り) のメタデータ、spine、目次、画像参照の解決
- ハイブリッド MOBI の KF8 部と旧形式 (KF7) 部の両方、および単独 AZW3 の本文再構成、目次ラベル (CNCX)、`kindle:embed` / `recindex` 画像参照、表紙
- ビューアー資産の注入 (script の除去、文字コード、XHTML 判定)

実機では、青空文庫『雪華図説の研究』(図版 23 枚) や『博物誌』(挿絵 69 枚) などで、縦書きページ内の画像配置、
章をまたぐ連続ページ送り、目次ジャンプ、横書き切替、文字サイズ変更、読書位置の復元を確認しています。

## トラブルシューティング

環境変数 `EBOOKVIEWER_TRACE=1` を付けて起動すると、`%LOCALAPPDATA%\EbookViewer\trace.log` に
ナビゲーションやリソース要求の時刻が記録されます。未処理例外は同じフォルダーの `error.log` に残ります。

本文は仮想ホスト `https://book.ebookviewer.invalid/` で配信しています。`.local` のようなホスト名は mDNS の
名前解決待ちでページ表示が約 2 秒遅れるため使っていません (ブラウザー引数 `--host-resolver-rules` で即時解決させています)。
