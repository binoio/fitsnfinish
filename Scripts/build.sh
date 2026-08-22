#!/usr/bin/env zsh
# Build FITS n' Finish and assemble the macOS .app bundle from the SwiftPM
# release products.
#   ./Scripts/build.sh [--debug]
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

CONFIG="release"
[[ "$1" == "--debug" ]] && CONFIG="debug"

swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/FITS n' Finish.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FitsnFinish" "$APP/Contents/MacOS/FitsnFinish"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
print -n "APPL????" > "$APP/Contents/PkgInfo"

# App icon (regenerate with Scripts/generate_icons.sh).
[[ -f "$ROOT/Support/Icons/AppIcon.icns" ]] \
  && cp "$ROOT/Support/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle (compiled Metal library) → Contents/Resources so
# Bundle.module resolves inside the app.
for bundle in "$BIN_DIR"/FitsnFinish_*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "Built: $APP"
