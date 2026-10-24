#!/usr/bin/env bash
# Packages build/RelayDock.app into a drag-to-Applications RelayDock.dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/RelayDock.app"
OUTPUT="$ROOT/build/RelayDock.dmg"
BACKGROUND="$ROOT/brand/dmg-background.png"
VOLUME_NAME="RelayDock"
LAYOUT_VOLUME_NAME="RelayDock Layout $$"

if [[ ! -d "$APP/Contents" ]]; then
  echo "Missing app bundle: $APP — run scripts/build-macos-app.sh first." >&2
  exit 1
fi
if [[ ! -f "$BACKGROUND" ]]; then
  echo "Missing DMG background: $BACKGROUND" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/RelayDock-dmg.XXXXXX")"
STAGING="$WORK/staging"
MOUNT="$WORK/$LAYOUT_VOLUME_NAME"
RW_DMG="$WORK/RelayDock-rw.dmg"
LAYOUT_SCRIPT="$WORK/layout.applescript"

cleanup() {
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$STAGING" "$MOUNT"
ditto "$APP" "$STAGING/RelayDock.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"
cp "$BACKGROUND" "$STAGING/.background/dmg-background.png"

# Build a writable image first so Finder can store the window layout and
# background choice in .DS_Store, then compress it read-only.
rm -f "$RW_DMG" "$OUTPUT"
hdiutil create -volname "$LAYOUT_VOLUME_NAME" -srcfolder "$STAGING" -format UDRW -fs HFS+ -ov "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -nobrowse -readwrite -mountpoint "$MOUNT" >/dev/null

cat > "$LAYOUT_SCRIPT" <<APPLESCRIPT
tell application "Finder"
  tell disk "$LAYOUT_VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 860, 648}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 12
    set background picture of theViewOptions to file ".background:dmg-background.png"
    set position of item "RelayDock.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Finder is the only supported way to write a disk-image layout. Keep the
# build usable if it is unavailable (for example, a headless CI session).
if ! osascript "$LAYOUT_SCRIPT"; then
  echo "Warning: Finder layout failed; the DMG will use the default icon layout." >&2
fi
sync

# Set the volume icon after Finder has touched the image: Finder clears a
# custom icon that was present before the window layout was written.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
if [[ -x /usr/bin/SetFile ]]; then
  /usr/bin/SetFile -a C "$MOUNT"
fi
sync

# Use a unique name while Finder works on the image, then give the finished
# volume the public name. This avoids targeting another mounted RelayDock.dmg.
diskutil rename "$MOUNT" "$VOLUME_NAME" >/dev/null
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT" >/dev/null

test -s "$OUTPUT"

# Round-trip check: the image mounts read-only and holds the app, the drop
# target, the background used by the Finder window, and the volume icon.
hdiutil attach "$OUTPUT" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
test -d "$MOUNT/RelayDock.app/Contents/MacOS"
test -L "$MOUNT/Applications"
test -f "$MOUNT/.background/dmg-background.png"
test -f "$MOUNT/.VolumeIcon.icns"
hdiutil detach "$MOUNT" >/dev/null

echo "Built $OUTPUT"
