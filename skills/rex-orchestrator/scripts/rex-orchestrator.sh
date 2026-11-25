#!/usr/bin/env bash
# Launch, clone and help retain the Bash implementation.
set -euo pipefail
unset CDPATH
SCRIPT_SRC=$0
while [ -L "$SCRIPT_SRC" ]; do
  SCRIPT_PARENT=$(cd "$(dirname "$SCRIPT_SRC")" && pwd -P)
  SCRIPT_LINK=$(readlink "$SCRIPT_SRC")
  case "$SCRIPT_LINK" in
    /*) SCRIPT_SRC=$SCRIPT_LINK ;;
    *) SCRIPT_SRC="$SCRIPT_PARENT/$SCRIPT_LINK" ;;
  esac
done
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_SRC")" && pwd -P)
case "${1:-help}" in
  status | ls | screen | wait | send | keys | close | claims) ;;
  *) exec "$BASH" "$SCRIPT_DIR/rex-orchestrator-bash.sh" "$@" ;;
esac
REX="${REX_ORCHESTRATOR_REX_BIN_DIR:+$REX_ORCHESTRATOR_REX_BIN_DIR/}rex"
if ! command -v "$REX" >/dev/null 2>&1; then
  for app in "/Applications/Rex Beta.app" "/Applications/Rex.app" "$HOME/Applications/Rex Beta.app" "$HOME/Applications/Rex.app"; do
    REX="$app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    [ -x "$REX" ] && break
    REX=""
  done
  [ -n "$REX" ] || { echo "rex-orchestrator: rex is not on PATH and no Rex app bundle was found; set REX_ORCHESTRATOR_REX_BIN_DIR" >&2; exit 2; }
fi
# Rex's JSON decoder replaces invalid UTF-8. Transport argv as bytes so
# diagnostics and file arguments retain the same spelling as in Bash.
json_string() {
  local LC_ALL=C v="$1" bytes="$2" c i byte
  printf '"'
  for ((i=0; i<${#v}; i++)); do
    c=${v:i:1}
    case "$c" in
      '"' | "\\") printf '\\%s' "$c" ;;
      [[:cntrl:]]) printf '\\u%04x' "'$c" ;;
      [$'\200'-$'\377'])
        if [ "$bytes" = yes ]; then
          printf -v byte '%d' "'$c"
          printf '\\u00%02x' "$((byte & 255))"
        else
          printf '%s' "$c"
        fi ;;
      *) printf '%s' "$c" ;;
    esac
  done
  printf '"'
}
args=$(printf '{"forward_errors":true,"script_dir":'; json_string "$SCRIPT_DIR" no
  printf ',"rex_bin":'; json_string "$REX" no
  printf ',"session":'; json_string "${REX_SESSION:-}" yes
  printf ',"block":'; json_string "${REX_BLOCK:-}" yes
  printf ',"argv":['
  sep=''; for arg in "$@"; do printf '%s' "$sep"; json_string "$arg" yes; sep=,; done; printf ']}')
run_lua() {
  local command=$1 diagnostics line rc=0
  local flags=(--fail-fast)
  # Keep wait alive long enough to handle destruction of its target's session itself.
  if [ "$command" = wait ]; then flags+=(--all); fi
  # Let Lua resolve explicit targets even when their session has no focused block.
  diagnostics=$(REX_SESSION='' REX_BLOCK='' "$REX" "do" "$SCRIPT_DIR/lua/main.lua" --args - "${flags[@]}" 4>&2 2>&1 >&3 <<<"$args") || rc=$?
  case "$diagnostics" in
    'Error: unknown flag: --all'* | 'Error: unknown flag: --fail-fast'* | 'Error: unknown flag: --args'* | 'Error: unknown command "do"'*)
      printf '%s\n' 'rex-orchestrator: this Rex CLI lacks rex do with --args, --all and --fail-fast; update Rex' >&2
      return 1 ;;
    'Error: REX_SERVER: no Rex server is running '* | 'Error: no Rex server is running '*)
      # Rex failed before executing Lua. Preserve startup diagnostics and offline dead-claim pruning.
      if [ "$rc" = 4 ]; then "$BASH" "$SCRIPT_DIR/rex-orchestrator-bash.sh" "$@" >&3; return $?; fi ;;
  esac
  while IFS= read -r line; do
    case "$line" in '' | 'listening: '*'; Ctrl-C to stop') ;; *) printf '%s\n' "$line" >&2 ;; esac
  done <<<"$diagnostics"
  return "$rc"
}
if [ "$1" = wait ]; then
  rc=0
  result=$(run_lua "$@" 3>&1) || rc=$?
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
  elif [ "$rc" = 0 ] || [ "$rc" = 4 ]; then
    printf '%s\n' 'rex-orchestrator: rex did not answer' >&2
    rc=1
  fi
  exit "$rc"
fi
run_lua "$@" 3>&1
