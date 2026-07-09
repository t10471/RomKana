#!/bin/bash
# Fast reload for iterative CODE changes.
#
# Unlike build_install.sh, this NEVER deletes the .app bundle and NEVER re-registers
# it (`open` / TISRegisterInputSource). It only swaps the freshly built binary into the
# already-installed bundle, re-signs, and restarts the process. Because macOS never sees
# the input source disappear, it keeps RomKana registered and does NOT inject phantom
# fallback input sources (ATOK / Apple 日本語) into the enabled list.
#
# Use scripts/build_install.sh instead when the bundle itself changes — Info.plist,
# llama.framework, the zenz GGUF / Dictionary resources, or the first install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Library/Input Methods/RomKana.app"

if [ ! -d "$APP" ]; then
  echo "RomKana.app is not installed yet. Run scripts/build_install.sh first." >&2
  exit 1
fi

echo "==> swift build -c release"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Stop the running instance first so the executable file isn't busy while we overwrite
# it. macOS respawns the input method on the next keystroke in a RomKana field.
echo "==> stopping current RomKana process"
killall RomKana 2>/dev/null || true

echo "==> swapping in the new binary (bundle kept in place)"
cp "$BIN/RomKana" "$APP/Contents/MacOS/RomKana"

echo "==> re-signing (ad-hoc)"
codesign --force --deep --sign - \
  --entitlements "$ROOT/RomKana.entitlements" \
  "$APP"

echo "==> done. No bundle delete / no re-register → no phantom input sources."
echo "    RomKana relaunches on the next keystroke; if it feels stuck, switch input"
echo "    source away and back once."
