# StoneEngine (stone_engine の取り込み)

本文の組版に使っている [stone_engine](https://github.com/sanpu-ya/stone_engine) (MIT License,
Copyright (c) 2024 Nihon Design Center) のうち、`STLabel` の表示に必要な部分だけを取り込んだものです。

- 取り込み元: `https://github.com/sanpu-ya/stone_engine`
- コミット: `f8b2dc5d64c2022bc730275d287124561b406fef` (2025-04-23)
- ライセンス: [LICENSE](LICENSE) (MIT)

upstream をそのまま SwiftPM の依存として使えないのは、stone_engine が全ファイルで `import UIKit` して
いて **iOS 専用**だからです。EbookViewer は macOS 14 以降と iOS 17 以降の 1 ターゲット構成なので、
AppKit でもビルドできるようにソースを取り込み、最小限の変更を加えています。

## ファイル

| ファイル | 由来 |
|---|---|
| `Upstream/STContext.swift` `STObject.swift` `STFontManager.swift` `STTextSubstitutionGlyph.swift` `STLayout.swift` `STParser.swift` | upstream のまま (import 行のみ変更) |
| `Upstream/STLabel.swift` | upstream に変更あり (下記) |
| `STPlatform.swift` | EbookViewer で追加 (UIKit / AppKit の差を埋めるシム) |
| `STRuby.swift` | EbookViewer で追加 (ルビ) |

編集機能のクラス (`STTextView` 一式・`STText`・`STCursorView`・`STKnobView`・`STLensView`・`STTiledLayer`) は
本文表示に使わないので取り込んでいません。

## upstream からの変更点

### 全ファイル

`import UIKit` を次の形に変えています (`STTextSubstitutionGlyph.swift` は元から両対応)。

```swift
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
```

macOS では `STPlatform.swift` が `UIColor` → `NSColor` の typealias、`UIColor.label` などの
semantic color、`UIGraphicsGetCurrentContext()` を用意するので、これらを使っている箇所は無変更で通ります。

### STLabel.swift

1. **基底クラス** を `UIView` から `STPlatformView` にしました。`STPlatformView` は iOS では `UIView`
   そのもの、macOS では `NSView` に `isFlipped = true` (stone_engine は y 軸下向きで組版する)、
   `backgroundColor`、`setNeedsLayout()`、`setNeedsDisplay()`、`layoutSubviews()`、`sizeThatFits(_:)` を
   足したものです。
2. **`CATiledLayer` (`STTiledLayer`) を使わない**ようにしました。本文は 1 ページ = 1 画面ぶんしか描かないので
   タイル分割の利点がなく、`NSView` では背景スレッドからの描画になって扱いが面倒になるためです。
   `layerClass` の override と `layoutSublayers(of:)` (`#if ALIGN_LAYER` で無効化されていたもの) を外しました。
3. **編集機能の描画を外しました**。`textInput` プロパティと、選択範囲 (`drawSelectedArea`)・未確定文字列
   (`drawMarkedArea`)・`uniteRunRects` を削除しています。これらは `STTextView` と組み合わせたときだけ
   使われるもので、取り込んでいないクラスを参照していました。
4. **ページ分割を足しました** (`isPaged` / `pageIndex` / `pageCount` / `linesPerPage` /
   `page(ofCharacterAt:)`)。`isPaged` が false なら upstream と同じ挙動です。詳細は下記。
5. **同じ条件なら組み直さない**ようにしました。`layoutSubviews()` で組版結果を左右する条件
   (`LayoutSignature`) を比べ、変わっていなければ `STParser` / `STLayout` を呼び直しません。
   ページを送るたびに章全体を組み直さないためです。
6. **ルビを足しました** (`rubyAnnotations` / `rubyFontScale` / `rubyExtent`)。詳細は下記。
7. **強調表示を足しました** (`styleAnnotations` / `emphasisAnnotations`)。詳細は下記。
8. **字間を足しました**。`STContext.spacings` に run ごとの前後の空きを入れると、`STLayout` が
   その空きを含めて文字を送るようにしました (`layoutRunLrTb` / `layoutRunTbRl` の 3 か所と、
   次の語が入るかを見る `STContext.advance(token:)`)。ルビのほうが長い親文字を広げるのに使います。

## ページ分割のしくみ

`STLayout` は `renderSize` の **inline 方向** (縦書きなら高さ) で行を折り返しますが、**block 方向**
(縦書きなら幅) は打ち切らず、行を右から左へ (横書きなら上から下へ) 積み続けます。`renderSize` に
収まらない行の run は `visibility = .invisible` (境目は `.ellipsis`) になるだけです。

そこで `isPaged = true` のときは次のようにしています。

- 1 ページの行数 `linesPerPage` = block 方向の長さ ÷ 行送り
- `pageCount` = `context.lineCount` ÷ `linesPerPage` (切り上げ)
- 描画時は `visibility` を見ずに、`pageIndex` のページに属する行の run だけを選び、block 方向へ
  `行送り × linesPerPage × pageIndex` ずらして描く

組版は 1 回だけで、ページ送りは描画位置をずらすだけなので、ページ境界で行が割れたり送るたびに
組み直しが起きたりすることがありません。`STParser` は 1 文字 = 1 run で解析するので run の添字が
そのまま文字位置になり、`page(ofCharacterAt:)` で「本文の n 文字目は何ページ目か」が分かります
(目次のリンク先へのページ送りに使っています)。

## ルビのしくみ

`STLabel.rubyAnnotations` に「親文字の範囲 (text の Character 単位) とルビ」の組を渡すと、
縦書きなら親文字の右、横書きなら上にルビを置きます (`STRuby.swift`)。

- **行間に置く**ので、行分割・禁則処理・1 行の文字数には影響しません。そのかわり行送りが
  親文字 + ルビぶんないと隣の行とぶつかります (`lineHeightScale` ≥ 1 + `rubyFontScale`、
  既定の 1.9 と 0.5 なら余裕があります)。
- **1 行目のルビが切れない**よう、ルビがあるときは本文全体をルビの幅だけずらし、
  1 ページに入る行数 (`linesPerPage`) もその幅を引いて数えます (`rubyExtent`)。
- **ルビ自体の組版は stone_engine に任せます**。親文字と同じフォント・同じ組方向で文字を
  小さくしただけの `STContext` を作り、`STParser` / `STLayout` に 1 行として組ませてから、
  親文字の中央にそろう位置へ平行移動しています。こうすると縦書き用グリフへの差し替えや
  欧文の回転がそのまま効き、グリフまわりの処理を書き直さずに済みます。
- **親文字が行をまたぐとき**は、親文字を行ごとに分け、ルビも親文字の文字数に比例して
  分けて付けます。
- **ルビのほうが長いときは、親文字を広げて**ルビの長さに合わせます (下記)。
- **二段ルビ**は `STRubyAnnotation.position` で置く側を選びます。`.over` が親文字の上
  (縦書きでは右)、`.under` が下 (縦書きでは左) です。両側にルビがあるときは、行の両脇に
  ルビぶんの空きを取り分けます。

### 画像

stone_engine は文字しか組まないので、画像は本文に置いた 1 文字 (全角空白) を目印にして、
その上に描きます (`STImage.swift`)。

- **行の中に収める画像** (外字など) は、行に直交する向きを 1 文字ぶんに合わせ、文字が進む向きは
  画像の形に合わせて `STContext.spacings` で置き場所の 1 文字を伸ばし縮みさせます。
- **挿絵** (段落に 1 つだけ置かれた画像) は 1 ページを使って表示します。そのため、ページを
  「行を `linesPerPage` ずつ区切ったもの」から**ページの並び** (`pages`) に変えました。
  挿絵が載っている行はそこで本文のページを区切り、その 1 ページを挿絵に使います。

## 罫囲み

罫囲み (`boxAnnotations`) は、囲む文字の枠をまとめた矩形に少し余白を足して、`draw(_:)` で
罫を引きます。何行にもわたる罫囲みは、その範囲全体を 1 つの枠で囲みます (CSS の border と同じ)。
罫は文字の両側へ出るので、行の両脇に罫のぶんの空きを取り分けます。

## 割り注

割り注は、本文 1 行ぶんの幅の中に半分の大きさの文字を 2 行に組んだものです (`warichuRanges`)。
1 行の中に入れ子の行ができるので、`STLayout` には手を入れず、組んだあとに位置を組み替えます
(`STWarichu.swift`)。

1. まず半分の大きさで 1 行に組ませる (ふつうの組版)
2. 2 行に積んだときに要る長さまで字間を詰めて組み直す (親文字を広げるときと同じ
   `STContext.spacings` のしくみ。詰める量は 1 の結果から求める)
3. 前半を 1 行目、後半を 2 行目として位置を組み替える (縦書きは 1 行目が右、横書きは上)

行をまたいだ割り注は、積み直すと読み順が崩れるので 3 を行いません。

## 字下げ・地付き

行の始まり (と終わり) に空きを作れるようにしました (`indentAnnotations`)。

- `STContext.indents` に**文字ごと**の字下げを持たせ、`STLayout` が行を始めるとき
  (`layout()` の冒頭と `goNextLine*`) に、その行の 1 文字目の字下げぶんだけ内側から始めます。
  文字ごとに持つので、ブロック全体に同じ値を入れておけば**折り返した行も同じ位置**から始まります。
- 地付き・地寄せは `STContext.trailingGaps` に持たせ、行揃え (`alignText*`) でその行を行末へ
  寄せます。折り返しの判定も、行末に空けるぶんを引いた長さで見ます。
- 「折り返して N 字下げ」は `STContext.hangingIndents` に持たせます。`STLayout` が行を始めるとき、
  改行で始まる行なら `indents`、折り返して始まる行なら `hangingIndents` を使います
  (どちらで行が終わったかは、行末の文字が改行かどうかで分かります)。

## 文字の大きさ

upstream は 1 つの文字サイズで組みますが、文字ごとに大きさを変えられるようにしました
(`sizeAnnotations`)。

- `STContext.sizeScales` (文字ごとの倍率) を見て、`STParser` がその大きさでグリフと字幅を取り、
  `STRun.fontSize` に持たせます。`STLayout` の**文字まわりの計算だけ**を `context.adjustFontSize`
  から `run.fontSize` に替えました (折り返しの先読み、約物の詰め、縦中横の中央ぞろえを含む)。
- **行送りは変えていません**。変えると `firstRunFrame(line:)` やページ送りの計算など、行が
  等間隔であることを前提にした箇所をすべて作り直すことになるためです。そのかわり、行送りを
  超える大きさにはしないので隣の行とぶつかりません (`STContext.maxSizeScale`)。
- 縦書きでは、小さい文字を 1 文字ぶんの枠の中央にそろえます。

## 強調表示

太字・斜体は**文字ごとにフォントを差し替えて**表します (`STStyle.swift`)。

- `STLabel.styleAnnotations` に範囲と字面 (`.bold` / `.italic`) を渡すと、組む前に
  `STContext.styles` (文字ごとの字面) に展開され、`STParser` がその字面のフォントで
  グリフと字幅を取ります。字幅が変わるので**行分割にも反映されます**。
- フォントは `CTFontCreateCopyWithSymbolicTraits` で作ります。Hiragino なら W3 → W6 に
  なります。日本語フォントには斜体が無いので、斜体を指定しても正体のままになります。
- 描画は字面ごとにまとめます (`DrawBucket` の種別に字面を足しました)。

傍線 (`lineAnnotations`) は字面を変えないので、フォントは差し替えずに `draw(_:)` で線を引きます
(`STLine.swift`)。続いている文字をまとめて 1 本にし、行が変わるところで切ります。

- 種類は実線・二重線・鎖線・破線・波線 (青空文庫の傍線の種類)。点線と破線は `setLineDash`、
  波線は二次ベジエの山を並べて描きます。
- 引く側は `underline` (縦書きなら右・横書きなら下。WebKit が縦組みで引く側に合わせています)、
  `overline` (その反対 = 左傍線)、`strikethrough` (文字の中央) の 3 つ。線のぶんの空きも
  行の脇に取り分けます。

縦中横 (`tateChuYokoRanges`) は、`STContext.forcedTateChuYoko` に入れた run を
`isTateChuYoko(run:)` が数字でなくても縦中横として扱うようにしたものです。stone_engine は
字を詰めないので、1 文字ぶんの 1.5 倍に収まらないまとまりは横に並べません。

圏点 (傍点) は字面を変えずに文字の脇へ印を打つものなので、**ルビと同じしくみに載せています**。
`STLabel.emphasisAnnotations` に範囲を渡すと、1 文字ずつの注記 (印は `﹅` など) に展開されて
ルビと同じ経路で組まれます。同じ文字にルビがあるときは、CSS の `text-emphasis` と同じく
圏点を反対側へ逃がします。

## ルビの掛けと、親文字の広げ方

「承 (うけたまわ)」のようにルビが親文字より長いとき、まず**隣の文字へ掛け** (ルビの掛け)、
それでも収まらないぶんだけ**親文字の字間を広げ**ます。どちらも JIS X 4051 に倣っています。

掛けてよい条件:

- 隣が**仮名**のときだけ掛ける (漢字・欧文には掛けない)
- 片側につき**ルビ 1 文字ぶん**まで
- 隣にもルビや圏点が付いていたら掛けない
- 行の境を越えて掛けない

`allowsRubyOverhang` を false にすると掛けをやめ、はみ出すぶんをすべて親文字を広げて収めます。

広げるときの空きは、親文字の外側が内側の半分になるように配ります
(N 文字なら 0.5 : 1 : … : 1 : 0.5 ─ 1 文字あたり前後に `余り / 2N` ずつ入れるとこうなります)。

親文字を広げると 1 行に入る文字数が変わるので、`STContext.spacings` に字間を入れて
`STLayout` に組み直させます。組版はこうして 2 回に分かれます。

1. 親文字をふつうに組む
2. ルビを組み、1 の結果と比べて掛ける量と広げる量を決める
3. 広げる親文字があれば、字間を入れて組み直す
4. 掛ける量を組み直したあとの行割りで取り直し、ルビの置き場所を決める

ルビは 2 で 1 度だけ組み、4 では位置をずらすだけです (行をまたぐときは文字数で切り分けます)。
掛ける量を 4 でも求め直すのは、広げたことで行が変わっても置き場所がずれないようにするためです。
2 万字・ルビ 500 箇所の章で、1 章を組むのにかかる時間は Release ビルドで 71ms → 98ms でした。
