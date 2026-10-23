#!/usr/bin/env bash
# Derive the menu bar template from the actual shipped app icon, not the
# historical brand/icon.svg. ImageMagick is a development-only dependency.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/macOS/RelayDock/Assets/RelayDockAppIcon.png"
OUTPUT="$ROOT/macOS/RelayDock/Sources/RelayDockApp/Resources"
mkdir -p "$OUTPUT"

for scale in 1 2; do
  width=$((18 * scale))
  height=$((16 * scale))
  suffix=""
  if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
  # The source mark is white on black. Its luminance becomes alpha; remove
  # faint background shading, preserve the original contour and crossing gap,
  # then rasterize to a black mask with transparent padding.
  magick "$SOURCE" -alpha off -colorspace gray -level '12%,95%' \
    -trim +repage -resize "${width}x${height}" \
    -gravity center -background black -extent "${width}x${height}" \
    \( +clone -fill black -colorize 100 \) +swap \
    -alpha off -compose CopyOpacity -composite -strip \
    "PNG32:$OUTPUT/MenuBarIconTemplate$suffix.png"
done
