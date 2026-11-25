#!/usr/bin/env bash
# Phase 1 entry point. Commands not yet ported retain the Bash implementation.
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
  status | ls | screen | wait) ;;
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
# Encode argv without jq or a helper process. Work bytewise so UTF-8 passes unchanged.
json_string() {
  local LC_ALL=C v="$1" c i
  printf '"'
  for ((i=0; i<${#v}; i++)); do
    c=${v:i:1}
    case "$c" in
      '"' | "\\") printf '\\%s' "$c" ;;
      [[:cntrl:]]) printf '\\u%04x' "'$c" ;;
      *) printf '%s' "$c" ;;
    esac
  done
  printf '"'
}
args=$(printf '{"script_dir":'; json_string "$SCRIPT_DIR"; printf ',"argv":['
  sep=''; for arg in "$@"; do printf '%s' "$sep"; json_string "$arg"; sep=,; done; printf ']}')
# Keep wait alive long enough to handle destruction of its target's session itself.
if [ "$1" = wait ]; then
  exec "$REX" "do" "$SCRIPT_DIR/lua/main.lua" --args "$args" --fail-fast --all
fi
# Let Lua resolve REX_BLOCK/REX_SESSION so missing context retains the public usage error.
exec "$REX" "do" "$SCRIPT_DIR/lua/main.lua" --args "$args" --fail-fast
