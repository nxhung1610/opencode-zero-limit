#!/usr/bin/env bash
# Builds the RelayDock launcher and Edge daemon and copies them into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macOS/RelayDock"
OUTPUT="$ROOT/build/relaydock-launch"
EDGE_OUTPUT="$ROOT/build/relaydock-edge"

mkdir -p "$ROOT/build"

swift build --package-path "$PACKAGE" --configuration release --product RelayDockLauncher
swift build --package-path "$PACKAGE" --configuration release --product RelayDockEdge
BIN_PATH="$(swift build --package-path "$PACKAGE" --configuration release --show-bin-path)"
cp -f "$BIN_PATH/RelayDockLauncher" "$OUTPUT"
cp -f "$BIN_PATH/RelayDockEdge" "$EDGE_OUTPUT"
test -x "$OUTPUT"
test -x "$EDGE_OUTPUT"

echo "Built $OUTPUT"
echo "Built $EDGE_OUTPUT"
