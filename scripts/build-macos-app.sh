#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/macOS/RelayDock"
OUTPUT="$ROOT/build/RelayDock.app"
ICONSET="$PACKAGE/.build/RelayDock.iconset"
ICON_SOURCE="$PACKAGE/Assets/RelayDockAppIcon.png"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing app icon: $ICON_SOURCE" >&2
  exit 1
fi

swift build --package-path "$PACKAGE" --configuration release

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources" "$ICONSET"
cp "$PACKAGE/.build/release/RelayDock" "$OUTPUT/Contents/MacOS/RelayDock"
cp "$ROOT/macOS/Info.plist" "$OUTPUT/Contents/Info.plist"

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
iconutil -c icns "$ICONSET" -o "$OUTPUT/Contents/Resources/AppIcon.icns"

echo "Built $OUTPUT"
