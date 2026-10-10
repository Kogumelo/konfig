#!/bin/zsh
# Compila o km-conf e monta o bundle .app (assinatura ad-hoc, uso local).
set -e
cd "$(dirname "$0")"

swift build -c release --product km-conf
BIN="$(swift build -c release --show-bin-path)/km-conf"

APP=km-conf.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pt-BR.lproj"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/km-conf"
# pasta de idioma: faz o AppKit usar português nos textos prontos ("Editado", avisos)
printf '"CFBundleName" = "km-conf";\n' > "$APP/Contents/Resources/pt-BR.lproj/InfoPlist.strings"
codesign --force --sign - "$APP"

echo "OK: $PWD/$APP"
echo "Para abrir um arquivo: open -a $PWD/$APP exemplos/config.toml"
