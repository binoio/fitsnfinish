#!/usr/bin/env zsh
# Build for the iOS Simulator, assemble the .app, install and launch it on a
# booted (or newly booted) simulator device.
#   ./Scripts/run_simulator.sh [device-name]
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

BUNDLE_ID="io.bino.fitsnfinish"
TRIPLE="arm64-apple-ios17.0-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# 1. Cross-compile the SwiftPM package for the simulator.
swift build -c debug --triple "$TRIPLE" --sdk "$SDK"
BIN_DIR="$(swift build -c debug --triple "$TRIPLE" --sdk "$SDK" --show-bin-path)"

# 2. Assemble the flat iOS .app bundle.
APP="$ROOT/build/FITS n' Finish (Simulator).app"
rm -rf "$APP"
mkdir -p "$APP"
cp "$BIN_DIR/FitsnFinish" "$APP/FitsnFinish"
cp "$ROOT/Support/Info-iOS.plist" "$APP/Info.plist"
# App icons (regenerate with Scripts/generate_icons.sh).
[[ -d "$ROOT/Support/Icons/iOS" ]] && cp "$ROOT/Support/Icons/iOS/"*.png "$APP/"
for bundle in "$BIN_DIR"/FitsnFinish_*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/"
done
codesign --force --sign - "$APP"

# 3. Pick a device: explicit argument, else the booted one, else boot the
#    first available iPhone.
DEVICE="$1"
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun simctl list devices booted | grep -Eo '^\s+.+\([0-9A-F-]{36}\)' | head -1 | grep -Eo '[0-9A-F-]{36}' || true)"
fi
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun simctl list devices available | grep iPhone | head -1 | grep -Eo '[0-9A-F-]{36}' || true)"
  if [[ -z "$DEVICE" ]]; then
    echo "error: no iOS simulator devices available — install a runtime with:" >&2
    echo "  xcodebuild -downloadPlatform iOS" >&2
    exit 1
  fi
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
fi

# 4. Install and launch.
open -a Simulator
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
echo "Launched $BUNDLE_ID on simulator device $DEVICE"
