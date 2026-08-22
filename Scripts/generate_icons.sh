#!/usr/bin/env zsh
# Regenerate all app icons programmatically and compile the macOS .icns.
# Outputs land in Support/Icons/ and are picked up by build.sh /
# run_simulator.sh at bundle-assembly time.
set -eo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/Support/Icons"

rm -rf "$OUT"
mkdir -p "$OUT"
swift "$ROOT/Scripts/generate_icons.swift" "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
echo "Compiled $OUT/AppIcon.icns"
