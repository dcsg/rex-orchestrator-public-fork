#!/bin/bash
# Resolve the standalone Lua interpreter even when the caller's PATH is minimal.
set -euo pipefail
script_dir=${BASH_SOURCE[0]%/*}
for lua in /opt/homebrew/bin/luajit /usr/local/bin/luajit "$(type -P luajit || :)"; do
  if [ -x "$lua" ]; then
    exec "$lua" -E "$script_dir/lua/local.lua" "$@"
  fi
done
# Print $1 with its C0 controls and DEL shown as \xNN, never raw, so caller- or filesystem-supplied text can't drive
# the terminal. Backslashes stay as they are: Lua's diagnostics arrive here already escaped.
rex_term_text() (
  export LC_ALL=C
  s=$1
  case $s in *[[:cntrl:]]*) ;; *) printf '%s' "$s"; exit 0 ;; esac
  while [ -n "$s" ]; do
    c=${s%"${s#?}"}; s=${s#?}
    case $c in [[:cntrl:]]) printf '\\x%02X' "'$c" ;; *) printf '%s' "$c" ;; esac
  done
)
operation=${1:-this operation}
case "$operation" in
  offline)
    printf '%s\n' 'rex-orchestrator: Rex is not running. Offline checks require LuaJIT. Install it with brew install luajit.' >&2
    exit 1 ;;
  validate-agy) operation='agy token validation' ;;
esac
printf 'rex-orchestrator: %s requires LuaJIT. Install it with brew install luajit.\n' "$(rex_term_text "$operation")" >&2
case "${1:-}" in harvest | validate-agy) exit 69 ;; *) exit 2 ;; esac
