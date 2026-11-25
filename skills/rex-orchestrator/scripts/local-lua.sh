#!/bin/bash
# Resolve the standalone Lua interpreter even when the caller's PATH is minimal.
set -euo pipefail
script_dir=${BASH_SOURCE[0]%/*}
for lua in /opt/homebrew/bin/luajit /usr/local/bin/luajit "$(type -P luajit || :)"; do
  if [ -x "$lua" ]; then
    exec "$lua" -E "$script_dir/lua/local.lua" "$@"
  fi
done
operation=${1:-this operation}
case "$operation" in
  offline) operation=${2:-this operation} ;;
  validate-agy) operation='agy token validation' ;;
esac
printf 'rex-orchestrator: %s requires LuaJIT. Install it with brew install luajit.\n' "$operation" >&2
case "${1:-}" in harvest | validate-agy) exit 69 ;; *) exit 2 ;; esac
