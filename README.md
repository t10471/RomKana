# RomKana — AzooKey + Zenzai のローカル macOS IME

ローマ字を打つと、文脈を見てかな漢字交じり文に変換する macOS 入力メソッド（IME）。
変換は **完全ローカル**・**単一プロセス**で動く（外部サービス・ネットワーク不要）。

例: `kouyuufuuninyuuryokusuruto` →（Shift+Space）→ `こうゆう風に入力すると`（候補から選択）
空白で区切ると文節ごとに変換できる: `seido ga agaranai` → `制度が上がらない`（1語だけ別候補にも差し替え可）

> 旧構成（mozcpy + ローカルLLMスコアリングの Python 2プロセス）は 2026-06 に撤去しました。
> 詳細・経緯は [`docs/development-journey.md`](docs/development-journey.md)、現行リファレンスは [`docs/architecture.md`](docs/architecture.md)、旧構成は [`docs/architecture-legacy.md`](docs/architecture-legacy.md)。

## アーキテクチャ

```
キー入力(ローマ字)
   │  IMKInputController が捕捉、ローマ字のまま下線表示（Sumibi風）
   ▼
RomKana.app (Swift / InputMethodKit, ~/Library/Input Methods/)
   ├─ RomajiConverter            ローマ字 → かな（即時）
   └─ KanaKanjiConverter         かな → 漢字（プロセス内・~50ms）
        （AzooKeyKanaKanjiConverter）
        ├─ 同梱辞書（Dictionary フォルダ）
        ├─ Zenzai = zenz ニューラルモデル（llama.cpp + GGUF 70MB, Metal）
        ├─ 学習メモリ（確定で更新）
        └─ 動的ユーザー辞書（userdict.json）
   ▼ 候補ウィンドウ表示、Space で候補送り、Enter で確定
```

- **変換は専用ニューラル（zenz）に寄せた単一プロセス**。常駐 ~74MB、warm の1変換 ~50ms。
- requestCandidates が同期・高速なので、非同期待ちや候補順のジャンプは無い。
- 実測（同一30問・top1）: 旧辞書のみ 22/30 / 旧+Qwen3-1.7B 26/30 / **現 AzooKey+Zenzai 28/30**。

## 構成ファイル

```
~/dev/romkana/
├── Sources/
│   ├── main.swift               IMKServer 起動・入力ソース登録
│   ├── RomKanaController.swift   IMKInputController: 入力/変換/候補/確定/学習/辞書/設定/メニュー
│   ├── RomajiConverter.swift     ローカル romaji→かな（拗音/促音/撥音）
│   ├── Config.swift              config.json の読み込み・既定生成
│   └── Log.swift                 os.Logger ラッパ / DebugLog
├── models/zenz-v3.2-small-gguf/ggml-model-Q5_K_M.gguf   同梱する zenz モデル
├── Package.swift                AzooKeyKanaKanjiConverter(trait Zenzai), Cxx interop
├── Info.plist / RomKana.entitlements   IME 登録（バンドルID は .inputmethod. 必須）
├── scripts/build_install.sh     ビルド→バンドル組立→署名→reload
└── docs/                        architecture.md / architecture-legacy.md / development-journey.md
```

## セットアップ / 使い方

1. ビルド/インストール:
   ```
   bash ~/dev/romkana/scripts/build_install.sh
   ```
   （`swift build` → `~/Library/Input Methods/RomKana.app` に組立 → ad-hoc 署名 → reload。
   `llama.framework`・`Dictionary` フォルダ・zenz GGUF を同梱する。）
2. 入力ソース追加: システム設定 → キーボード → 入力ソース → ＋ → 日本語 → **RomKana** → 追加
   （初回は反映に再ログインが必要な場合あり）
3. `Ctrl+Space` 等で RomKana に切替え、TextEdit 等でローマ字入力 → **Shift+Space で変換** →
   Space で候補送り → Enter で確定。

## 操作

| キー | 動作 |
|---|---|
| 英字/記号 | ローマ字を打鍵、そのまま下線付きインライン表示（Sumibi風） |
| Space | （入力中）空白を挿入／（候補表示中）次候補 |
| **Shift+Space** | （入力中）変換して候補表示 |
| ↑ / ↓ | 候補移動 |
| Enter | （入力中）かなのまま確定／（候補中）選択候補を確定 |
| Backspace | （入力中）1字削除／（候補中）ローマ字編集に戻る |
| Esc | （候補中）ローマ字編集に戻る／（入力中）取消 |
| 英数 / かな | 直接入力モード ⇔ かな入力モード切替 |

- 空白で区切ると文節ごとに変換し、候補に「1語だけ別候補に差し替えた文」が並ぶ（同音異義を1語だけ選び直せる）。
- 大文字始まりの英字（`AI` `LLM` `API`）は変換せずそのまま確定候補に出る。

## 設定・ユーザー辞書

`~/Library/Application Support/RomKana/`（メニューの「設定を編集…」「ユーザー辞書を編集…」から開ける。**IME を選び直すと反映**）。

- `config.json` — `nBest` / `inferenceLimit` / `chunkCandidateLimit` / `learning` / `userDictWeight` / `modelFile` / `warmupReading` / `latinVerbatimPattern` / `debugLog`。無ければ自動生成、一部キーだけの上書きも可。
- `userdict.json` — `{"読み": ["表記", ...]}`。例 `あい→AI`、`おk→OK`、`めるこいん→メルコイン`。
- 学習メモリ — 確定するたび AzooKey が更新（メニューの「学習をリセット」で消去）。

## 開発ループ（Xcode 不要）

```
bash scripts/build_install.sh      # 再ビルド→再署名→killall（次キー入力で自動再起動）
log stream --predicate 'subsystem == "com.toshinao.romkana"' --level debug   # ログ
tail -f /tmp/romkana_conv.log      # 変換の詳細（config.debugLog=true のとき）
```
- 接続名/クラス名/`-module-name RomKana` の不一致は無言の未読込の原因。
- バイナリ差し替え後は必ず再署名（スクリプトが実施）。
- `Info.plist` の登録系を変えた時は再ログインで反映。
- `llama.framework` の同梱忘れは dyld クラッシュ（`@rpath/llama.framework`）の原因。

## 既知の制限 / 次の課題
- 広い文脈の同音異義は外すことがある（例「結局精度が…」が「制度」になる場面）。文節単位の選び直しは空白区切りで対応。
- IME はアプリの確定済みテキストを触れないため、Sumibi の「実テキストを領域変換」は不可。preedit で近似。
- 配布時の sandbox 化は entitlements に必要例外の追加が要る。

## ライセンス / クレジット

- RomKana 本体のコードは **MIT License**（[`LICENSE`](LICENSE)）。
- `.app` には第三者の成果物を同梱・リンクしています。各ライセンス（MIT / BSD-2-Clause / Apache-2.0）と著作権表示は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を参照。
- 同梱の zenz モデル `ggml-model-Q5_K_M.gguf` は **CC-BY-SA-4.0**（© Miwa Keita / ensan）で、MIT には含まれません。GGUF へ量子化した改変版を同ライセンスで再配布しています。
- 主な依存: AzooKeyKanaKanjiConverter（MIT, © Miwa/Ensan）、llama.cpp（MIT）、AzooKey 既定辞書（Apache-2.0）。
