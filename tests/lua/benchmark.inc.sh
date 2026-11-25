# shellcheck shell=bash disable=SC2154
# Sourced by live.sh: shares only that test's throwaway Rex server and stand-in.
benchmark() {
  local name=$1 command=$2 impl=$3 path="$OLD" out trace timing measurement trigger
  out="$T/$name.out"; trace="$T/$name.trace"; timing="$T/$name.time"
  [ "$impl" != lua ] || path="$CLI"
  : > "$trace"
  : > "$trace.lua"
  for measurement in wall count; do
    if [ "$command" = wait ]; then
      type_line working; await_state working
      (sleep 1; type_line 'done') &
      trigger=$!
    fi
    if [ "$measurement" = wall ]; then
      # Measure the normal command. Tracing would disproportionately slow the Bash baseline.
      /usr/bin/time -p /opt/homebrew/bin/bash "$path" "$command" "$B" > "$out" 2>"$timing"
    else
      BASH_XTRACEFD=9 REX_LUA_TRACE="$trace.lua" /opt/homebrew/bin/bash -x "$path" "$command" "$B" > "$out" 9>>"$trace" 2>"$T/trace.err"
    fi
    if [ "$command" = wait ]; then
      wait "$trigger"
      grep -qx 'done' "$out"
    else
      jq -e '.state == "done" and .alive' "$out" >/dev/null
    fi
  done
  local wall count
  wall=$(awk '$1=="real" {print $2}' "$timing")
  count=$(luajit "$ROOT/tests/lua/trace-count.lua" "$trace" "$trace.lua")
  printf '%s\t%s\t%s\t%s\n' "$impl" "$command" "$wall" "$count" >> "$REX_LUA_BENCHMARK"
}
# Only do calls are instrumented; every other call still uses the original test shim.
# shellcheck disable=SC2016 # The generated shim expands its own arguments.
printf '#!/bin/bash\nif [ "$1" = do ] && [ -n "$REX_LUA_TRACE" ]; then shift 2; exec %q --autostart=false do %q "$@"; fi\nexec %q --autostart=false "$@"\n' \
  "$REAL_REX" "$ROOT/tests/lua/profile.lua" "$REAL_REX" > "$T/bin/rex"
unset REX_BLOCK REX_LUA_TRACE
rm -f "$sf" "$sf.own"
type_line 'done'; await_state 'done'
printf 'implementation\tcommand\twall_seconds\texternal_processes\n' > "$REX_LUA_BENCHMARK"
for sample in 1 2 3 4 5; do benchmark "status-bash-$sample" status bash; benchmark "status-lua-$sample" status lua; done
for sample in 1 2 3; do benchmark "wait-bash-$sample" wait bash; benchmark "wait-lua-$sample" wait lua; done
# Restore the simple shim before the remaining integration checks.
printf '#!/bin/bash\nexec %q --autostart=false "$@"\n' "$REAL_REX" > "$T/bin/rex"
