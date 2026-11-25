# shellcheck shell=bash disable=SC2154
# Orphan close, sourced by live.sh: every pane, watcher and state file belongs to its throwaway Rex server.
orphan_previous_state_dir=$REX_ORCHESTRATOR_STATE_DIR
orphan_previous_caller=$REX_BLOCK
export REX_ORCHESTRATOR_STATE_DIR="$T/orphan-state"
export REX_ORCHESTRATOR_ORPHAN_GRACE=0
mkdir -p "$T/launch-agents" "$T/launch-work"
launch_fixture claude-code steer claude-steer
rex_test session new lua-orphans --shell none --keep-open --json -- /bin/bash > "$T/orphan-session.json"
REX_SESSION=$(jq -r .session_id "$T/orphan-session.json")
export REX_SESSION
# A pane whose shell runs an orchestrator agent stand-in that can quit and be started again.
O_AGENT=$(jq -r '.initial_windows[0].block_ids[0]' "$T/orphan-session.json")
orphan_pane() {
  rex_test run -s "$REX_SESSION" --shell none --keep-open --focus=false --json -- /bin/cat |
    jq -r '[.. | objects | .block_ids? // empty | .[]] | first'
}
orphan_sf() { printf '%s/%s' "$REX_ORCHESTRATOR_STATE_DIR" "${1//[^A-Za-z0-9_-]/_}"; }
# Launch a steerable child from orchestrator $1, named $2; extra arguments go to launch.
orphan_launch() {
  local orchestrator=$1 name=$2 rc=0
  shift 2
  mkdir -p "$T/launch-work/orphan-$name"
  REX_BLOCK=$orchestrator cli launch --no-cage --dir "$T/launch-work/orphan-$name" --label "$name" --tab "$name" \
    --timeout 8 --agent "$T/launch-agents/claude-steer" "$@" > "$T/orphan-launch.out" 2> "$T/orphan-launch.err" || rc=$?
  [ "$rc" = 0 ] || { cat "$T/orphan-launch.err" >&2; echo "orphan launch $name exited $rc" >&2; exit 1; }
  cat "$T/orphan-launch.out"
}
orphan_type() { printf '%s\n' "$2" | rex_test send -s "$REX_SESSION" -b "$1"; }
orphan_state() {
  rex_test block call -s "$REX_SESSION" -b "$1" program_status | jq -r '[.records[]? | select(.id==null)] | last | .state'
}
orphan_await_state() {
  local n
  for ((n=0;n<100;n++)); do [ "$(orphan_state "$1")" != "$2" ] || return 0; sleep 0.05; done
  echo "$1 never reported $2" >&2; exit 1
}
orphan_open() { rex_test block ls -s "$REX_SESSION" -q --short=false | grep -Fxq -- "$1"; }
# closed BLOCK: its pane and every state file are gone.
orphan_closed() {
  ! orphan_open "$1" && [ -z "$(find "$REX_ORCHESTRATOR_STATE_DIR" -maxdepth 1 -name "$(basename "$(orphan_sf "$1")")*" -print -quit)" ]
}
orphan_await_closed() {
  local n
  for ((n=0;n<${2:-150};n++)); do orphan_closed "$1" && return 0; sleep 0.1; done
  echo "orphan $1 was not closed" >&2; cat "$REX_ORCHESTRATOR_STATE_DIR"/watch/*.log >&2 2>/dev/null || :; exit 1
}
# The live watchers of orchestrator $1 (the rex do process itself, not a launcher waiting for the lock).
orphan_watchers() {
  ps -axo pid=,command= | awk -v id="$1" 'index($0,"watch.lua --args") && index($0,id) && $2!="/usr/bin/perl" {print $1}'
}
orphan_await_watchers() {
  local n
  for ((n=0;n<100;n++)); do [ "$(orphan_watchers "$1" | wc -l | tr -d ' ')" != "$2" ] || return 0; sleep 0.1; done
  echo "orchestrator $1 does not have $2 watcher(s)" >&2; exit 1
}
orphan_ls() { REX_BLOCK=$1 cli ls | cut -f2- | jq -r --arg l "$2" 'select(.label==$l) | .orphan'; }

O1=$(orphan_pane)
O2=$(orphan_pane)
check 'orphan fixture panes' "$([ -n "$O1" ] && [ "$O1" != null ] && [ -n "$O2" ] && echo ok)" ok

# One watcher per orchestrator, however many children it launches, started detached by launch.
A=$(ORPHAN_TEST_UNRELATED=leak orphan_launch "$O1" done-child)
B=$(orphan_launch "$O1" working-child)
orphan_await_watchers "$O1" 1
watcher_pid=$(orphan_watchers "$O1")
check 'the watcher runs from /' "$(lsof -a -p "$watcher_pid" -d cwd -Fn | sed -n 's/^n//p')" /
ps -E -o command= -p "$watcher_pid" > "$T/watcher-env"
check 'the watcher keeps its settings' "$(grep -c "REX_ORCHESTRATOR_STATE_DIR=$REX_ORCHESTRATOR_STATE_DIR" "$T/watcher-env")" 1
check "the watcher gets none of the caller's other environment" "$(grep -c 'ORPHAN_TEST_UNRELATED\|REX_BLOCK=' "$T/watcher-env" || :)" 0
sleep 3.5 # Outlast the retry window of the second launch's watcher start.
check 'two launches start one watcher' "$(orphan_watchers "$O1" | wc -l | tr -d ' ')" 1
check 'launch records the session and policy' "$(sed -n '8,9p' "$(orphan_sf "$A").own" | tr '\n' ' ')" "$REX_SESSION close "
check 'the watcher keeps a heartbeat' "$([ -s "$REX_ORCHESTRATOR_STATE_DIR/watch/${O1//[^A-Za-z0-9_-]/_}.alive" ] && echo yes)" yes
# Another orchestrator's child, launched while its orchestrator agent runs in a shell pane.
orphan_type "$O_AGENT" "bash $(printf %q "$ROOT/tests/lua/orch-agent.sh")"
orphan_await_state "$O_AGENT" idle
C=$(orphan_launch "$O_AGENT" other-child)
orphan_type "$B" working; orphan_await_state "$B" working

# The orchestrator's pane closes: its finished child is closed through close, its working child waits for its turn.
rex_test block close -s "$REX_SESSION" "$O1"
orphan_await_closed "$A"
check 'a closed orphan releases its claim' "$(cli claims --json | jq -r --arg id "$A" 'select(.block==$id) | .block')" ''
check 'a working orphan is left to finish' "$(orphan_open "$B" && [ -s "$(orphan_sf "$B").own" ] && echo open)" open
check 'ls shows a waiting orphan' "$(orphan_ls "$O2" working-child)" waiting
check 'ls shows a child with its orchestrator as no orphan' "$(orphan_ls "$O2" other-child)" null
orphan_type "$B" 'done'
orphan_await_closed "$B"
check "another orchestrator's child is untouched" "$(orphan_open "$C" && [ -s "$(orphan_sf "$C").own" ] && echo open)" open
orphan_await_watchers "$O1" 0
check 'the watcher removes its files once its orphans are closed' \
  "$(find "$REX_ORCHESTRATOR_STATE_DIR/watch" -name "${O1//[^A-Za-z0-9_-]/_}*" | wc -l | tr -d ' ')" 0

# The orchestrator agent quits and a new one starts in the same pane: its children stay its own and stay drivable.
orphan_type "$O_AGENT" quit
sleep 1
orphan_type "$O_AGENT" "bash $(printf %q "$ROOT/tests/lua/orch-agent.sh")"
orphan_await_state "$O_AGENT" idle
sleep 6 # More than a watcher tick, past the zero grace period.
check 'children outlive a quit orchestrator agent' "$(orphan_open "$C" && [ -s "$(orphan_sf "$C").own" ] && echo open)" open
check 'ls shows no orphan after the agent restarts' "$(orphan_ls "$O2" other-child)" null
REX_BLOCK=$O_AGENT cli send "$C" 'after the restart' > "$T/orphan.out" 2> "$T/orphan.err" || {
  cat "$T/orphan.err" >&2; echo 'send from the resumed orchestrator failed' >&2; exit 1; }
for ((n=0;n<50;n++)); do [ ! -s "$T/launch-work/orphan-other-child/prompts" ] || break; sleep 0.1; done
check 'the resumed orchestrator drives its child' "$(cat "$T/launch-work/orphan-other-child/prompts")" 'after the restart'
REX_BLOCK=$O_AGENT cli close "$C"
check 'the resumed orchestrator closes its child' "$(orphan_closed "$C" && echo closed)" closed
orphan_await_watchers "$O_AGENT" 0

# Launched from a shell inside the orchestrator's pane, as an agent does: the watcher outlives the pane's hangup.
O5=$(rex_test run -s "$REX_SESSION" --shell none --keep-open --focus=false --json -- /bin/bash |
  jq -r '[.. | objects | .block_ids? // empty | .[]] | first')
mkdir -p "$T/launch-work/orphan-in-pane"
in_pane=$(printf 'env REX_ORCHESTRATOR_STATE_DIR=%q REX_ORCHESTRATOR_ORPHAN_GRACE=0 REX_SERVER=%q REX_ORCHESTRATOR_REX_BIN_DIR=%q /bin/bash %q launch --no-cage --dir %q --label in-pane --tab in-pane --timeout 8 --agent %q > %q 2>&1' \
  "$REX_ORCHESTRATOR_STATE_DIR" "$REX_SERVER" "$REX_ORCHESTRATOR_REX_BIN_DIR" "$CLI" "$T/launch-work/orphan-in-pane" \
  "$T/launch-agents/claude-steer" "$T/orphan-in-pane.out")
orphan_type "$O5" "$in_pane"
for ((n=0;n<150;n++)); do grep -q '^block:' "$T/orphan-in-pane.out" 2>/dev/null && break; sleep 0.1; done
F=$(grep '^block:' "$T/orphan-in-pane.out") || { cat "$T/orphan-in-pane.out" >&2; echo 'launch from a pane failed' >&2; exit 1; }
orphan_await_watchers "$O5" 1
rex_test block close -s "$REX_SESSION" "$O5"
orphan_await_closed "$F"
check 'a watcher started inside the closed pane closes its orphan' "$(orphan_closed "$F" && echo closed)" closed

# No watcher (a Rex restart kills them): the sweep in the next call, from any pane, closes the orphan.
O3=$(orphan_pane)
D=$(orphan_launch "$O3" swept-child)
orphan_await_watchers "$O3" 1
kill "$(orphan_watchers "$O3")"
orphan_await_watchers "$O3" 0
rex_test block close -s "$REX_SESSION" "$O3"
sleep 2
check 'without a watcher the orphan waits for a sweep' "$(orphan_open "$D" && echo open)" open
REX_BLOCK=$O2 cli status "$O_AGENT" > /dev/null 2> "$T/orphan.err"
check 'the sweep closes the orphan' "$(orphan_closed "$D" && echo closed)" closed
grep -Fq "closed $D, an orphan" "$T/orphan.err" || { cat "$T/orphan.err" >&2; echo 'the sweep did not report the close' >&2; exit 1; }
pass=$((pass+1))
# A sweep that finds a working orphan starts a watcher for it, which closes it when its turn ends.
O3=$(orphan_pane)
D=$(orphan_launch "$O3" swept-working)
orphan_await_watchers "$O3" 1
orphan_type "$D" working; orphan_await_state "$D" working
kill "$(orphan_watchers "$O3")"
orphan_await_watchers "$O3" 0
rm -f "$REX_ORCHESTRATOR_STATE_DIR/watch/${O3//[^A-Za-z0-9_-]/_}.alive"
rex_test block close -s "$REX_SESSION" "$O3"
check 'ls from another pane shows the waiting orphan' "$(orphan_ls "$O2" swept-working)" waiting
orphan_await_watchers "$O3" 1
check 'a restarted watcher appends to the log' \
  "$(grep -c 'watching the children' "$REX_ORCHESTRATOR_STATE_DIR/watch/${O3//[^A-Za-z0-9_-]/_}.log")" 2
orphan_type "$D" 'done'
orphan_await_closed "$D"

# The grace period: a finished orphan is closed only once it has passed.
O4=$(orphan_pane)
E=$(REX_ORCHESTRATOR_ORPHAN_GRACE=6s orphan_launch "$O4" grace-child)
rex_test block close -s "$REX_SESSION" "$O4"
sleep 2
check 'ls shows an orphan in its grace period' "$(orphan_ls "$O2" grace-child)" grace
check 'an orphan stays open during the grace period' "$(orphan_open "$E" && echo open)" open
orphan_await_closed "$E" 150

# The maximum wait: an orphan still working after it is left open and reported, never killed.
O4=$(orphan_pane)
E=$(REX_ORCHESTRATOR_ORPHAN_MAX_WAIT=2s orphan_launch "$O4" stuck-child)
orphan_type "$E" working; orphan_await_state "$E" working
rex_test block close -s "$REX_SESSION" "$O4"
for ((n=0;n<150;n++)); do [ "$(cat "$(orphan_sf "$E").orphan" 2>/dev/null)" != expired ] || break; sleep 0.1; done
check 'ls shows an orphan left open' "$(orphan_ls "$O2" stuck-child)" expired
grep -q "left $E open" "$REX_ORCHESTRATOR_STATE_DIR/watch/${O4//[^A-Za-z0-9_-]/_}.log" || {
  head -50 "$REX_ORCHESTRATOR_STATE_DIR"/watch/*.log >&2; echo 'the watcher did not report the orphan left open' >&2; exit 1; }
pass=$((pass+1))
orphan_type "$E" 'done'
orphan_await_watchers "$O4" 0
check 'an orphan left open stays open after its turn ends' "$(orphan_open "$E" && echo open)" open
REX_BLOCK=$O2 cli close --force "$E"

# The kill switch holds every orphan; removing it lets the watcher close them.
O4=$(orphan_pane)
E=$(orphan_launch "$O4" killed-child)
: > "$REX_ORCHESTRATOR_STATE_DIR/disabled"
rex_test block close -s "$REX_SESSION" "$O4"
sleep 6
check 'the kill switch keeps an orphan open' "$(orphan_open "$E" && echo open)" open
check 'ls shows an orphan the kill switch keeps' "$(orphan_ls "$O2" killed-child)" kept
rm "$REX_ORCHESTRATOR_STATE_DIR/disabled"
orphan_await_closed "$E"

# Opting out: no watcher starts, and no later sweep closes the child, whatever its environment.
O4=$(orphan_pane)
E=$(REX_ORCHESTRATOR_ORPHANS=keep orphan_launch "$O4" kept-child)
sleep 3.5
check 'an opted-out launch starts no watcher' "$(orphan_watchers "$O4" | wc -l | tr -d ' ')" 0
check 'an opted-out launch records its policy' "$(sed -n '9p' "$(orphan_sf "$E").own")" keep
rex_test block close -s "$REX_SESSION" "$O4"
check 'ls shows an opted-out orphan as kept' "$(orphan_ls "$O2" kept-child)" kept
sleep 0.5
check 'a sweep starts no watcher for a child launched with keep' "$(orphan_watchers "$O4" | wc -l | tr -d ' ')" 0
check 'an opted-out orphan stays open' "$(orphan_open "$E" && [ -s "$(orphan_sf "$E").own" ] && echo open)" open
REX_BLOCK=$O2 cli close --force "$E"
code=0; REX_ORCHESTRATOR_ORPHANS=sometimes REX_BLOCK=$O2 cli launch --no-cage --agent "$T/launch-agents/claude-steer" \
  --dir "$T/launch-work" > /dev/null 2> "$T/orphan.err" || code=$?
check 'launch refuses an unknown orphan policy' "$code" 2
grep -q 'REX_ORCHESTRATOR_ORPHANS takes close or keep' "$T/orphan.err"

# A record without a session (an older launch) is never an orphan, nor is an unreadable one.
O4=$(orphan_pane)
E=$(orphan_launch "$O4" legacy-child)
sed -i '' '8,$d' "$(orphan_sf "$E").own"
rex_test block close -s "$REX_SESSION" "$O4"
REX_BLOCK=$O2 cli ls > /dev/null
check 'a record without a session is left alone' "$(orphan_open "$E" && [ -s "$(orphan_sf "$E").own" ] && echo open)" open
REX_BLOCK=$O2 cli close --force "$E"

# A state dir whose name isn't ASCII: the watcher gets it byte for byte, and calls don't start another one. One whose
# name isn't UTF-8 is refused before anything starts.
orphan_ascii_state_dir=$REX_ORCHESTRATOR_STATE_DIR
export REX_ORCHESTRATOR_STATE_DIR="$T/orphan-é-state"
O4=$(orphan_pane)
E=$(orphan_launch "$O4" latin-child)
orphan_await_watchers "$O4" 1
for ((n=0;n<50;n++)); do [ ! -s "$REX_ORCHESTRATOR_STATE_DIR/watch/${O4//[^A-Za-z0-9_-]/_}.alive" ] || break; sleep 0.1; done
check 'the watcher of a non-ASCII state dir writes its heartbeat there' \
  "$([ -s "$REX_ORCHESTRATOR_STATE_DIR/watch/${O4//[^A-Za-z0-9_-]/_}.alive" ] && echo yes)" yes
REX_BLOCK=$O2 cli ls > /dev/null; sleep 0.5
check 'a call starts no second watcher for it' "$(orphan_watchers "$O4" | wc -l | tr -d ' ')" 1
rex_test block close -s "$REX_SESSION" "$O4"
orphan_await_closed "$E"
code=0; REX_ORCHESTRATOR_STATE_DIR="$T/orphan-"$'\377'"-state" REX_BLOCK=$O2 cli launch --no-cage \
  --agent "$T/launch-agents/claude-steer" --dir "$T/launch-work" > /dev/null 2> "$T/orphan.err" || code=$?
check 'a state dir whose name is not UTF-8 is refused' "$code" 2
grep -q 'refusing state dir' "$T/orphan.err"
export REX_ORCHESTRATOR_STATE_DIR=$orphan_ascii_state_dir

# Left running for live.sh: a watcher that must exit when the server goes away.
O_LAST=$(orphan_pane)
orphan_launch "$O_LAST" last-child > /dev/null
orphan_await_watchers "$O_LAST" 1
export REX_ORCHESTRATOR_STATE_DIR=$orphan_previous_state_dir REX_BLOCK=$orphan_previous_caller
unset REX_ORCHESTRATOR_ORPHAN_GRACE
