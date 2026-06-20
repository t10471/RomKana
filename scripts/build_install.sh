#!/bin/bash
# Build RomKana via SwiftPM (azooKey + Zenzai), assemble the .app bundle into
# ~/Library/Input Methods with its resource bundles + zenz model, sign, reload.
set -euo pipefail

ROOT="$HOME/dev/romkana"
APP="$HOME/Library/Input Methods/RomKana.app"
GGUF="$ROOT/models/zenz-v3.2-small-gguf/ggml-model-Q5_K_M.gguf"

echo "==> swift build -c release"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "==> assembling bundle at: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RomKana" "$APP/Contents/MacOS/RomKana"
# Zenzai's llama.cpp builds as a dynamic framework the binary loads via
# @rpath (LC_RPATH has @loader_path → Contents/MacOS). Ship it next to the binary.
cp -R "$BIN/llama.framework" "$APP/Contents/MacOS/llama.framework"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/main.tiff" ] && cp "$ROOT/Resources/main.tiff" "$APP/Contents/Resources/main.tiff"
# Localized display names ("ひらがな (RomKana)") live in *.lproj/InfoPlist.strings.
for lproj in "$ROOT"/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# azooKey's default dictionary ships as a flat resource bundle (no Info.plist, so
# codesign rejects it as a nested bundle). Ship just the Dictionary FOLDER as a
# normal app resource; the converter is pointed at it via dictionaryResourceURL.
DICT_BUNDLE="$BIN/AzooKeyKanakanjiConverter_KanaKanjiConverterModuleWithDefaultDictionary.bundle"
cp -R "$DICT_BUNDLE/Dictionary" "$APP/Contents/Resources/Dictionary"
# zenz neural model (Zenzai weight), found via Bundle.main at runtime.
cp "$GGUF" "$APP/Contents/Resources/ggml-model-Q5_K_M.gguf"

# Ship our license + third-party attributions inside the bundle, so the
# distributed .app carries the required notices (MIT/BSD/Apache + CC-BY-SA zenz).
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$ROOT/licenses" "$APP/Contents/Resources/licenses"   # full license texts (MIT/BSD/Apache/CC-BY-SA)

plutil -lint "$APP/Contents/Info.plist"

echo "==> ad-hoc code signing"
codesign --force --deep --sign - \
  --entitlements "$ROOT/RomKana.entitlements" \
  "$APP"

echo "==> registering / reloading"
/usr/bin/open "$APP" || true        # let the system (re)discover the bundle
killall RomKana 2>/dev/null || true # kill old instance; macOS respawns on next keystroke

echo "==> done. (First time: System Settings > Keyboard > Input Sources > + > Japanese > RomKana)"
