#!/usr/bin/env bash
# All Rex operations are confined to this script's throwaway socket and state.
set -euo pipefail
unset CDPATH
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
REAL_REX=${REX_TEST_REX:-$(command -v rex)}
T=$(mktemp -d /tmp/rex-lua-live.XXXXXX)
server_pid=''
cleanup() { [ -z "$server_pid" ] || { kill "$server_pid" 2>/dev/null || :; wait "$server_pid" 2>/dev/null || :; }; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/home" "$T/config" "$T/data" "$T/cache" "$T/work" "$T/bin"
: > "$T/init.lua"
export HOME="$T/home" XDG_CONFIG_HOME="$T/config" XDG_DATA_HOME="$T/data" XDG_CACHE_HOME="$T/cache"
export REX_SERVER="unix://$T/rex.sock" REX_BLOCK='' REX_SESSION='' REX_CONFIG="$T/init.lua"
export REX_ORCHESTRATOR_STATE_DIR="$T/orchestrator-state"
# The entry script still execs rex; this shim ensures even that call cannot autostart a server.
printf '#!/bin/bash\nexec %q --autostart=false "$@"\n' "$REAL_REX" > "$T/bin/rex"
chmod +x "$T/bin/rex"
export REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin"
rex_test() { "$REAL_REX" --autostart=false "$@"; }
rex_test server run --listen "$REX_SERVER" --state-dir "$T/state" --restore=false --config "$T/init.lua" > "$T/server.log" 2>&1 &
server_pid=$!
for ((n=0;n<100;n++)); do [ ! -S "$T/rex.sock" ] || break; sleep 0.05; done
[ -S "$T/rex.sock" ] || { cat "$T/server.log" >&2; exit 1; }
rex_test session new lua-test --shell none --keep-open --json -- /bin/bash "$ROOT/tests/lua/standin.sh" "$T/work" > "$T/session.json"
REX_SESSION=$(jq -r .session_id "$T/session.json"); export REX_SESSION
B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
CLI="$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh"
OLD="$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator-bash.sh"
pass=0
check() { [ "$2" = "$3" ] || { printf 'FAIL %s: got [%s], want [%s]\n' "$1" "$2" "$3" >&2; exit 1; }; pass=$((pass+1)); }
cli() { /bin/bash "$CLI" "$@"; }
old() { /bin/bash "$OLD" "$@"; }
type_line() { printf '%s\n' "$1" | rex_test send -s "$REX_SESSION" -b "$B"; }
state() { rex_test block call -s "$REX_SESSION" -b "$B" program_status | jq -r '[.records[]? | select(.id==null)] | last | .state'; }
await_state() { for ((n=0;n<100;n++)); do [ "$(state)" != "$1" ] || return 0; sleep 0.03; done; echo "state never became $1" >&2; exit 1; }
await_listener() {
  local n
  for ((n=0;n<100;n++)); do
    if grep -q '^listening:' "$T/wait.err"; then return 0; fi
    if ! kill -0 "$wait_pid" 2>/dev/null; then break; fi
    sleep 0.05
  done
  cat "$T/wait.err" "$T/wait.out" >&2
  echo "wait did not start listening" >&2
  exit 1
}
await_state working
check 'status JSON parity' "$(cli status "$B" | jq -Sc .)" "$(old status "$B" | jq -Sc .)"
implicit_list=$(REX_SESSION='' REX_BLOCK="$B" cli ls)
check 'resolve session from REX_BLOCK' "$implicit_list" ''
mkdir -p "$T/install space/bin"
ln -s "$ROOT/skills/rex-orchestrator/scripts" "$T/install space/assets"
ln -s ../assets/rex-orchestrator.sh "$T/install space/bin/relative"
ln -s relative "$T/install space/bin/chain"
check 'Lua through chained relative install symlinks' "$(/bin/bash "$T/install space/bin/chain" status "$B")" "$(cli status "$B")"
REX_SESSION=lua-test cli wait "$B" --timeout 20 > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
await_listener; type_line 'done'
for ((n=0;n<100;n++)); do
  if ! kill -0 "$wait_pid" 2>/dev/null; then break; fi
  sleep 0.05
done
if kill -0 "$wait_pid" 2>/dev/null; then echo 'wait missed the status event' >&2; exit 1; fi
wait "$wait_pid" || { cat "$T/wait.err" "$T/wait.out" >&2; exit 1; }
check 'event-driven done using the session label' "$(cat "$T/wait.out")" 'done'
check 'screen parity' "$(cli screen "$B")" "$(old screen "$B")"
check 'default screen lines with an empty argument' "$(cli screen "$B" '')" "$(old screen "$B" '')"
check 'ls parity' "$(cli ls | cut -f2- | jq -Sc .)" "$(old ls | cut -f2- | jq -Sc .)"
for pair in 'blocked:10:blocked question A question' 'error:11:error Boom'; do
  IFS=: read -r command expected_code expected_text <<< "$pair"
  type_line "$command"; await_state "$command"
  code=0; cli wait "$B" > "$T/wait.out" 2> "$T/wait.err" || code=$?
  check "$command exit" "$code" "$expected_code"; check "$command text" "$(cat "$T/wait.out")" "$expected_text"
done
type_line working; await_state working
code=0; cli wait "$B" --timeout 0 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'timeout exit' "$code" 124
check 'timeout text' "$(cat "$T/wait.out")" 'timeout (state=working)'
# Ownership record compatible with Bash, for a caller that has already disappeared.
export REX_BLOCK=block:01a10000-0000-7000-8000-000000000001
sf="$REX_ORCHESTRATOR_STATE_DIR/${B//[^A-Za-z0-9_-]/_}"
pid=$(rex_test block call -s "$REX_SESSION" -b "$B" process | jq -r .child.pid)
printf '%s\n' "$REX_BLOCK" "$pid" '' claude "$T/work" '' /bin/bash > "$sf.own"
type_line permission; await_state blocked
cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" || { cat "$T/wait.err" >&2; cat "$T/wait.out" >&2; exit 1; }
check 'one-time approval completes' "$(cat "$T/wait.out")" 'done'
check 'only one Enter' "$(wc -l < "$T/work/presses" | tr -d ' ')" 1
type_line permission; await_state blocked
cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/concurrent1.out" 2> "$T/concurrent1.err" &
first=$!
cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/concurrent2.out" 2> "$T/concurrent2.err" &
second=$!
wait "$first"; wait "$second"
check 'concurrent approvers press once' "$(wc -l < "$T/work/presses" | tr -d ' ')" 2
printf 'outside\n' > "$T/outside.txt"
for kind in symlink hardlink; do
  if [ "$kind" = symlink ]; then ln -s "$T/outside.txt" "$T/work/new.txt"; else ln "$T/outside.txt" "$T/work/new.txt"; fi
  type_line permission; await_state blocked
  code=0; cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" || code=$?
  check "refuse $kind approval" "$code" 10
  rm "$T/work/new.txt"
done
for target in AGENTS.md .env sub/../new.txt; do
  type_line "permission $target"; await_state blocked
  code=0; cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" || code=$?
  check "refuse protected path $target" "$code" 10
done
check 'unsafe paths press no keys' "$(wc -l < "$T/work/presses" | tr -d ' ')" 2
# Restore done for the baseline-file test below.
type_line 'done'; await_state 'done'
# A stale report, marked by Bash's on-disk timestamp, cannot end Lua wait.
upd=$(rex_test block call -s "$REX_SESSION" -b "$B" program_status | jq -r '[.records[]? | select(.id==null)] | last | .updated_at')
printf '%s\n\n' "$upd" > "$sf"
code=0; cli wait "$B" --timeout 0 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'stale status exit' "$code" 124
check 'stale status text' "$(cat "$T/wait.out")" 'timeout (state=done, no new report since send/keys)'
# Self-target checks through a label and missing context retain usage exit 2.
code=0; REX_BLOCK="$B" cli status "$B" > /dev/null 2> "$T/err" || code=$?
check 'self-target exit' "$code" 2
code=0; REX_SESSION='' REX_BLOCK='' cli ls > /dev/null 2> "$T/err" || code=$?
check 'no context exit' "$code" 2
# A mode change immediately after approval stops this pane and disables Claude approvals.
rm -f "$sf"
printf '%s\n' "$REX_BLOCK" "$pid" '' claude "$T/work" '⏸ manual mode on' /bin/bash > "$sf.own"
: > "$T/work/mode-change"
type_line permission; await_state blocked
code=0; cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'mode change after approval stops pane' "$code:$(cat "$T/wait.out")" '10:stopped'
check 'mode change after approval sets kill switch' "$([ -f "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude" ] && echo yes)" yes
if [ -n "${REX_LUA_BENCHMARK:-}" ]; then . "$ROOT/tests/lua/benchmark.inc.sh"; fi
# Close events end an active wait, even without a last status report.
type_line working; await_state working
cli wait "$B" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
await_listener; rex_test block close -s "$REX_SESSION" "$B"
code=0; wait "$wait_pid" || code=$?
check 'closed event exit' "$code" 12; check 'closed event text' "$(cat "$T/wait.out")" exited
rex_test session new lua-destroy --shell none --keep-open --json -- /bin/bash "$ROOT/tests/lua/standin.sh" "$T/work" > "$T/session.json"
REX_SESSION=$(jq -r .session_id "$T/session.json")
B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
await_state working
cli wait "$B" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
await_listener; rex_test session kill "$REX_SESSION"
code=0; wait "$wait_pid" || code=$?
check 'destroyed session exit' "$code:$(cat "$T/wait.out")" '12:exited'
printf 'Lua live: %d passed\n' "$pass"
