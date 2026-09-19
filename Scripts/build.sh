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

# Stamp the marketing version from the VERSION file and a monotonic build
# number from the commit count — Sparkle compares CFBundleVersion, so it must
# strictly increase across releases.
if [[ -f "$ROOT/VERSION" ]]; then
  VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Embed Sparkle.framework (the executable links it via @rpath/../Frameworks).
SPARKLE_FRAMEWORK="$(find "$ROOT/.build" -type d -name "Sparkle.framework" -path "*artifacts*" -not -path "*dSYM*" | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  # ditto preserves the framework's Versions symlink structure; cp -R would not.
  ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
fi

# App icon (regenerate with Scripts/generate_icons.sh).
[[ -f "$ROOT/Support/Icons/AppIcon.icns" ]] \
  && cp "$ROOT/Support/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle (the Metal shader source) → Contents/Resources,
# where ResourceBundleLocator looks for it relative to the .app. Copy only the
# app's own bundle: a prior `swift test` leaves the fixtures bundle beside it.
RESOURCE_BUNDLE="$BIN_DIR/FitsnFinish_FitsnFinish.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
  echo "warning: $RESOURCE_BUNDLE missing; GPU pipeline will be unavailable" >&2
fi

echo "Built: $APP"
