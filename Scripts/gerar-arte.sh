#!/usr/bin/env bash
# Regera toda a arte a partir do motor: docs/art/*.svg, prévias dos clipes,
# SVGs dos stickers e o iconset do app.
#
# O CI (linux-core) roda o glyph-art e falha se o resultado mudar sem commit.
# O iconset precisa de rsvg-convert ou do pacote Python cairosvg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift run glyph-art

ICONSET="Apps/Glyph/AppIcon.iconset"
mkdir -p "$ICONSET"
render() { # tamanho arquivo
  if command -v rsvg-convert >/dev/null; then
    rsvg-convert -w "$1" -h "$1" docs/art/icon.svg -o "$2"
  elif python3 -c "import cairosvg" 2>/dev/null; then
    python3 -c "import cairosvg,sys; cairosvg.svg2png(url='docs/art/icon.svg', write_to=sys.argv[2], output_width=int(sys.argv[1]), output_height=int(sys.argv[1]))" "$1" "$2"
  else
    echo "aviso: sem rsvg-convert nem cairosvg; iconset não regerado" >&2
    return 1
  fi
}
for size in 16 32 128 256 512; do
  render "$size" "$ICONSET/icon_${size}x${size}.png" || exit 0
  render "$((size * 2))" "$ICONSET/icon_${size}x${size}@2x.png"
done
echo "ok $ICONSET"
