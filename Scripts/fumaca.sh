#!/bin/sh
# Teste de fumaça do glyphd de verdade (não só das bibliotecas): o binário
# responde, abre o socket e aceita um agente externo pelo protocolo glyph-brain/1.
# Uso: Scripts/fumaca.sh  (depois de swift build)
set -eu
BIN="$(swift build --show-bin-path)/glyphd"
GLYPH_HOME="$(mktemp -d)"
export GLYPH_HOME
trap 'kill "$PID" 2>/dev/null || true; rm -rf "$GLYPH_HOME"' EXIT
mkdir -p "$GLYPH_HOME/casa"
printf 'cerebro:\n  principal:\n    provider: offline\n' > "$GLYPH_HOME/casa/config.yaml"

echo "· ask (offline)"
timeout 20 "$BIN" ask "oi" | grep -q "oi!"

echo "· run abre o socket"
"$BIN" run --offline > "$GLYPH_HOME/run.log" 2>&1 &
PID=$!
i=0
until "$BIN" status > /dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then cat "$GLYPH_HOME/run.log"; echo "glyphd run não abriu o socket"; exit 1; fi
  sleep 0.1
done
kill "$PID"

echo "· agente externo (glyph-brain/1)"
cat > "$GLYPH_HOME/agente.sh" <<'AG'
#!/bin/sh
while IFS= read -r line; do
  rid=$(printf '%s' "$line" | sed -n 's/^{"id":"\([^"]*\)".*/\1/p')
  printf '{"type":"brain.reply","id":"%s","text":"resposta do agente","stop":"done"}\n' "$rid"
done
AG
chmod +x "$GLYPH_HOME/agente.sh"
printf 'cerebro:\n  principal:\n    provider: externo\n    comando: [%s]\n' "$GLYPH_HOME/agente.sh" > "$GLYPH_HOME/casa/config.yaml"
timeout 20 "$BIN" ask "oi" | grep -q "resposta do agente"

echo "· modo ensaio: prévia, aplicar, desfazer"
PASTA="$GLYPH_HOME/Downloads"
mkdir -p "$PASTA"
echo c > "$PASTA/contrato.pdf"
echo f > "$PASTA/foto.png"
touch -t 202601010000 "$PASTA/contrato.pdf" "$PASTA/foto.png"
printf 'ferramentas:\n  organizar:\n    pastas: [%s]\n' "$PASTA" > "$GLYPH_HOME/casa/config.yaml"
ID=$("$BIN" ensaio "$PASTA" | tee "$GLYPH_HOME/ensaio.log" | sed -n 's/.*glyphd ensaio aplicar //p')
grep -q "2 arquivos seriam movidos" "$GLYPH_HOME/ensaio.log"
test -f "$PASTA/contrato.pdf"  # ensaiar não mexe
"$BIN" ensaio aplicar "$ID" --sim | grep -q "movi 2"
test -f "$PASTA/PDFs/contrato.pdf" && test -f "$PASTA/Imagens/foto.png"
"$BIN" porque | grep -q "plano $ID"
"$BIN" ensaio desfazer "$ID" | grep -q "2 de volta"
test -f "$PASTA/contrato.pdf" && test ! -e "$PASTA/PDFs"
if "$BIN" ensaio "$GLYPH_HOME" > /dev/null 2>&1; then echo "ensaiou fora das pastas permitidas"; exit 1; fi

echo "ok"
