#!/bin/bash
# 確定履歴 (personalization_history.txt) から個人 N-gram モデルを学習し、Zenzai の
# パーソナライゼーション用に ~/Library/Application Support/RomKana/personal_lm/ へ出力する。
# 学習は AzooKey の CliTool (ngram train) を Zenzai trait 付きで実行する
# （EfficientNGram が library product 非公開のため、本体からは直接呼べない）。
#
# 使い方:  bash scripts/train_personal.sh
# 学習後:  config.json で "personalization": true にし、RomKana を選び直すと有効になる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AZOO="$ROOT/.build/checkouts/AzooKeyKanaKanjiConverter"
SUPPORT="$HOME/Library/Application Support/RomKana"
HISTORY="$SUPPORT/personalization_history.txt"
OUT="$SUPPORT/personal_lm"
N=5

if [ ! -f "$HISTORY" ]; then
  echo "[Error] 履歴がありません: $HISTORY"
  echo "        RomKana で日本語を変換・確定すると貯まります。"
  exit 1
fi
if [ ! -d "$AZOO" ]; then
  echo "[Error] AzooKey のチェックアウトが見つかりません: $AZOO"
  echo "        先に bash scripts/build_install.sh を実行してください。"
  exit 1
fi

lines=$(grep -c '' "$HISTORY" || true)
echo "==> 学習データ: $HISTORY (${lines} 文)"
mkdir -p "$OUT"

echo "==> CliTool ngram train (n=$N) -> $OUT"
swift run --package-path "$AZOO" --traits Zenzai CliTool ngram train -n "$N" -o "$OUT/" "$HISTORY"

echo "==> 出力ファイル:"
ls -la "$OUT"
echo "==> 完了。config.json で \"personalization\": true にし、RomKana を選び直すと有効になります。"
