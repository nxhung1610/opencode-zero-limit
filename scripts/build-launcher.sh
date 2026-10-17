#!/usr/bin/env bash
# Builds the RelayDock launcher and copies it into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macOS/RelayDock"
OUTPUT="$ROOT/build/relaydock-launch"

mkdir -p "$ROOT/build"

swift build --package-path "$PACKAGE" --configuration release --product RelayDockLauncher
BIN_PATH="$(swift build --package-path "$PACKAGE" --configuration release --show-bin-path)"
cp -f "$BIN_PATH/RelayDockLauncher" "$OUTPUT"
test -x "$OUTPUT"

echo "Built $OUTPUT"
