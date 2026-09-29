#!/usr/bin/env bash
# Monta build/Glyph.app a partir do executável do SwiftPM.
#
#   Scripts/bundle-app.sh            # debug
#   Scripts/bundle-app.sh release    # release
#
# Assinatura: por padrão assina ad hoc ("-"). Para distribuir sem aviso do
# Gatekeeper é preciso Developer ID + notarização:
#   GLYPH_SIGN_IDENTITY="Developer ID Application: ..." Scripts/bundle-app.sh release
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "erro: o app só compila no macOS" >&2
  exit 1
fi

swift build -c "$CONFIG" --product Glyph
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Glyph"

APP="$ROOT/build/Glyph.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glyph"
cp "$ROOT/Apps/Glyph/Info.plist" "$APP/Contents/Info.plist"
if [[ -d "$ROOT/Packs/default" ]]; then
  cp -R "$ROOT/Packs/default" "$APP/Contents/Resources/Pack"
fi
if [[ -d "$ROOT/Apps/Glyph/AppIcon.iconset" ]]; then
  iconutil -c icns "$ROOT/Apps/Glyph/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${GLYPH_SIGN_IDENTITY:--}"
codesign --force --options runtime \
  --entitlements "$ROOT/Apps/Glyph/Glyph.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "ok: $APP"
echo "rodar:      open \"$APP\""
echo "modo mock:  GLYPH_MOCK=1 \"$APP/Contents/MacOS/Glyph\""
