#!/usr/bin/env zsh
# Build (debug) and launch the app bundle.
set -eo pipefail

ROOT="${0:A:h:h}"
"$ROOT/Scripts/build.sh" --debug
# Dev launches skip the move-to-Applications prompt.
open --env FF_SKIP_MOVE_PROMPT=1 "$ROOT/build/FITS n' Finish.app"
