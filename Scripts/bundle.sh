#!/bin/bash
# Monta um .app a partir de um executavel do SwiftPM.
#
# Nao ha Xcode nesta maquina, entao o bundle e montado a mao. Isso e suficiente:
# um .app e uma pasta com estrutura conhecida, e o que o sistema exige para
# conceder permissoes e a identidade de codigo mais o Info.plist -- nao o Xcode.
#
#   Scripts/bundle.sh <nome-do-executavel> <Nome Do App> <Info.plist> [debug|release]
set -euo pipefail

EXECUTABLE="$1"
APP_NAME="$2"
PLIST="$3"
CONFIG="${4:-debug}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/build/$APP_NAME.app"

if [ ! -x "$BUILD_DIR/$EXECUTABLE" ]; then
    echo "executavel nao encontrado: $BUILD_DIR/$EXECUTABLE"
    echo "rode antes:  swift build -c $CONFIG"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/$PLIST" "$APP/Contents/Info.plist"

# So existe para quem tem CFBundleIconFile no Info.plist (hoje, o app
# principal); copiar sem uso nao atrapalha o probe.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Modelos ficam fora do bundle, baixados no primeiro uso. Gigabytes dentro do
# .app tornariam a assinatura lenta e a distribuicao impraticavel.
printf 'APPL????' > "$APP/Contents/PkgInfo"


codesign --force --deep --sign - \
    --options runtime \
    --entitlements "$ROOT/Resources/app.entitlements" \
    "$APP" 2>&1 | sed 's/^/  /'

echo "montado: $APP"
