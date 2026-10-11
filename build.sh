#!/bin/zsh
# Compila o Konfig e monta o bundle .app (assinatura ad-hoc, uso local).
set -e
cd "$(dirname "$0")"

swift build -c release --product Konfig
BIN="$(swift build -c release --show-bin-path)/Konfig"

APP=Konfig.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pt-BR.lproj"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Konfig"
# ícone do app: gerado de icone/konfig.svg por icone/gerar.sh
cp icone/Konfig.icns "$APP/Contents/Resources/Konfig.icns"
# pasta de idioma: faz o AppKit usar português nos textos prontos ("Editado", avisos)
printf '"CFBundleName" = "Konfig";\n' > "$APP/Contents/Resources/pt-BR.lproj/InfoPlist.strings"
codesign --force --sign - "$APP"

echo "OK: $PWD/$APP"
echo "Para abrir um arquivo: open -a $PWD/$APP exemplos/config.toml"
