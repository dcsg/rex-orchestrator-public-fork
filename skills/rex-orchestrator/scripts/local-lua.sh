#!/bin/bash
# Resolve the standalone Lua interpreter even when the caller's PATH is minimal.
set -euo pipefail
script_dir=${BASH_SOURCE[0]%/*}
for lua in /opt/homebrew/bin/luajit /usr/local/bin/luajit "$(type -P luajit || :)"; do
  if [ -x "$lua" ]; then
    exec "$lua" -E "$script_dir/lua/local.lua" "$@"
  fi
done
printf '%s\n' 'rex-orchestrator: LuaJIT is not installed or on PATH' >&2
exit 2
