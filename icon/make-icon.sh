#!/bin/zsh
# Generates icon/Konfig.icns from icon/konfig.svg.
# Run it only when the drawing changes: the .icns is versioned and build.sh just copies it.
set -e
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

# the converter uses macOS's own SVG support (NSImage); no need for rsvg-convert or ImageMagick
swiftc -O svg2png.swift -o "$TMP/svg2png"

mkdir "$TMP/Konfig.iconset"
for n in 16 32 128 256 512; do
  "$TMP/svg2png" konfig.svg "$TMP/Konfig.iconset/icon_${n}x${n}.png" $n
  "$TMP/svg2png" konfig.svg "$TMP/Konfig.iconset/icon_${n}x${n}@2x.png" $((n * 2))
done
iconutil -c icns "$TMP/Konfig.iconset" -o Konfig.icns

echo "OK: $PWD/Konfig.icns"
