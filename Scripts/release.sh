#!/bin/bash
# Empacota uma versão para distribuir: LingoSync.dmg e LingoSync.zip.
#
#   Scripts/release.sh <versao>        ex.: Scripts/release.sh 1.0.0
#
# O .dmg traz o atalho para Aplicativos, que é o jeito de instalar que todo
# usuário de Mac conhece. A assinatura é ad-hoc: sem conta de desenvolvedor
# não há notarização, e o README explica como passar pelo Gatekeeper na
# primeira abertura.
set -euo pipefail

VERSION="${1:?uso: Scripts/release.sh <versao>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

rm -rf "$OUT"
mkdir -p "$OUT"

# O SDK 27 das Command Line Tools vem sem o plugin SwiftUIMacros; o 26.5 compila.
if [ -d "$SDK" ]; then export SDKROOT="$SDK"; fi
swift build -c release --product TradutorApp --package-path "$ROOT"

# A versão entra numa cópia do Info.plist, antes da assinatura — mexer no
# plist depois de assinar invalida o selo.
PLIST="build/release/Info.plist"
cp "$ROOT/Resources/app-Info.plist" "$ROOT/$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$ROOT/$PLIST"

# O bundle.sh monta com o nome do executável ("Tradutor", o que o plist
# declara) e grava em build/. Monta numa pasta à parte para não apagar o
# build/Tradutor.app de quem está desenvolvendo, e renomeia depois: o nome
# da pasta .app não entra na assinatura.
STAGE="$(mktemp -d)"
cp -R "$ROOT/build/Tradutor.app" "$STAGE/dev.app" 2>/dev/null || true
"$ROOT/Scripts/bundle.sh" TradutorApp "Tradutor" "$PLIST" release
mv "$ROOT/build/Tradutor.app" "$OUT/LingoSync.app"
if [ -d "$STAGE/dev.app" ]; then mv "$STAGE/dev.app" "$ROOT/build/Tradutor.app"; fi

# Sem os símbolos de depuração o executável cai pela metade, e o .dmg fica
# abaixo dos 10 MB que o envio pelo navegador aceita. Tirar símbolos mexe no
# binário, então a assinatura é refeita com os mesmos direitos.
strip -x "$OUT/LingoSync.app/Contents/MacOS/Tradutor"
codesign --force --deep --sign - --options runtime \
    --entitlements "$ROOT/Resources/app.entitlements" "$OUT/LingoSync.app"
codesign --verify --deep --strict "$OUT/LingoSync.app"

ditto -c -k --keepParent "$OUT/LingoSync.app" "$OUT/LingoSync.zip"

DMG_DIR="$STAGE/dmg"
mkdir -p "$DMG_DIR"
cp -R "$OUT/LingoSync.app" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "LingoSync $VERSION" -srcfolder "$DMG_DIR" -ov -format ULMO \
    "$OUT/LingoSync.dmg" >/dev/null
rm -rf "$STAGE" "$ROOT/$PLIST"

(cd "$OUT" && shasum -a 256 LingoSync.dmg LingoSync.zip > SHA256SUMS.txt)
echo "pronto: $OUT"
ls -lh "$OUT"
