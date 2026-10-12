#!/bin/zsh
# Builds Konfig and assembles the .app bundle (ad-hoc signature, for local use).
# --install: also replaces /Applications/Konfig.app, the copy Finder's "Open With" uses.
set -e
cd "$(dirname "$0")"

install=false
case "$1" in
    "") ;;
    --install) install=true ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

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
# build number = commit count; KonfigCommit = short hash (+ "-dirty" when tracked files differ from it), shown in the sidebar
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" \
    -c "Add :KonfigCommit string $commit" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Konfig"
# app icon: generated from icon/konfig.svg by icon/make-icon.sh
cp icon/Konfig.icns "$APP/Contents/Resources/Konfig.icns"
# one folder per language: UI strings, document type names, and AppKit's own texts ("Edited", alerts)
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "OK: $PWD/$APP ($commit)"

if $install; then
    DEST=/Applications/Konfig.app
    [[ -d "$DEST" ]] && rm -r "$DEST"
    ditto "$APP" "$DEST"
    # re-register: refreshes the icon and document types Launch Services had cached from the old copy
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    echo "Installed: $DEST"
    pgrep -xq Konfig && echo "Konfig is open: the old version keeps running until you quit it (⌘Q) and reopen it."
else
    echo "To open a file: open -a $PWD/$APP examples/config.toml"
fi
