#!/usr/bin/env zsh
# Build (debug) and launch the app bundle.
set -eo pipefail

ROOT="${0:A:h:h}"
"$ROOT/Scripts/build.sh" --debug
open "$ROOT/build/FITS n' Finish.app"
