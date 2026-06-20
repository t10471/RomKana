#!/bin/bash
# Build RomKana (swiftc, no Xcode), assemble the .app bundle into
# ~/Library/Input Methods, ad-hoc sign, and reload the running instance.
set -euo pipefail

ROOT="$HOME/dev/romkana"
APP="$HOME/Library/Input Methods/RomKana.app"
BIN_TMP="/tmp/RomKana.bin"

echo "==> compiling (swiftc, -module-name RomKana)"
swiftc -O \
  -module-name RomKana \
  -swift-version 5 \
  -framework Cocoa -framework InputMethodKit \
  -target arm64-apple-macosx14.0 \
  "$ROOT"/Sources/*.swift \
  -o "$BIN_TMP"

echo "==> assembling bundle at: $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_TMP" "$APP/Contents/MacOS/RomKana"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/main.tiff" ] && cp "$ROOT/Resources/main.tiff" "$APP/Contents/Resources/main.tiff"
# Localized display names ("ひらがな (RomKana)") live in *.lproj/InfoPlist.strings.
for lproj in "$ROOT"/Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done
plutil -lint "$APP/Contents/Info.plist"

echo "==> ad-hoc code signing"
codesign --force --deep --sign - \
  --entitlements "$ROOT/RomKana.entitlements" \
  "$APP"

echo "==> registering / reloading"
/usr/bin/open "$APP" || true        # let the system (re)discover the bundle
killall RomKana 2>/dev/null || true # kill old instance; macOS respawns on next keystroke

echo "==> done. (First time: System Settings > Keyboard > Input Sources > + > Japanese > RomKana)"
