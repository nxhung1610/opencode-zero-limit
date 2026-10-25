#!/usr/bin/env bash
# Builds the RelayDock launcher and Edge daemon and copies them into build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macOS/RelayDock"
OUTPUT="$ROOT/build/relaydock-launch"
EDGE_OUTPUT="$ROOT/build/relaydock-edge"
FREE_USAGE_PLUGIN="$PACKAGE/Resources/relaydock-free-usage-limit.js"

mkdir -p "$ROOT/build"

swift build --package-path "$PACKAGE" --configuration release --product RelayDockLauncher
swift build --package-path "$PACKAGE" --configuration release --product RelayDockEdge
BIN_PATH="$(swift build --package-path "$PACKAGE" --configuration release --show-bin-path)"
# Replace via a fresh inode (mv renames): `cp -f` over an already-executed
# Mach-O reuses its inode, and macOS then SIGKILLs it ("Killed: 9") on the
# next launch — stale code-signature state for the overwritten vnode.
cp -f "$BIN_PATH/RelayDockLauncher" "$OUTPUT.tmp"
cp -f "$BIN_PATH/RelayDockEdge" "$EDGE_OUTPUT.tmp"
test -s "$FREE_USAGE_PLUGIN"
cp -f "$FREE_USAGE_PLUGIN" "$ROOT/build/relaydock-free-usage-limit.js.tmp"
mv -f "$OUTPUT.tmp" "$OUTPUT"
mv -f "$EDGE_OUTPUT.tmp" "$EDGE_OUTPUT"
mv -f "$ROOT/build/relaydock-free-usage-limit.js.tmp" "$ROOT/build/relaydock-free-usage-limit.js"
test -x "$OUTPUT"
test -x "$EDGE_OUTPUT"

echo "Built $OUTPUT"
echo "Built $EDGE_OUTPUT"
