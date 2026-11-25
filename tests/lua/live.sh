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
unset CLAUDECODE CLAUDE_CONFIG_DIR CODEX_HOME REX_ORCHESTRATOR_CONFIG_DIR
unset REX_ORCHESTRATOR_CAGE_PROFILE REX_ORCHESTRATOR_CAGE_TPL REX_ORCHESTRATOR_CAGE_SECRETS
unset REX_ORCHESTRATOR_CAGE_AGY_HOME REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
# The entry script and the Bash baseline both use this shim to disable autostart.
printf '#!/bin/bash\nexec %q --autostart=false "$@"\n' "$REAL_REX" > "$T/bin/rex"
chmod +x "$T/bin/rex"
export REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin"
rex_test() { "$REAL_REX" --autostart=false "$@"; }
"$REAL_REX" --autostart=false server run --listen "$REX_SERVER" --state-dir "$T/state" --restore=false --config "$T/init.lua" > "$T/server.log" 2>&1 &
server_pid=$!
for ((n=0;n<100;n++)); do [ ! -S "$T/rex.sock" ] || break; sleep 0.05; done
[ -S "$T/rex.sock" ] || { cat "$T/server.log" >&2; exit 1; }
rex_test session new lua-test --shell none --keep-open --json -- /bin/bash "$ROOT/tests/lua/standin.sh" "$T/work" > "$T/session.json"
REX_SESSION=$(jq -r .session_id "$T/session.json"); export REX_SESSION
B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
CLI="$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh"
OLD=${REX_LUA_BASELINE:-}
[ -z "$OLD" ] || [ -f "$OLD" ] || { echo 'REX_LUA_BASELINE must point at an extracted Bash implementation' >&2; exit 2; }
pass=0
check() { [ "$2" = "$3" ] || { printf 'FAIL %s: got [%s], want [%s]\n' "$1" "$2" "$3" >&2; exit 1; }; pass=$((pass+1)); }
cli() { /bin/bash "$CLI" "$@"; }
old() { /bin/bash "$OLD" "$@"; }
type_line() { printf '%s\n' "$1" | rex_test send -s "$REX_SESSION" -b "$B"; }
state() { rex_test block call -s "$REX_SESSION" -b "$B" program_status | jq -r '[.records[]? | select(.id==null)] | last | .state'; }
await_state() { for ((n=0;n<100;n++)); do [ "$(state)" != "$1" ] || return 0; sleep 0.03; done; echo "state never became $1" >&2; exit 1; }
prompt_wait() {
  local n
  for ((n=0;n<140;n++)); do
    if ! kill -0 "$wait_pid" 2>/dev/null; then wait "$wait_pid"; return; fi
    sleep 0.05
  done
  cat "$T/wait.err" "$T/wait.out" >&2
  echo "wait did not finish promptly" >&2
  exit 1
}
expect_error() {
  local label=$1 session=$2 caller=$3 expected=$4 message=$5 bash_code=0 lua_code=0
  shift 5
  REX_SESSION="$session" REX_BLOCK="$caller" cli "$@" > "$T/lua.out" 2> "$T/lua.err" || lua_code=$?
  check "$label exit" "$lua_code" "$expected"
  check "$label output" "$(cat "$T/lua.out")" ''
  grep -Fq "$message" "$T/lua.err" || { cat "$T/lua.err" >&2; exit 1; }
  pass=$((pass+1))
  if [ -n "$OLD" ]; then
    REX_SESSION="$session" REX_BLOCK="$caller" old "$@" > "$T/old.out" 2> "$T/old.err" || bash_code=$?
    check "$label Bash exit" "$bash_code" "$lua_code"
    cmp "$T/old.out" "$T/lua.out"
    if [ "$label" = 'server down' ]; then
      sed -E '/^Error: (REX_SERVER: )?no Rex server is running/d' "$T/old.err" > "$T/old.filtered"
      mv "$T/old.filtered" "$T/old.err"
    fi
    cmp -s "$T/old.err" "$T/lua.err" || { diff -u "$T/old.err" "$T/lua.err" >&2; exit 1; }
  fi
}
await_state working
# shellcheck disable=SC1003 # The title ends with a literal backslash.
title=$(printf '%s\\' '<&>"')
for ((n=0;n<100;n++)); do
  [ "$(cli status "$B" | jq -r .title)" != "$title" ] || break
  sleep 0.03
done
check 'title fixture' "$(cli status "$B" | jq -r .title)" "$title"
rex_test "do" -e 'assert(rex.call("session.attach",{session_id=rex.args.s})); assert(rex.session.set_block_label{session_id=rex.args.s,block_id=rex.args.b,label=rex.args.label})' \
  "s=$REX_SESSION" "b=$B" 'label=fixture\label'
cli status "$B" > "$T/lua.out"
check 'status reads the working state of the pane' "$(jq -r '[.state,.alive] | join(":")' "$T/lua.out")" 'working:true'
if [ -n "$OLD" ]; then old status "$B" > "$T/old.out"; cmp "$T/old.out" "$T/lua.out"; fi
expect_error 'unknown REX_BLOCK' '' block:01a10000-0000-7000-8000-000000000001 \
  2 'REX_SESSION is empty and no session could be resolved' status "$B"
expect_error 'bad REX_SESSION' not-a-rex-session '' 2 'no such block in this session' status "$B"
expect_error 'invalid UTF-8 argv' "$REX_SESSION" '' 2 'no such block in this session' status "$(printf '\377')"
implicit_list=$(REX_SESSION='' REX_BLOCK="$B" cli ls)
check 'resolve session from REX_BLOCK' "$implicit_list" ''
mkdir -p "$T/install space/bin"
ln -s "$ROOT/skills/rex-orchestrator/scripts" "$T/install space/assets"
ln -s ../assets/rex-orchestrator.sh "$T/install space/bin/relative"
ln -s relative "$T/install space/bin/chain"
check 'Lua through chained relative install symlinks' "$(/bin/bash "$T/install space/bin/chain" status "$B")" "$(cli status "$B")"
for delay in 0 0.02 0.05 0.1 0.2 0.4; do
  type_line working; await_state working
  REX_SESSION=lua-test cli wait "$B" --timeout 20 > "$T/wait.out" 2> "$T/wait.err" &
  wait_pid=$!
  sleep "$delay"; type_line 'done'
  prompt_wait || { cat "$T/wait.err" "$T/wait.out" >&2; exit 1; }
  check "status transition during wait startup after $delay s" "$(cat "$T/wait.out")" 'done'
  check 'wait has no Rex banner' "$(cat "$T/wait.err")" ''
done
check 'screen agrees with Rex capture' "$(cli screen "$B")" "$(rex_test capture -s "$REX_SESSION" -b "$B" --trim --unwrap)"
check 'default screen lines with an empty argument' "$(cli screen "$B" '')" "$(cli screen "$B")"
cli ls > "$T/lua.out"
check 'ls emits the block ID and status JSON' \
  "$(cut -f2- "$T/lua.out" | jq -r '.state')" 'done'
if [ -n "$OLD" ]; then old ls > "$T/old.out"; cmp "$T/old.out" "$T/lua.out"; fi
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
type_line idle; await_state idle
started=$SECONDS
check 'initial idle' "$(cli wait "$B" --timeout 12)" idle
[ $((SECONDS-started)) -ge 8 ] || { echo 'idle returned before its grace' >&2; exit 1; }
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
type_line agy-cut; await_state blocked
code=0; cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'unverified cut agy prompt is left to the user' "$code" 10
grep -q 'not a verified one' "$T/wait.err"
# Seed only this fixture's verified-build cache to exercise the cut dialog path with a shell stand-in.
bin=$(rex_test block call -s "$REX_SESSION" -b "$B" process | jq -r .child.path)
printf '%s 34423fc9b0af3841e7646aa72a2d40ffeab8218b22d1cb99eac7355f9eba31e3 %s\n' \
  "$(stat -f '%z %m %i %c' "$bin")" "$bin" > "$REX_ORCHESTRATOR_STATE_DIR/agy-sha256"
cli wait "$B" --approve-in "$T/work" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" || { cat "$T/wait.err" >&2; exit 1; }
check 'verified cut agy prompt completes' "$(cat "$T/wait.out")" 'done'
check 'cut agy approval presses once' "$(wc -l < "$T/work/presses" | tr -d ' ')" 3
# Restore done for the baseline-file test below.
type_line 'done'; await_state 'done'
# A stale report, marked by Bash's on-disk timestamp, cannot end Lua wait.
upd=$(rex_test block call -s "$REX_SESSION" -b "$B" program_status | jq -r '[.records[]? | select(.id==null)] | last | .updated_at')
printf '%s\n\n' "$upd" > "$sf"
code=0; cli wait "$B" --timeout 0 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'stale status exit' "$code" 124
check 'stale status text' "$(cat "$T/wait.out")" 'timeout (state=done, no new report since send/keys)'
type_line blocked; await_state blocked
upd=$(rex_test block call -s "$REX_SESSION" -b "$B" program_status | jq -r '[.records[]? | select(.id==null)] | last | .updated_at')
printf '%s\n\n' "$upd" > "$sf"
started=$SECONDS; code=0
cli wait "$B" --timeout 14 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'stale Claude prompt remains blocked' "$code:$(cat "$T/wait.out")" '10:blocked question A question'
[ $((SECONDS-started)) -gt 10 ] || { echo 'stale prompt returned before its grace' >&2; exit 1; }
grep -q 'no new report since send/keys: the prompt is still up' "$T/wait.err"
rm "$sf"
type_line bg; await_state 'done'
code=0; cli wait "$B" --timeout 0 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'background wait persists hold' "$code:$(cat "$T/wait.out")" '124:timeout (state=done, background: 1 shell)'
cp "$sf.hold" "$T/first.hold"
code=0; cli wait "$B" --timeout 0 > "$T/wait.out" 2> "$T/wait.err" || code=$?
check 'remaining background hold is carried across waits' "$code" 124
cmp "$T/first.hold" "$sf.hold"
check 'ignore-background completes a carried hold' "$(cli wait "$B" --ignore-background)" 'done'
[ ! -e "$sf.hold" ]
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
if [ -n "${REX_LUA_BENCHMARK:-}" ]; then
  [ -n "$OLD" ] || { echo 'REX_LUA_BENCHMARK requires REX_LUA_BASELINE' >&2; exit 2; }
  . "$ROOT/tests/lua/benchmark.inc.sh"
fi
# Close events end an active wait, even without a last status report.
type_line working; await_state working
cli wait "$B" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
sleep 0.4; rex_test block close -s "$REX_SESSION" "$B"
code=0; wait "$wait_pid" || code=$?
check 'closed event exit' "$code" 12; check 'closed event text' "$(cat "$T/wait.out")" exited
rex_test session new lua-destroy --shell none --keep-open --json -- /bin/bash "$ROOT/tests/lua/standin.sh" "$T/work" > "$T/session.json"
REX_SESSION=$(jq -r .session_id "$T/session.json")
B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
await_state working
rex_test "do" -e 'assert(rex.call("session.attach",{session_id=rex.args.s})); assert(rex.session.set_block_label{session_id=rex.args.s,block_id=rex.args.b,label="twins"})' \
  "s=$REX_SESSION" "b=$B"
rex_test split -s "$REX_SESSION" -b "$B" --label twins --shell none --keep-open -- /bin/cat >/dev/null
expect_error 'ambiguous block label' "$REX_SESSION" '' 2 'is ambiguous' status twins
cli wait "$B" --timeout 5 > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
sleep 0.4; rex_test session kill "$REX_SESSION"
code=0; wait "$wait_pid" || code=$?
check 'destroyed session exit' "$code:$(cat "$T/wait.out")" '12:exited'
. "$ROOT/tests/lua/mutations.inc.sh"
. "$ROOT/tests/lua/launch.inc.sh"
rex_test session new lua-disconnect --shell none --keep-open --json -- /bin/bash "$ROOT/tests/lua/standin.sh" "$T/work" > "$T/session.json"
REX_SESSION=$(jq -r .session_id "$T/session.json")
B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
type_line bg; await_state 'done'
sf="$REX_ORCHESTRATOR_STATE_DIR/${B//[^A-Za-z0-9_-]/_}"
cli wait "$B" --timeout 20 > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
for ((n=0;n<100;n++)); do [ ! -s "$sf.hold" ] || break; sleep 0.05; done
[ -s "$sf.hold" ] || { echo 'wait never took its initial snapshot' >&2; exit 1; }
kill -KILL "$server_pid"; wait "$server_pid" 2>/dev/null || :
server_pid=''
code=0; prompt_wait || code=$?
check 'server disconnect fails promptly' "$code:$(cat "$T/wait.out")" '1:'
grep -q 'rex did not answer' "$T/wait.err"
expect_error 'server down' "$REX_SESSION" '' 1 'rex did not answer for block' status "$B"
expect_error 'server down with implicit session' '' "$B" 2 'REX_SESSION is empty and no session could be resolved' wait "$B"
. "$ROOT/tests/lua/mutation-disconnect.inc.sh"
printf 'Lua live: %d passed\n' "$pass"
