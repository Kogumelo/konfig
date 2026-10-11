#!/bin/zsh
# Gera icone/Konfig.icns a partir de icone/konfig.svg.
# Rodar só quando o desenho mudar: o .icns fica versionado e o build.sh apenas o copia.
set -e
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT

# o conversor usa a leitura de SVG do próprio macOS (NSImage); não precisa de rsvg-convert nem ImageMagick
swiftc -O svg2png.swift -o "$TMP/svg2png"

mkdir "$TMP/Konfig.iconset"
for n in 16 32 128 256 512; do
  "$TMP/svg2png" konfig.svg "$TMP/Konfig.iconset/icon_${n}x${n}.png" $n
  "$TMP/svg2png" konfig.svg "$TMP/Konfig.iconset/icon_${n}x${n}@2x.png" $((n * 2))
done
iconutil -c icns "$TMP/Konfig.iconset" -o Konfig.icns

echo "OK: $PWD/Konfig.icns"
