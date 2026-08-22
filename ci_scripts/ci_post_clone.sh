#!/usr/bin/env zsh
# Xcode Cloud post-clone hook. Xcode Cloud builds/tests the SwiftPM package
# via its workflow configuration; this hook just surfaces the toolchain in
# the build log and warms the package graph.
set -eo pipefail
swift --version
cd "$CI_PRIMARY_REPOSITORY_PATH"
swift package resolve
