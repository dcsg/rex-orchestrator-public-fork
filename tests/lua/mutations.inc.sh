# shellcheck shell=bash disable=SC2154
# Runs inside live.sh's throwaway Rex server.
work_phase2="$T/phase2"
previous_state_dir=$REX_ORCHESTRATOR_STATE_DIR
export REX_ORCHESTRATOR_STATE_DIR="$T/phase2-state"
mkdir -p "$work_phase2"
rex_test session new lua-phase2 --shell none --keep-open --json -- \
  /bin/bash "$ROOT/tests/lua/standin.sh" "$work_phase2" > "$T/session.json"
REX_SESSION=$(jq -r .session_id "$T/session.json")
B=$(jq -r '.initial_windows[0].block_ids[0]' "$T/session.json")
export REX_BLOCK=block:01a10000-0000-7000-8000-000000000001
sf="$REX_ORCHESTRATOR_STATE_DIR/${B//[^A-Za-z0-9_-]/_}"
pid=$(rex_test block call -s "$REX_SESSION" -b "$B" process | jq -r .child.pid)

command_code() {
  local label=$1 want=$2 rc=0
  shift 2
  cli "$@" > "$T/lua.out" 2> "$T/lua.err" || rc=$?
  if [ "$rc" != "$want" ]; then cat "$T/lua.err" >&2; fi
  check "$label" "$rc" "$want"
}
await_state working
command_code 'send refuses an unowned block' 2 send "$B" 'not allowed'
command_code 'keys refuses an unowned block' 2 keys "$B" escape
command_code 'close refuses an unowned block' 2 close "$B"
printf '%s\n' "$REX_BLOCK" "$pid" '' claude "$work_phase2" '⏸ manual mode on' /bin/bash > "$sf.own"
command_code 'send refuses working status' 4 send "$B" 'not allowed'
type_line composer; await_state idle
command_code 'send refuses a shell command' 2 send "$B" ' !echo fixture'
command_code 'send refuses the Claude survey key' 2 send "$B" '9 rating'
command_code 'send refuses a permission slash prefix' 2 send "$B" /PERM
command_code 'send rejects a missing file' 2 send "$B" -f "$work_phase2/missing"
touch "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude"
command_code 'send observes an agent kill switch' 2 send "$B" 'not allowed'
rm "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude"
[ ! -e "$work_phase2/prompts" ]

printf '%s\n' '-from file' 'now' > "$work_phase2/input"
command_code 'send types and submits an exact file prompt' 0 send "$B" -f "$work_phase2/input"
await_state 'done'
check 'send normalizes line endings and preserves a leading dash' "$(cat "$work_phase2/prompts")" '-from file now'
check 'wait sees the turn submitted by send' "$(cli wait "$B")" 'done'

type_line permission; await_state blocked
command_code 'keys refuses a persistent option' 2 keys "$B" 2
command_code 'keys refuses approval combined with navigation' 2 keys "$B" enter down
command_code 'keys refuses a Claude mode-switch alias' 2 keys "$B" Shift+Tab
[ ! -e "$work_phase2/presses" ]
printf 'previous\n7 shells\n' > "$sf"
printf 'held record\n' > "$sf.hold"
command_code 'keys enters the one-time option' 0 keys "$B" enter
await_state 'done'
check 'keys pressed exactly once' "$(cat "$work_phase2/presses")" enter
check 'keys preserves the background baseline' "$(sed -n 2p "$sf")" '7 shells'
check 'keys preserves the hold' "$(cat "$sf.hold")" 'held record'
touch "$REX_ORCHESTRATOR_STATE_DIR/disabled"
command_code 'keys observes the global kill switch' 2 keys "$B" tab
command_code 'global kill switch allows an interrupt key' 0 keys "$B" escape
rm "$REX_ORCHESTRATOR_STATE_DIR/disabled"

registry="$REX_ORCHESTRATOR_STATE_DIR/registry"
mkdir -p "$registry"
claim="$registry/${B//[^A-Za-z0-9_-]/_}.json"
dead_claim="$registry/block_stale.json"
jq -nc --arg block "$B" --arg session "$REX_SESSION" --argjson pid "$pid" --arg dir "$work_phase2" \
  '{block:$block,session:$session,pid:$pid,label:"claim\tlabel",kind:"claude",canonical_dir:$dir}' > "$claim"
jq -c '.pid=99999999' "$claim" > "$dead_claim"
(REX_SESSION='' REX_BLOCK='' cli claims --json) > "$T/lua.out"
cmp "$claim" "$T/lua.out"
check 'claims prunes a dead PID without a caller session' "$([ ! -e "$dead_claim" ] && echo yes)" yes
(REX_SESSION='' REX_BLOCK='' cli claims) > "$T/lua.out"
(REX_SESSION='' REX_BLOCK='' old claims) > "$T/old.out"
cmp "$T/old.out" "$T/lua.out"
pass=$((pass+1))

# Hold the same flock using Bash's inherited descriptor protocol.
(
  /usr/bin/perl -e 'use Fcntl qw(:flock); open(my $f, ">&=", 9) or exit 1; flock($f, LOCK_EX) or exit 1'
  : > "$T/bash-lock-ready"
  for ((n=0;n<100;n++)); do [ ! -e "$T/bash-lock-release" ] || break; sleep 0.05; done
) 9>>"$REX_ORCHESTRATOR_STATE_DIR/registry.lock" &
lock_pid=$!
for ((n=0;n<100;n++)); do [ ! -e "$T/bash-lock-ready" ] || break; sleep 0.05; done
[ -e "$T/bash-lock-ready" ]
cli claims --json > "$T/lua.out" &
claims_pid=$!
sleep 0.2
check 'Lua claims waits for the Bash registry lock' "$([ ! -s "$T/lua.out" ] && echo yes)" yes
: > "$T/bash-lock-release"
wait "$lock_pid"; wait "$claims_pid"
cmp "$claim" "$T/lua.out"

cage="$REX_ORCHESTRATOR_STATE_DIR/cage/codex.fixture"
mkdir -p "$cage"
printf '%s\n' '{"kind":"codex","label":"phase2-fixture"}' > "$cage/run-meta.json"
printf '%s\n' codex.fixture > "$sf.cage"
command_code 'close removes the pane, claim and cage' 0 close "$B"
[ ! -e "$claim" ] && [ ! -e "$sf.own" ] && [ ! -e "$sf.hold" ] && [ ! -e "$cage" ]
check 'close harvested a manifest' "$(find "$REX_ORCHESTRATOR_STATE_DIR/runs" -name manifest.json | wc -l | tr -d ' ')" 1
command_code 'close accepts a full ID for a previously deleted pane' 0 close --force "$B"
export REX_ORCHESTRATOR_STATE_DIR="$previous_state_dir"
