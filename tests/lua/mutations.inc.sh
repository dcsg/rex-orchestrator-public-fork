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
before_keys=$(grep -c 'method=client.key' "$T/server.log" || :)
for shift_key in 'shift+tab' 's-tab' 'Shift+[Tab]' 'ctrl+Shift+Tab' 'backtab' 'ctrl+b>tab'; do
  command_code "idle Claude refuses $shift_key" 2 keys "$B" "$shift_key"
done
check 'refused keys emit no keyboard events' "$(grep -c 'method=client.key' "$T/server.log" || :)" "$before_keys"
command_code 'send refuses a shell command' 2 send "$B" ' !echo fixture'
command_code 'send refuses the Claude survey key' 2 send "$B" '9 rating'
command_code 'send refuses a permission slash prefix' 2 send "$B" /PERM
command_code 'send rejects a missing file' 2 send "$B" -f "$work_phase2/missing"
printf unreadable > "$work_phase2/unreadable"; chmod 000 "$work_phase2/unreadable"
command_code 'send rejects an unreadable regular file with exit 1' 1 send "$B" -f "$work_phase2/unreadable"
chmod 600 "$work_phase2/unreadable"
for control in $'\003' $'\033' $'\177' $'\302\233'; do
  command_code 'send refuses terminal control characters' 2 send "$B" "prompt${control}text"
  grep -q 'terminal control character' "$T/lua.err"
done
touch "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude"
command_code 'send observes an agent kill switch' 2 send "$B" 'not allowed'
command_code 'keys observes an agent kill switch' 2 keys "$B" tab
rm "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude"
printf '%s\n' 'fixture stop' > "$sf.stopped"
command_code 'send refuses a stopped pane' 2 send "$B" 'not allowed'
rm "$sf.stopped"
cp "$sf.own" "$T/correct.own"
sed '6s/.*/⏵⏵ accept edits on/' "$T/correct.own" > "$sf.own"
command_code 'send stops on a permission pin mismatch' 2 send "$B" 'not allowed'
[ -s "$sf.stopped" ]
rm "$sf.stopped"
sed '2s/.*/99999999/' "$T/correct.own" > "$sf.own"
command_code 'send reports a replaced child process as exited' 12 send "$B" 'not allowed'
cp "$T/correct.own" "$sf.own"
[ ! -e "$work_phase2/prompts" ]

printf '%s\n%s\n\000' '-from file' 'now' > "$work_phase2/input"
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

# Two sends at once take turns on the block's input lock: each prompt arrives whole, on a line of its own.
# The escape pressed above still sits in the pane's line buffer: end that line first.
type_line ''; type_line plain; await_state idle
rm -f "$work_phase2/prompts"
cli send "$B" 'first concurrent prompt' > "$T/send1.out" 2> "$T/send1.err" & send1=$!
cli send "$B" 'second concurrent prompt' > "$T/send2.out" 2> "$T/send2.err" & send2=$!
rc1=0; wait "$send1" || rc1=$?
rc2=0; wait "$send2" || rc2=$?
[ "$rc1:$rc2" = 0:0 ] || cat "$T/send1.err" "$T/send2.err" >&2
check 'two concurrent sends both submit' "$rc1:$rc2" 0:0
for ((n=0;n<100;n++)); do [ "$(grep -c . "$work_phase2/prompts" 2>/dev/null)" = 2 ] && break; sleep 0.03; done
check 'each concurrent prompt arrives whole, on its own line' "$(sort "$work_phase2/prompts")" \
  "$(printf '%s\n' 'first concurrent prompt' 'second concurrent prompt')"
# A send that finds the lock held past its wait gives up with exit 4 and types nothing.
(
  /usr/bin/perl -e 'use Fcntl qw(:flock); open(my $f, ">&=", 9) or exit 1; flock($f, LOCK_EX) or exit 1'
  : > "$T/input-lock-ready"
  for ((n=0;n<1200;n++)); do [ ! -e "$T/input-lock-release" ] || break; sleep 0.05; done
) 9>>"$sf.input.lock" &
input_lock_pid=$!
for ((n=0;n<100;n++)); do [ ! -e "$T/input-lock-ready" ] || break; sleep 0.05; done
[ -e "$T/input-lock-ready" ]
started=$SECONDS
keys_rc=0; cli keys "$B" escape > "$T/keys-lock.out" 2> "$T/keys-lock.err" & keys_pid=$!
command_code 'send gives up on a held input lock' 4 send "$B" 'never typed'
check 'send waited for the held input lock' "$([ $((SECONDS-started)) -ge 14 ] && echo yes)" yes
grep -q 'another send or keys to .* was still running after 15s; nothing was sent' "$T/lua.err"
wait "$keys_pid" || keys_rc=$?
check 'keys gives up on a held input lock' "$keys_rc" 4
grep -q 'was still running after 15s; no key was pressed' "$T/keys-lock.err"
: > "$T/input-lock-release"; wait "$input_lock_pid"
check 'nothing was typed while the lock was held' "$(grep -c 'never typed' "$work_phase2/prompts" || :)" 0

registry="$REX_ORCHESTRATOR_STATE_DIR/registry"
mkdir -p "$registry"
claim="$registry/${B//[^A-Za-z0-9_-]/_}.json"
dead_claim="$registry/block_stale.json"
gone_claim="$registry/block_gone_session.json"
jq -nc --arg block "$B" --arg session "$REX_SESSION" --argjson pid "$pid" --arg dir "$work_phase2" \
  '{block:$block,session:$session,pid:$pid,label:"claim\tlabel",kind:"claude",canonical_dir:$dir}' > "$claim"
jq -c '.pid=99999999' "$claim" > "$dead_claim"
jq -c '.session="session:01a10000-0000-7000-8000-000000000001"' "$claim" > "$gone_claim"
(REX_SESSION='' REX_BLOCK='' cli claims --json) > "$T/lua.out"
cmp "$claim" "$T/lua.out"
check 'claims prunes a dead PID without a caller session' "$([ ! -e "$dead_claim" ] && echo yes)" yes
check 'claims prunes a removed session with a live PID' "$([ ! -e "$gone_claim" ] && echo yes)" yes
(REX_SESSION='' REX_BLOCK='' cli claims) > "$T/lua.out"
check 'claims keeps the tab-separated field contract' "$(cat "$T/lua.out")" \
  "$(jq -r '[.block,.label,.session,.kind,(.pid|tostring),.canonical_dir] | @tsv' "$claim")"
if [ -n "$OLD" ]; then
  (REX_SESSION='' REX_BLOCK='' old claims) > "$T/old.out"
  cmp "$T/old.out" "$T/lua.out"
fi

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

cage="$REX_ORCHESTRATOR_STATE_DIR/cage/agy.fixture"
private_cage_command="$REX_ORCHESTRATOR_STATE_DIR/cage-commands/agy.fixture"
mkdir -p "$cage" "$(dirname "$private_cage_command")"
printf '%s\n' '{"kind":"agy","label":"phase2-fixture"}' > "$cage/run-meta.json"
: > "$private_cage_command"
printf '%s\n' agy.fixture > "$sf.cage"
command_code 'close removes the pane, claim and cage' 0 close "$B"
[ ! -e "$claim" ] && [ ! -e "$sf.own" ] && [ ! -e "$sf.hold" ] && [ ! -e "$cage" ]
check 'close harvested a manifest' "$(find "$REX_ORCHESTRATOR_STATE_DIR/runs" -name manifest.json | wc -l | tr -d ' ')" 1
check 'caged close removes a reserved agy command file' "$([ ! -e "$private_cage_command" ] && echo yes)" yes
command_code 'close accepts a full ID for a previously deleted pane' 0 close --force "$B"
export REX_ORCHESTRATOR_STATE_DIR="$previous_state_dir"
