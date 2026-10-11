#!/bin/zsh
# Builds Konfig and assembles the .app bundle (ad-hoc signature, for local use).
set -e
cd "$(dirname "$0")"

# Every NSLocalizedString key in the source must be translated in every language.
keys=$(grep -ho 'NSLocalizedString("[^"]*"' Sources/**/*.swift | cut -d'"' -f2 | sort -u)
for strings in Resources/*.lproj/Localizable.strings; do
    plutil -lint -s "$strings"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        grep -qF "\"$key\" =" "$strings" || { echo "Missing \"$key\" in $strings" >&2; exit 1; }
    done <<< "$keys"
done

swift build -c release --product Konfig
BIN="$(swift build -c release --show-bin-path)/Konfig"

APP=Konfig.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Konfig"
# app icon: generated from icon/konfig.svg by icon/make-icon.sh
cp icon/Konfig.icns "$APP/Contents/Resources/Konfig.icns"
# one folder per language: UI strings, document type names, and AppKit's own texts ("Edited", alerts)
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "OK: $PWD/$APP"
echo "To open a file: open -a $PWD/$APP examples/config.toml"
