# RomKana アーキテクチャ（旧 / レガシー）

> **この文書は旧アーキテクチャの記録です。**
> RomKana は現在、変換エンジンを **AzooKeyKanaKanjiConverter + Zenzai（zenz ニューラルモデル）** に置き換え、**Python サービスを廃止した単一プロセス構成**になっています。現行の構成は [`architecture.md`](./architecture.md) を参照してください。
> ここに書かれている **mozcpy + LLM スコアリング（Qwen3-1.7B）の2プロセス構成**は 2026-06-21 に撤去されました。設計の経緯として残しています。

ローマ字を文脈つきでかな漢字に変換する、**完全ローカル**の macOS 入力メソッド（IME）。この文書は構成・データの流れ・設計判断をまとめたリファレンス。経緯・なぜそうしたかは [`development-journey.md`](./development-journey.md) を参照。

---

## 1. 全体像

**2プロセス構成**。表示・入力は Swift の IME、重い変換は Python の常駐サービスに分離している。

```
┌──────────────────────────────────────────────────┐
│ 任意の macOS アプリ（入力先のテキストフィールド）    │
└───────────────────▲──────────────────────────────┘
                    │ InputMethodKit
                    │ （preedit 表示 / 確定 insert / 候補ウィンドウ）
┌───────────────────┴──────────────────────────────┐
│ RomKana.app   — Swift + InputMethodKit            │
│   キー入力 → ローマ字 preedit → Shift+Space で変換 │
│   候補ウィンドウ・確定・学習トリガ・管理メニュー    │
└───────────────────▲──────────────────────────────┘
                    │ HTTP / JSON  (127.0.0.1:8765, localhost のみ)
┌───────────────────┴──────────────────────────────┐
│ 変換サービス  — Python（LaunchAgent で常駐）        │
│   mozcpy 辞書 n-best ＋ LLM sum-loglik リランク     │
│   (MLX / Qwen3-1.7B) ＋ ユーザー辞書 ＋ 文脈つき学習 │
└───────────────────▲──────────────────────────────┘
                    │ 読み書き
              learned.json（学習） / userdict.json（辞書）
```

**なぜ2プロセスか**: IME はあらゆるアプリのプロセスに読み込まれる軽量・常時生存のコンポーネントである必要があり、そこに数GBの LLM ランタイム（MLX/Python）を抱えさせたくない。変換は1つの常駐サービスに集約し、IME は薄いクライアントに保つ。サービスはモデルを1度だけロードして使い回す。

---

## 2. プロセス1 — RomKana.app（Swift / InputMethodKit）

役割: キー入力の解釈、ローマ字→かなの即時表示、変換要求、候補ウィンドウ、確定、学習トリガ、管理メニュー。**変換ロジックは持たない**（サービスに委譲）。

### 主要ファイル

| ファイル | 役割 |
|---|---|
| `Sources/main.swift` | `IMKServer` 起動、`NSManualApplication`/`AppDelegate`、入力ソース登録の儀式 |
| `Sources/RomKanaController.swift` | `IMKInputController` 本体。イベント処理・候補・確定・文脈追跡・サービス通信・メニュー（中核、~590行） |
| `Sources/RomajiConverter.swift` | ローカルの romaji→かな変換表（サービス不要・即時） |
| `Sources/Log.swift` / `DebugLog` | デバッグログ（本番化で除去予定） |
| `Sources/ConversionClient.swift` | ※レガシー（未配線）。実際の通信は Controller 内の `URLSession` 直叩き |

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
   ├─ romajiBuffer に空白あり → startSegmentedConversion
   │     各空白セグメントを独立変換して連結（サービスの segments API、dict-only）
   │     大文字始まり/子音のみの英字（AI, LLM）はそのまま確定
   │
   └─ 空白なし → 単体変換（上限つき同期待ち）
         ① composedReading()  : RomajiConverter で romaji→かな
         ② 辞書(use_llm:false) と LLM(use_llm:true) を /convert へ並行発射
         ③ 最大 400ms だけ LLM を待つ
              間に合えば LLM 順、超えたら辞書順で確定（以後並べ替えない＝ジャンプ無し）
         ④ showCandidates（候補ウィンドウ表示・先頭をインライン）
```

### 確定と学習（`commit`）

```
commit(text)
   ├─ insertText（アプリに確定文字を挿入）
   ├─ recentContext 更新（直近24字を保持。次の変換の文脈）
   ├─ learn(reading, surface, priorContext) → /learn（fire-and-forget）
   └─ reset
```

`recentContext`（直近の確定テキスト24字）が「文脈」として変換にも学習にも使われる。

### 管理メニュー（`menu()`）

入力ソースアイコンのメニュー。`/learned`・`/reset_learn` を叩く、または辞書ファイルを開く。

- 学習内容を確認 / 学習をリセット / ユーザー辞書を編集…

---

## 3. プロセス2 — 変換サービス（`service/server.py`, Python）

役割: 候補生成（辞書）、LLM リランク、ユーザー辞書、文脈つき適応学習、区切り変換。`ThreadingHTTPServer`、LaunchAgent で常駐、起動時に LLM をバックグラウンドで warm-load。

### `/convert` の変換パイプライン

```
reading（かな）
   │
   ▼ _normalize（口語正規化: こうゆう→こういう 等。元読みの候補も残す）
   ▼ mozcpy n-best（正規化＋元の両読み）＋ 生かな fallback → dedupe
   │         = ordered（辞書順の候補。実在のみ＝ハルシネーション無し）
   │
   ▼ use_llm の時: _rerank(context, ordered)
   │     LLM の sum-loglik で並べ替え（生成しない＝1パスのスコアリング）
   │     ・全候補を1回のバッチ forward（右パディング）
   │     ・文脈は1度だけ forward して KV キャッシュ化、候補にタイル複製
   │
   ▼ _apply_userdict(reading, ordered)
   │     ユーザー辞書の登録表記を候補2番目に差し込み（#1は据え置き）
   │
   ▼ _apply_learned(reading, ordered, context)
   │     文脈一致の学習 → 無ければ広域学習 で先頭へ昇格（後述）
   │
   ▼ candidates（最終順）
```

ポイント: **生成は辞書(mozcpy)、LLM はスコアリングだけ**。これにより造語ゼロ・高速（生成ループ無し）・オフライン。

### `/convert`（segments モード）= 区切り変換

```
convert_segments(segments, context)
   各セグメントを左から独立に変換（dict-only）
      acc = 確定文脈 ＋ 手前セグメントの確定 を累積して次に渡す
   → 各 best を連結して返す
```

手動で区切ると各セグメントが短くなり、**辞書の頻度 top1 が速くて良い**（LLM は孤立短語で外す＋40倍遅いので使わない）。

### LLM リランク（`_rerank`）

- 入力: 文脈 ＋ 同一読みの候補群（長さがほぼ揃う）。出力: スコア順。
- スコア = `P(候補トークン | 文脈)` の**合計対数尤度（sum）**。mean では信号が消える。
- バッチ＋文脈 KV キャッシュで warm ~0.1〜0.3s（候補ごと forward の旧実装比 約2.5倍）。

---

## 4. 状態とデータ

| データ | 場所 | 形 | 更新 |
|---|---|---|---|
| 適応学習 | `~/Library/Application Support/RomKana/learned.json` | `{"<文脈バケツ>\t<読み>": {表記: 回数}}` | 確定のたび（`/learn`） |
| ユーザー辞書 | 同ディレクトリ `userdict.json` | `{"読み": ["表記", ...]}` | 手編集（mtime ホットリロード） |
| 直近文脈 | IME メモリ `recentContext` | 直近24字の確定テキスト | 確定のたび |
| LLM | サービスメモリ | MLX モデル（~1.2GB常駐） | 起動時1回ロード |

### 文脈つき適応学習（`_apply_learned`）

学習キーは `"<直前2文字>\t<読み>"`。空バケツ＝「どの文脈でも」（広域）。

```
記録: 確定時に 広域キー と 文脈別キー の両方をカウント
適用: 文脈別キーに勝者(≥2回)があれば昇格
      無ければ 広域キー(≥2回) にフォールバック
```

→ 同じ読みが文脈で出し分く（雨/飴）。**LLM の賢さに依存しない**（小型モデルは同音語の文脈分岐が弱く、ユーザーの履歴の方が当たる、という実測に基づく設計）。

---

## 5. API（HTTP, localhost のみ）

| メソッド・パス | 用途 | 主な入出力 |
|---|---|---|
| `POST /convert` | 変換 | `{reading, context, n_best, use_llm}` または `{segments, context, ...}` → `{candidates, best}` |
| `POST /learn` | 学習記録 | `{reading, surface, context}` |
| `POST /reset_learn` | 学習リセット | `{}`（全消し）/ `{reading}`（個別・全バケツ） |
| `GET /learned` | 学習内容取得 | → `{learned}` |
| `GET /health` | 死活・モデルロード状態 | → `{ok, llm}` |

---

## 6. 主要な設計判断（と理由）

1. **生成は辞書、LLM はスコアリング**: ローカル小型モデルに生成させると質が出ず遅い。辞書が実在候補を出し、LLM は `P(候補|文脈)` の計算だけ担う。造語ゼロ・高速・オフライン。
2. **上限つき同期待ち**: 「フリーズ無し」と「先頭が動かない」は両立しない。最大400msだけ LLM を待つ同期方式で、ジャンプ無し・#1 に LLM 品質・体感~0.1〜0.3s に。
3. **完全ローカル**: ネット不要・無料・プライベート。クラウド生成（Sumibi 等）より速い（生成ループとネット往復が無い）が、品質はモデルに依存（~17/30 vs クラウド~29/30）。
4. **区切り変換は dict-only**: 手動区切りでは辞書 top1 が速くて良い。LLM は孤立短語で逆に外す。
5. **学習は LLM 非依存**: 同音語の文脈分岐は弱い小型モデルよりユーザー履歴が当たる。文脈バケツ＋広域フォールバックで実装。
6. **IME はアプリの確定済みテキストを触れない**ため、Sumibi の「下線なし実テキストを領域変換」は不可。preedit で近似している。

---

## 7. 性能特性（warm、Qwen3-1.7B）

| 操作 | 体感 |
|---|---|
| 入力中のかな/ローマ字表示 | 即時（ローカル、サービス不要） |
| 変換（短文・文脈あり） | ~0.1〜0.15s |
| 変換（長文・長文脈） | ~0.3s（400ms deadline 内） |
| 区切り変換 | ~0.03s（dict-only） |
| サービス常駐メモリ | ~1.2GB（モデル込み） |

---

## 8. ビルドと配置

- `scripts/build_install.sh` — `swiftc -module-name RomKana` でビルド → `~/Library/Input Methods/RomKana.app` に組立 → ad-hoc 署名 → `open`＋`killall` で再読込。
- バンドルID `com.toshinao.inputmethod.RomKana`（**`.inputmethod.` が必須**。これが無いと入力ソースに出ない）。
- サービスは LaunchAgent `com.toshinao.romkana.service`（`service/*.plist`、`RunAtLoad`＋`KeepAlive`）で常駐。`.venv/bin/python service/server.py`。

---

## 9. ファイル一覧

```
~/dev/romkana/
├── Sources/
│   ├── main.swift               IMKServer 起動・登録の儀式
│   ├── RomKanaController.swift   IMEの中核（入力/候補/確定/通信/学習/メニュー）
│   ├── RomajiConverter.swift     ローカル romaji→かな表
│   ├── ConversionClient.swift    ※レガシー・未配線
│   └── Log.swift                 ログ補助（本番化で除去予定）
├── service/
│   ├── server.py                 変換サービス（辞書＋LLM＋辞書＋学習＋区切り）
│   └── com.toshinao.romkana.service.plist
├── scripts/build_install.sh      ビルド→配置→再読込
├── Info.plist / *.entitlements   IME バンドル設定
└── docs/
    ├── architecture.md           現行構成
    ├── architecture-legacy.md    （この文書）
    └── development-journey.md     経緯・設計判断の物語

~/Library/Application Support/RomKana/
├── learned.json                  文脈つき適応学習
└── userdict.json                 ユーザー辞書
```
