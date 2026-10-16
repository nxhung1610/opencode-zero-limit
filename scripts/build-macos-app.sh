#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macOS/RelayDock"
OUTPUT="$ROOT/build/RelayDock.app"
ICON_SOURCE="$PACKAGE/Assets/RelayDockAppIcon.png"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing app icon: $ICON_SOURCE" >&2
  exit 1
fi

mkdir -p "$ROOT/build" "$PACKAGE/.build"

swift build --package-path "$PACKAGE" --configuration release

STAGING_ROOT="$(mktemp -d "$PACKAGE/.build/RelayDock-app.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
BUNDLE="$STAGING_ROOT/RelayDock.app"
ICONSET="$STAGING_ROOT/RelayDock.iconset"

mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$ICONSET"
cp "$PACKAGE/.build/release/RelayDock" "$BUNDLE/Contents/MacOS/RelayDock"
cp "$ROOT/macOS/Info.plist" "$BUNDLE/Contents/Info.plist"

while read -r size name; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$name" >/dev/null
done <<'ICONS'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
ICONS

iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
plutil -lint "$BUNDLE/Contents/Info.plist"
test -x "$BUNDLE/Contents/MacOS/RelayDock"
test -s "$BUNDLE/Contents/Resources/AppIcon.icns"

if [[ -e "$OUTPUT" ]]; then
  if [[ ! -d "$OUTPUT/Contents" ]]; then
    echo "Refusing to replace a non-app path: $OUTPUT" >&2
    exit 1
  fi
  mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
  cp -f "$BUNDLE/Contents/Info.plist" "$OUTPUT/Contents/Info.plist"
  cp -f "$BUNDLE/Contents/MacOS/RelayDock" "$OUTPUT/Contents/MacOS/RelayDock"
  cp -f "$BUNDLE/Contents/Resources/AppIcon.icns" "$OUTPUT/Contents/Resources/AppIcon.icns"
else
  mv "$BUNDLE" "$OUTPUT"
fi

plutil -lint "$OUTPUT/Contents/Info.plist"
test -x "$OUTPUT/Contents/MacOS/RelayDock"
test -s "$OUTPUT/Contents/Resources/AppIcon.icns"
echo "Built $OUTPUT"
