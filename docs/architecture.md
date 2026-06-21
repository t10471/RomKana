# RomKana アーキテクチャ

ローマ字を文脈つきでかな漢字に変換する、**完全ローカル**の macOS 入力メソッド（IME）。この文書は現行構成・データの流れ・設計判断をまとめたリファレンス。経緯・なぜそうしたかは [`development-journey.md`](./development-journey.md) を参照。

> 旧構成（mozcpy + LLM スコアリングの Python 2プロセス）は [`architecture-legacy.md`](./architecture-legacy.md) に分離しています。2026-06-21 に AzooKey + Zenzai へ移行し、Python サービスを撤去しました。

---

## 1. 全体像

**単一プロセス構成**。入力も変換も RomKana.app の中で完結する。外部サービス・ネットワーク往復は無い。

```
┌──────────────────────────────────────────────────┐
│ 任意の macOS アプリ（入力先のテキストフィールド）    │
└───────────────────▲──────────────────────────────┘
                    │ InputMethodKit
                    │ （preedit 表示 / 確定 insert / 候補ウィンドウ）
┌───────────────────┴──────────────────────────────┐
│ RomKana.app   — Swift + InputMethodKit            │
│                                                    │
│   RomajiConverter        ローマ字 → かな（即時）   │
│        │                                           │
│        ▼                                           │
│   KanaKanjiConverter      かな → 漢字              │
│   （AzooKeyKanaKanjiConverter, プロセス内）        │
│        ├─ 同梱辞書（Dictionary フォルダ）          │
│        ├─ Zenzai = zenz ニューラルモデル          │
│        │     llama.cpp(llama.framework) + GGUF     │
│        ├─ 学習メモリ（確定で更新）                 │
│        └─ 動的ユーザー辞書（userdict.json）        │
└───────────────────▲──────────────────────────────┘
                    │ 読み書き
   ~/Library/Application Support/RomKana/
        config.json / userdict.json / 学習メモリ
```

**なぜ単一プロセスになったか**: 変換エンジンが純 Swift パッケージ（AzooKeyKanaKanjiConverter）になり、ニューラル変換も llama.cpp を組み込んだ軽量モデル（zenz, GGUF 70MB）で動くため、IME プロセスに直接抱えても軽い（常駐 ~74MB）。旧構成で Python/MLX を別プロセスに逃がしていた理由（数GBのランタイムを各アプリに載せたくない）が消えたので、HTTP サービスを廃止して薄く・速くした。

---

## 2. RomKana.app（Swift / InputMethodKit）

役割: キー入力の解釈、ローマ字→かなの即時表示、かな→漢字変換、候補ウィンドウ、確定、学習、ユーザー辞書・設定の読み込み、管理メニュー。**変換は外部に出さず、すべてプロセス内で行う。**

### 主要ファイル

| ファイル | 役割 |
|---|---|
| `Sources/main.swift` | `IMKServer` 起動、`NSManualApplication`/`AppDelegate`、入力ソース登録（`TISRegisterInputSource`） |
| `Sources/RomKanaController.swift` | `IMKInputController` 本体。イベント処理・変換要求・候補・確定・学習・ユーザー辞書・設定・メニュー（中核） |
| `Sources/RomajiConverter.swift` | ローカルの romaji→かな変換表（即時・依存なし） |
| `Sources/Config.swift` | `config.json` の読み込み（既定値つき・部分上書き・無ければ自動生成） |
| `Sources/Log.swift` / `DebugLog` | ログ補助（`os.Logger`、および `config.debugLog` で切替えるファイルログ） |

`KanaKanjiConverter` は `RomKanaController` 内で **静的に1つだけ共有**する。zenz の GGUF と Metal は初回ロードが重い（~1〜2秒）ため、テキストフィールドやセッションごとに作らず、プロセスで一度だけ読む。

### 入力時のイベントフロー（`RomKanaController`）

```
キー入力 ─▶ handle(event)
   ├─ 英数/かなキー         → 入力モード切替
   ├─ directInput(英数)     → そのまま挿入
   ├─ composing 中          → handleComposing
   │     ├─ 英字/記号       → romajiBuffer に追記 → renderComposing（生ローマ字を下線表示）
   │     ├─ Space           → romajiBuffer に空白挿入
   │     ├─ Shift+Space     → startConversion（変換要求）
   │     ├─ Return          → composedReading() を確定（かな）
   │     └─ Backspace       → 1文字削除
   └─ converting 中         → handleConverting（候補移動・Enter確定・etc）
```

- **preedit はローマ字のまま**（Sumibi 風）。`renderComposing` が `romajiBuffer` をそのまま下線表示する。かな漢字になるのは変換後だけ。
- **Space=空白 / Shift+Space=変換**。空白で単語を区切れる。

### 変換要求（`startConversion`）

```
startConversion
   ├─ romajiBuffer に空白あり → 区切り変換（Sumibi 風）
   │     各空白チャンクを独立に変換し、チャンクごとに上位候補（最大 chunkCandidateLimit）を取得
   │     候補#0 = 全チャンクの1番を連結
   │     以降    = 1チャンクだけ別候補に差し替えた文を列挙（同音異義を1語だけ選び直せる）
   │     大文字始まりの英字（AI, LLM, API）は変換せずそのまま（latinVerbatim）
   │
   └─ 空白なし → 文まるごと変換
         ① composedReading()  : RomajiConverter で romaji→かな
         ② ComposingText に積んで KanaKanjiConverter.requestCandidates（Zenzai 有効）
         ③ mainResults を「入力全体をカバーする候補（correspondingCount == 入力長）」を先頭、
            部分候補を後ろ、に並べ替え（途中まで候補のゴミを下げ、本命の文を上に）
         ④ 大文字英字の verbatim と、最後に生かな読みを fallback として追加
         ⑤ showCandidates（候補ウィンドウ表示・先頭をインライン）
```

requestCandidates は**同期・高速（warm で ~50ms）**なので、イベント処理中にそのまま呼んで結果を出す。旧構成のような「非同期待ち」「上限つき deadline」「順番のジャンプ」は無い。

### 確定と学習（`commit`）

```
commit(text)
   ├─ insertText（アプリに確定文字を挿入）
   ├─ 選んだ候補が Candidate なら
   │     updateLearningData(cand)  … AzooKey 学習メモリへ
   │     setCompletedData(cand)    … 文脈（直前確定）キャッシュへ
   └─ reset
```

学習は **AzooKey 組み込みのもの**を使う。確定した `Candidate` をそのまま渡すと、読み→表記の選好と直前文脈が反映される。学習データは Application Support 配下に永続化される（`memoryDirectoryURL`）。

> 区切り変換の候補は複数チャンクを連結した文字列なので、対応する単一の `Candidate` が無い。この経路では学習トリガを発火しない（`lastCandidates` を空にする）。

### 管理メニュー（`menu()`）

入力ソースアイコンのメニュー。

- **学習をリセット** — 次の変換で `shouldResetMemory` を一度だけ立て、AzooKey 学習を消去
- **ユーザー辞書を編集…（再選択で反映）** — `userdict.json` を開く
- **設定を編集…（再選択で反映）** — `config.json` を開く

辞書・設定は **IME を選び直したとき**（`activateServer`）に再読込する。

---

## 3. 変換エンジン — AzooKeyKanaKanjiConverter + Zenzai

純 Swift の変換ライブラリ。`KanaKanjiConverter.requestCandidates(_:options:)` に、かな読みを積んだ `ComposingText` と `ConvertRequestOptions` を渡すと、`ConversionResult`（`mainResults` ＝候補列、`firstClauseResults` ＝先頭文節候補）が返る。

### `ConvertRequestOptions`（`convertOptions()` で組み立て）

| 項目 | 値 | 由来 |
|---|---|---|
| `N_best` | 9 | `config.nBest` |
| `learningType` | `.inputAndOutput` / `.nothing` | `config.learning` |
| `dictionaryResourceURL` | `…/Resources/Dictionary` | 同梱辞書フォルダ（`config.dictionaryFolder`） |
| `memoryDirectoryURL` / `sharedContainerURL` | App Support/RomKana | 学習メモリの永続先 |
| `zenzaiMode` | `.on(weight:, inferenceLimit: 10, personalizationMode: nil)` | zenz GGUF を指定（`config.inferenceLimit`） |
| `shouldResetMemory` | 通常 false | メニューのリセット時のみ true |

### Zenzai（zenz ニューラルモデル）

- かな漢字変換に特化した小型ニューラルモデルを、辞書変換の上で使って候補を賢く並べる仕組み。
- 実体は **llama.cpp**（`llama.framework`）＋ **zenz の GGUF**。本アプリは **zenz-v3.2-small** の `ggml-model-Q5_K_M.gguf`（GPT-2系 char、約95Mパラメータ、量子化後 70MB）を同梱。
- Metal で動き、warm 後の1変換は ~50ms。初回のみモデルロードで重いので、`activateServer` でダミー変換して**ウォームアップ**する。

### 同梱辞書

AzooKey の既定辞書を `Dictionary` フォルダとして同梱し、`dictionaryResourceURL` で明示的に指す。SwiftPM の `Bundle.module` はアクセサが実行ファイル隣（.build パス）/ .app 直下しか見ず、`Contents/Resources` を見ないため使えない。コード署名の都合（後述）でも、`.bundle` でなく**素のフォルダ**として置くのが扱いやすい。

---

## 4. ユーザー辞書（`loadUserDictionary`）

手編集の `userdict.json`（`{"読み": ["表記", ...]}`）を、AzooKey の**動的ユーザー辞書**に流し込む。AzooKey は見出しの読みを `ruby`（＝ルビ）と呼び、**カタカナ**で持つ決まり。

```
userdict.json
   │  読み（ひらがな）をカタカナのルビに変換（0x3041–0x3096 を +0x60）
   ▼
DicdataElement(word: 表記, ruby: ルビ(カタカナの読み),
               cid: 固有名詞, mid: 一般, value: config.userDictWeight)
   ▼
KanaKanjiConverter.sendToDicdataStore(.importDynamicUserDict([...]))
```

- `value`（既定 -10、小さいほど強い）で候補順を押し上げる。
- `activateServer` ごとに読み直すので、編集して IME を選び直せば反映。`importDynamicUserDict` は毎回まとめて差し替える。
- 例: `あい→AI`、`おk→OK`、`めるこいん→メルコイン`、`おねしゃす→お願いします` など、英略語・社内語・口語。

---

## 5. 設定（`Sources/Config.swift` / `config.json`）

チューニング値はコードに直書きせず、`~/Library/Application Support/RomKana/config.json` から読む。

| キー | 既定 | 意味 |
|---|---|---|
| `nBest` | 9 | 候補の幅 |
| `inferenceLimit` | 10 | Zenzai の推論上限 |
| `chunkCandidateLimit` | 4 | 空白チャンクごとの代替候補数 |
| `learning` | true | AzooKey 学習の ON/OFF |
| `userDictWeight` | -10 | ユーザー辞書の重み（小さいほど強い） |
| `modelFile` | `ggml-model-Q5_K_M.gguf` | zenz GGUF のファイル名 |
| `dictionaryFolder` | `Dictionary` | 同梱辞書フォルダ名 |
| `warmupReading` | `てすと` | 起動時ウォームアップの読み |
| `latinVerbatimPattern` | `^[A-Z][A-Za-z0-9]*$` | そのまま残す英字の判定 |
| `debugLog` | true | `/tmp/romkana_conv.log` を書くか |

- 既定値はコード側に持ち、**ファイルが無ければ自動生成**、**一部キーだけ書いても残りは既定**（部分上書き）。
- 反映は `userdict.json` と同じく **IME 再選択時**。

---

## 6. 状態とデータ

| データ | 場所 | 形 | 更新 |
|---|---|---|---|
| 設定 | `~/Library/Application Support/RomKana/config.json` | キー/値 JSON | 手編集（再選択で反映） |
| ユーザー辞書 | 同ディレクトリ `userdict.json` | `{"読み": ["表記", ...]}` | 手編集（再選択で反映） |
| 学習メモリ | 同ディレクトリ（AzooKey 管理） | AzooKey 内部形式 | 確定のたび |

---

## 7. 主要な設計判断（と理由）

1. **変換は専用ニューラル（zenz）に寄せる**: 汎用 LLM をスコアラとして使う旧方式より、かな漢字変換に特化した zenz の方が、同一30問の実測で精度が上（後述ベンチ）。しかも軽い・速い。
2. **単一プロセス**: 変換が純 Swift＋軽量 GGUF で済むので、IME に直接組み込める。HTTP サービス／LaunchAgent／Python ランタイムを廃止し、常駐 ~74MB に。
3. **同期変換でジャンプ無し**: requestCandidates が ~50ms と速いので、旧構成で苦労した「非同期の順番ジャンプ」「待ち時間」が原理的に消えた。
4. **学習は AzooKey 組み込みを採用**: 自前の文脈バケツ学習より、ライブラリの単語＋文脈学習の方が精度が良いと判断（移行時の選択）。
5. **空白区切りで文節を明示**: ユーザーが空白で区切る＝文節境界を教えてくれる。これを使い、チャンクごとの代替候補を並べて「1語だけ同音異義を選び直す」を実現。
6. **候補は入力全体をカバーするものを優先**: `mainResults` は途中までの文節候補も含むため、`correspondingCount` で全体カバーを先頭に出し、ゴミ候補を下げる。
7. **チューニング値は config.json**: モデル・推論上限・候補数・重みなどを再ビルド無しで触れるよう外部化。
8. **IME はアプリの確定済みテキストを触れない**ため、Sumibi の「下線なし実テキストを領域変換」は不可。preedit で近似する（この制約は旧構成と同じ）。

---

## 8. 性能特性（warm, zenz-v3.2-small Q5_K_M）

| 操作 | 体感 |
|---|---|
| 入力中のかな/ローマ字表示 | 即時（ローカル） |
| 変換（文まるごと） | ~50ms |
| 区切り変換 | チャンク数 × 数十ms（各チャンクで requestCandidates） |
| 初回変換 | モデルロードで重い → `activateServer` でウォームアップ済み |
| 常駐メモリ | ~74MB（モデル込み） |

### 精度の実測（同一30問・top1・本アプリの辞書＋GGUF）

| 方式 | 正解 | 速度 | メモリ |
|---|---|---|---|
| 旧: mozcpy 辞書のみ | 22/30 | ~20ms | — |
| 旧: mozcpy + Qwen3-1.7B | 26/30 | ~100–280ms | ~1.2GB |
| **現: AzooKey + Zenzai** | **28/30** | **~50ms** | **74MB** |

全体では現行が上。ただし**個別には旧 LLM が勝つ問題もある**（例: 「けっきょくせいどがよくなった」→ 旧=精度○ / 現=制度✗）。広い文脈理解は 1.7B の方が強い場面が残る、という正直な結果。詳細は [`development-journey.md`](./development-journey.md) の移行編を参照。

---

## 9. ビルドと配置（`scripts/build_install.sh`）

```
swift build -c release            # SwiftPM（AzooKey + Zenzai trait, Cxx interop）
   ↓ ~/Library/Input Methods/RomKana.app に組立
   ├─ Contents/MacOS/RomKana                 実行ファイル
   ├─ Contents/MacOS/llama.framework         Zenzai の llama.cpp（@rpath で読む）
   ├─ Contents/Resources/Dictionary/         AzooKey 既定辞書（素フォルダ）
   ├─ Contents/Resources/ggml-model-Q5_K_M.gguf   zenz モデル
   ├─ Contents/Info.plist / *.lproj / main.tiff
   ↓ ad-hoc 署名（--deep, entitlements）
   ↓ open ＋ killall で再読込
```

- **`Package.swift`**: `AzooKeyKanaKanjiConverter`（`.upToNextMinor(from: "0.8.0")`, trait `["Zenzai"]`）に依存。target は `.interoperabilityMode(.Cxx)`（C++ 相互運用）＋ `.swiftLanguageMode(.v5)`。
- **llama.framework は必須**: Zenzai の llama.cpp は動的フレームワークで、実行ファイルが `@rpath`（`@loader_path` → `Contents/MacOS`）で読む。同梱し忘れると dyld クラッシュ。
- **辞書は素フォルダで同梱**: AzooKey のリソース `.bundle` は Info.plist が無く、codesign が入れ子バンドルとして弾く。`Dictionary` フォルダだけ普通のリソースとして置き、`dictionaryResourceURL` で指す。
- バンドルID `com.toshinao.inputmethod.RomKana`（**`.inputmethod.` が必須**。これが無いと入力ソースに出ない）。

---

## 10. ファイル一覧

```
~/dev/romkana/
├── Sources/
│   ├── main.swift               IMKServer 起動・入力ソース登録
│   ├── RomKanaController.swift   IMEの中核（入力/変換/候補/確定/学習/辞書/設定/メニュー）
│   ├── RomajiConverter.swift     ローカル romaji→かな表
│   ├── Config.swift              config.json の読み込み・既定生成
│   └── Log.swift                 ログ補助
├── models/
│   └── zenz-v3.2-small-gguf/ggml-model-Q5_K_M.gguf   同梱する zenz モデル
├── scripts/build_install.sh      ビルド→配置→再読込
├── Package.swift / Package.resolved
├── Info.plist / *.entitlements   IME バンドル設定
└── docs/
    ├── architecture.md           （この文書・現行）
    ├── architecture-legacy.md    旧構成（mozcpy + LLM スコアリング）
    └── development-journey.md     経緯・設計判断の物語

~/Library/Application Support/RomKana/
├── config.json                  設定
├── userdict.json                ユーザー辞書
└── （AzooKey 学習メモリ）         確定で更新
```
