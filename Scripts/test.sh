#!/usr/bin/env zsh
# Run the FITS n' Finish test suite.
#   ./Scripts/test.sh           native (macOS) run
#   ./Scripts/test.sh --docker  containerized run of the portable core suite
set -eo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

if [[ "$1" == "--docker" ]]; then
  docker build -t fitsnfinish-tests .
  docker run --rm fitsnfinish-tests
else
  swift test
fi
