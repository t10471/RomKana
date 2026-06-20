# RomKana — ローカルLLM/辞書ハイブリッドの macOS IME

ローマ字を打つと、かな漢字交じり文に変換する macOS 入力メソッド（IME）。
変換は**完全ローカル**で動く。

例: `kouyuufuuninyuuryokusuruto` → （Space）→ `こうゆう風に入力すると`（候補から選択）

## アーキテクチャ

```
キー入力(ローマ字)
   │  IMKInputController が捕捉
   ▼
RomKana.app (Swift / InputMethodKit, ~/Library/Input Methods/)
   ├─ RomajiConverter: ローカル romaji→かな（同期・即時インラインプレビュー）
   └─ Space で確定要求 ── HTTP :8765 ──▶ 変換サービス(Python, launchd常駐)
                                            ├─ mozcpy: かな→漢字 n-best（主・読み忠実・~15ms）
                                            └─ LLM rescore(任意/既定OFF): LFM2.5-1.2B-JP via MLX
   ▼ 候補を表示、Space で候補送り、Enter で確定
```

### Phase 0 の重要な知見（なぜハイブリッドか）
当初は「LLM が romaji/かな → 漢字を直接変換」を狙ったが、**LFM2.5-1.2B-JP(4bit) は
汎用チャットモデルで、プロンプトのみでは かな漢字変換が不安定**だった（読みを保持せず応答・
継続・言い換えをする。モデルカードも変換用途は非推奨と明記）。3方式（番号選択・指示変換・
LM 尤度リスコア）すべて、辞書(`mozcpy`)の順位を改善せず**悪化**させた。
→ **変換の主役は `mozcpy`（Mozc 由来の辞書＋コストモデル）**。LLM は文脈ありリスコアの
オプションとして残し、既定 OFF（`use_llm:false`）。強いモデル/文脈活用は将来の拡張余地。

## 構成ファイル

```
~/dev/romkana/
├── Sources/
│   ├── main.swift              NSApplication + IMKServer + IMKCandidates
│   ├── RomKanaController.swift  IMKInputController: イベント/markedText/候補/確定
│   ├── RomajiConverter.swift    ローカル romaji→かな（拗音/促音/撥音）
│   ├── ConversionClient.swift   :8765 への非同期呼び出し（actor, キャンセル可）
│   └── Log.swift                os.Logger ラッパ
├── Info.plist                  IME 登録（ComponentInputModeDict 等）
├── RomKana.entitlements        現状 sandbox なし
├── service/
│   ├── server.py               変換サービス(mozcpy + 任意LLM rescore), POST /convert
│   └── com.toshinao.romkana.service.plist  LaunchAgent
├── scripts/
│   ├── build_install.sh        ビルド→バンドル→署名→reload
│   └── convert_test*.py        Phase 0 のプロンプト検証
└── .venv/                      mlx-lm, mozcpy
```

## セットアップ / 使い方

1. 変換サービス（launchd 常駐済み。手動なら）:
   ```
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.toshinao.romkana.service.plist
   curl -s localhost:8765/health   # {"ok": true, ...}
   ```
2. IME のビルド/インストール:
   ```
   bash ~/dev/romkana/scripts/build_install.sh
   ```
3. 入力ソース追加: システム設定 → キーボード → 入力ソース → ＋ → 日本語 → **RomKana** → 追加
   （初回は反映に再ログインが必要な場合あり）
4. `Ctrl+Space` 等で RomKana に切替え、TextEdit 等でローマ字入力 → Space で変換 →
   Space で候補送り → Enter で確定。

## 操作

| キー | 動作 |
|---|---|
| 英字 | ローマ字を打鍵、かなを下線付きインライン表示 |
| Space | （かな表示中）変換して候補表示／（候補表示中）次候補 |
| ↑ / ↓ | 候補移動 |
| Enter | 確定 |
| Backspace | （かな中）1字削除／（候補中）かな編集に戻る |
| Esc | （かな中）取消／（候補中）かな編集に戻る |

## 開発ループ（Xcode 不要）

```
bash scripts/build_install.sh      # 再ビルド→再署名→killall（次キー入力で自動再起動）
log stream --predicate 'subsystem == "com.toshinao.romkana"' --level debug   # ログ
```
- 接続名/クラス名/`-module-name RomKana` の不一致は無言の未読込の原因。
- バイナリ差し替え後は必ず再署名（スクリプトが実施）。
- Info.plist の登録系を変えた時は再ログインで反映。

## 既知の制限 / 次の課題
- 候補表示はインライン方式（IMKCandidates のリストUI化は Phase 3）。
- LLM リスコアは既定 OFF（1.2B では辞書に勝てない）。文脈ありでの有効化は要検証。
- sandbox 化（配布時）は entitlements に network.client / mach-register 例外を追加。
