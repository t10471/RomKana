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
romkana/
├── Sources/
│   ├── main.swift               IMKServer 起動・入力ソース登録
│   ├── RomKanaController.swift   IMKInputController: 入力/変換/候補/確定/学習/辞書/設定/メニュー
│   ├── RomajiConverter.swift     ローカル romaji→かな（拗音/促音/撥音）
│   ├── Config.swift              config.json の読み込み・既定生成
│   └── Log.swift                 os.Logger ラッパ / DebugLog
├── models/zenz-v3.2-small-gguf/ggml-model-Q5_K_M.gguf   同梱する zenz モデル
├── models/base_n5_lm/                                   個人最適化の base N-gram（任意・非収録）
├── Package.swift                AzooKeyKanaKanjiConverter(trait Zenzai), Cxx interop
├── Info.plist / RomKana.entitlements   IME 登録（バンドルID は .inputmethod. 必須）
├── scripts/build_install.sh     ビルド→バンドル組立→署名→reload
├── scripts/train_personal.sh    確定履歴→個人N-gram学習（CliTool ngram train）
└── docs/                        architecture.md / architecture-legacy.md / development-journey.md
```

## セットアップ / 使い方

1. zenz モデル（GGUF, 約74MB）を取得して `models/` に置く（リポジトリには含めていない）:
   ```
   mkdir -p models/zenz-v3.2-small-gguf
   curl -L -o models/zenz-v3.2-small-gguf/ggml-model-Q5_K_M.gguf \
     https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf
   ```
   （`huggingface-cli download Miwa-Keita/zenz-v3.2-small-gguf ggml-model-Q5_K_M.gguf --local-dir models/zenz-v3.2-small-gguf` でも可。モデルは Apache-2.0 / © Miwa Keita。）
2. ビルド/インストール（リポジトリ直下で実行。クローン先の場所は問わない）:
   ```
   bash scripts/build_install.sh
   ```
   （`swift build` → `~/Library/Input Methods/RomKana.app` に組立 → ad-hoc 署名 → reload。
   `llama.framework`・`Dictionary` フォルダ・zenz GGUF を同梱する。）
3. 入力ソース追加: システム設定 → キーボード → 入力ソース → ＋ → 日本語 → **RomKana** → 追加
   （初回は反映に再ログインが必要な場合あり）
4. `Ctrl+Space` 等で RomKana に切替え、TextEdit 等でローマ字入力 → **Shift+Space で変換** →
   Space で候補送り → Enter で確定。

## 操作

| キー | 動作 |
|---|---|
| 英字/記号 | ローマ字を打鍵、そのまま下線付きインライン表示（Sumibi風） |
| Space | （入力中）空白を挿入／（候補表示中）次候補 |
| **Shift+Space** | （入力中）変換して候補表示 |
| ↑ / ↓ | 候補移動 |
| Enter | （入力中）かなのまま確定／（候補中）選択候補を確定 |
| **Shift+Enter** | （入力中）ローマ字のまま確定 |
| Backspace | （入力中）1字削除／（候補中）ローマ字編集に戻る |
| Esc | （候補中）ローマ字編集に戻る／（入力中）取消／（文節変換中）候補→文節→ローマ字と段階的に戻す |
| ← / → | （文節変換中）フォーカス文節を移動（`《…》`） |
| Option+← / → | （文節変換中）フォーカス文節の区切りを伸縮 |
| 英数 / かな | 直接入力モード ⇔ かな入力モード切替 |

- **文節変換**（空白なしで Shift+Space・既定 ON）: 文が文節に分かれ `《…》` がフォーカス文節。`←`/`→` でフォーカス移動、`Space` でその文節の候補、`Option+←`/`Option+→` で文節の区切りを伸縮、`Enter` で全文確定、`Esc` は候補→文節→ローマ字と段階的に戻す（`config.clauseConversion` で OFF 可）。
- 空白で区切って Shift+Space すると、空白を文節境界として各チャンクを変換し、候補に「1語だけ別候補に差し替えた文」が並ぶ（同音異義を1語だけ選び直せる）。
- 大文字始まりの英字（`AI` `LLM` `API`）は変換せずそのまま確定候補に出る。

## 設定・ユーザー辞書

`~/Library/Application Support/RomKana/`（メニューの「設定を編集…」「ユーザー辞書を編集…」から開ける。**IME を選び直すと反映**）。

- `config.json` — `nBest` / `inferenceLimit` / `chunkCandidateLimit` / `learning` / `userDictWeight` / `modelFile` / `warmupReading` / `latinVerbatimPattern` / `debugLog` / `clauseConversion`（文節変換）/ `personalization`・`personalizationAlpha`・`personalizationN`（個人最適化）。無ければ自動生成、一部キーだけの上書きも可。
- `userdict.json` — `{"読み": ["表記", ...]}`。例 `あい→AI`、`おk→OK`、`めるこいん→メルコイン`。
- 学習メモリ — 確定するたび AzooKey が更新（メニューの「学習をリセット」で消去）。

## 個人最適化（Zenzai パーソナライゼーション・任意）

確定した文から個人 N-gram モデルを作り、Zenzai の変換を自分の語彙・言い回しに寄せる（既定 OFF）。AzooKey 組み込みの仕組みで、専門用語・固有名詞・口語の精度が上がりやすい。本体の逐次学習（AzooKey 学習メモリ）とは別レイヤの上積み。

1. base（汎用）N-gram モデルを取得して `models/base_n5_lm/` に置く（zenz GGUF と同じ作者）:
   ```
   mkdir -p models/base_n5_lm
   for f in lm_c_abc lm_u_abx lm_u_xbc lm_r_xbx; do
     curl -L -o "models/base_n5_lm/$f.marisa" \
       "https://huggingface.co/Miwa-Keita/base_n5_lm/resolve/main/$f.marisa"
   done
   ```
   `bash scripts/build_install.sh` で `.app` に同梱される。
2. `config.json` で `"personalization": true`。以後、確定文が
   `~/Library/Application Support/RomKana/personalization_history.txt` に貯まる
   （**ON のときだけ**記録・平文・ローカルのみ）。
3. ある程度（数百文〜）貯まったら個人モデルを学習:
   ```
   bash scripts/train_personal.sh
   ```
   `personal_lm/lm_*.marisa` が生成される（AzooKey CliTool を `swift run` で使用）。
4. RomKana を選び直すと有効化（base と personal が揃ったときのみ）。`personalizationAlpha`
   （既定 0.5）で個人モデルの効き具合を調整。効きすぎて汎用変換が乱れるなら下げる。

> プライバシー: 履歴は確定文の平文。`personalization` を OFF にすれば記録されない。
> base_n5_lm は azooKey-Desktop のサブモジュール由来（© Miwa Keita）で HF にライセンス
> 明示が無いため、本リポジトリには含めず取得手順のみ提供。再配布時は要確認。

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
- 同梱の zenz モデル `ggml-model-Q5_K_M.gguf` は **Apache-2.0**（© Miwa Keita / ensan）で、MIT には含まれません。GGUF へ量子化（＝改変）した旨を明示しています。
- 個人最適化で同梱する `base_n5_lm`（N-gram, © Miwa Keita）は HF にライセンス明示が無く、azooKey-Desktop のサブモジュール由来。本リポジトリには含めず取得手順のみ提供。再配布時は要確認。
- 主な依存: AzooKeyKanaKanjiConverter（MIT, © Miwa/Ensan）、llama.cpp（MIT）、AzooKey 既定辞書（Apache-2.0）。
