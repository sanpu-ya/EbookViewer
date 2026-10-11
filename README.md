# EbookViewer

EPUB / MOBI / AZW3 とコミック (CBZ / CBR / PDF / 画像フォルダー) に対応した、縦書き日本語対応の電子書籍ビューアーです。
Swift / SwiftUI で作られており、1 つのマルチプラットフォーム App ターゲットで macOS 14 以降と iOS / iPadOS 17 以降に対応します。

## 対応形式

- 電子書籍: EPUB 2 / 3 (`.epub`)、KF8 (`.azw3` `.kf8`)、MOBI (`.mobi` `.prc` `.azw`)。DRM 付きのファイルは開けません
- コミック: `.cbz` / `.zip`、`.cbr` / `.rar`、`.pdf`、画像フォルダー。ComicInfo.xml があれば読み取ります

## ドキュメント

- [操作と画面](docs/ui.md) — キー割り当て、表示の設定、コミックの操作、設定と読書位置の保存先
- [実装のしくみ](docs/implementation.md) — 対応形式の詳細、縦書き組版と注記の対応、ソース構成、テストで確認していること

## ビルド

必要なもの: Xcode 15 以降 (macOS 14 SDK)。

1. `EbookViewer.Apple/EbookViewer.xcodeproj` を開く
2. 署名の Team を設定する (Signing & Capabilities)
3. 実行先に "My Mac" または iOS シミュレーター / 実機を選んで Run

macOS 版は App Sandbox + Hardened Runtime で動作し、WKWebView が独自スキームの本文を読み込むために `com.apple.security.network.client` (Outgoing Connections) の権限が必要です。

`project.yml` を変更したら [XcodeGen](https://github.com/yonaskolb/XcodeGen) で再生成します:

```bash
brew install xcodegen
cd EbookViewer.Apple && xcodegen generate
```

コアのテストは Xcode 不要で macOS / Linux から実行できます (Xcode なら `EbookCore` フォルダーを開く):

```bash
cd EbookViewer.Apple/EbookCore && swift test
```

## トラブルシューティング

エラーは Application Support/EbookViewer/ の `error.log` に、動作解析用のトレースは `trace.log` に記録されます。
本文を表示する WebKit のプロセスが繰り返し終了する場合は、`com.apple.security.network.client` の権限を確認してください。
ルビが隣の行と重なる場合は行間が狭すぎます。「表示」メニューの「行間」を「標準」以上にしてください。

## ライセンス

MIT License です ([LICENSE](LICENSE))。利用しているソフトウェアは次のとおりです。

- [stone_engine](https://github.com/sanpu-ya/stone_engine) (MIT License, Copyright (c) 2024 Nihon Design Center) — 日本語組版エンジン。本文の組版に使い、必要な部分を [`EbookCore/Sources/StoneEngine/`](EbookViewer.Apple/EbookCore/Sources/StoneEngine/) に取り込んでいます
- [Unrar.swift](https://github.com/mtgto/Unrar.swift) (MIT License, Copyright (c) 2021 mtgto) — CBR (RAR) の展開。SwiftPM の依存として取得します。同梱の unrar 自体は UnRAR ライセンス (フリーウェア。RAR 圧縮アルゴリズムの再現には使えません) です
