# glyph-shell.zsh — sensor de terminal do Glyph (opt-in).
#
# Instale adicionando ao ~/.zshrc:
#   source /caminho/para/Glyph/Scripts/glyph-shell.zsh
#
# O que envia ao glyphd (socket local, só o seu usuário): o comando e a pasta
# quando ele começa; o código de saída e a duração quando termina. NÃO lê a
# tela nem a saída dos comandos.
# Comandos que começam com espaço não são enviados.

zmodload zsh/datetime 2>/dev/null
zmodload zsh/net/socket 2>/dev/null || return 0

typeset -g _glyph_cmd=""
typeset -g _glyph_start=0
typeset -g _glyph_sock="${GLYPH_SENSOR_SOCK:-${GLYPH_HOME:-$HOME/Library/Application Support/Glyph}/sensors.sock}"

_glyph_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\t'/ }
  print -rn -- "$s"
}

_glyph_preexec() {
  # Espaço na frente = privado.
  if [[ "$1" == " "* ]]; then _glyph_cmd=""; return; fi
  _glyph_cmd="$1"
  _glyph_start=$EPOCHREALTIME
  [[ -S "$_glyph_sock" ]] || return
  # Começou (um build rodando deixa o Glyph explorar).
  local line="{\"kind\":\"shell.start\",\"cmd\":\"$(_glyph_json_escape "$1")\",\"cwd\":\"$(_glyph_json_escape "$PWD")\"}"
  ( zsocket "$_glyph_sock" 2>/dev/null && print -r -- "$line" >&$REPLY; exec {REPLY}>&- ) &!
}

_glyph_precmd() {
  local code=$?
  [[ -n "$_glyph_cmd" && -S "$_glyph_sock" ]] || { _glyph_cmd=""; return; }
  local dur=$(( EPOCHREALTIME - _glyph_start ))
  local line="{\"kind\":\"shell.exit\",\"cmd\":\"$(_glyph_json_escape "$_glyph_cmd")\",\"code\":$code,\"cwd\":\"$(_glyph_json_escape "$PWD")\",\"duration\":$(printf '%.2f' $dur)}"
  _glyph_cmd=""
  # Em segundo plano e sem esperar: o prompt nunca fica mais lento.
  ( zsocket "$_glyph_sock" 2>/dev/null && print -r -- "$line" >&$REPLY; exec {REPLY}>&- ) &!
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _glyph_preexec
add-zsh-hook precmd _glyph_precmd
