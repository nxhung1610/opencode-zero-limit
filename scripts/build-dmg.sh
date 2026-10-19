#!/usr/bin/env bash
# Packages build/RelayDock.app into a drag-to-Applications RelayDock.dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/RelayDock.app"
OUTPUT="$ROOT/build/RelayDock.dmg"

if [[ ! -d "$APP/Contents" ]]; then
  echo "Missing app bundle: $APP — run scripts/build-macos-app.sh first." >&2
  exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/RelayDock-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/RelayDock.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUTPUT"
hdiutil create -volname "RelayDock" -srcfolder "$STAGING" -format UDZO -ov "$OUTPUT" >/dev/null

test -s "$OUTPUT"

# Round-trip check: the image mounts read-only and holds the app plus the
# drop target, so a broken layout fails here instead of at a user's first open.
MOUNTPOINT="$STAGING/mount"
mkdir -p "$MOUNTPOINT"
hdiutil attach "$OUTPUT" -nobrowse -readonly -mountpoint "$MOUNTPOINT" >/dev/null
test -d "$MOUNTPOINT/RelayDock.app/Contents/MacOS"
test -L "$MOUNTPOINT/Applications"
hdiutil detach "$MOUNTPOINT" >/dev/null

echo "Built $OUTPUT"
