# shellcheck shell=bash
# Sourced by live.sh with a throwaway Rex socket, home and state.
launch_fixture() {
  local app=$1 mode=$2 path="$T/launch-agents/$3"
  printf '#!/bin/bash\nexec /bin/bash %q %q %q %q "$@"\n' "$ROOT/tests/lua/launch-standin.sh" "$app" "$mode" "$T" > "$path"
  chmod +x "$path"
}
launch_case() {
  local rc=0
  expected_launch=$1 name=$2
  shift 2
  mkdir -p "$T/launch-work/$name"
  cli launch --no-cage --dir "$T/launch-work/$name" --label "$name" --timeout 8 "$@" > "$T/launch.out" 2> "$T/launch.err" || rc=$?
  if [ "$rc" != "$expected_launch" ]; then cat "$T/launch.err" "$T/launch.out" >&2; fi
  check "launch $name exit" "$rc" "$expected_launch"
  child=$(cat "$T/launch.out")
  case "$rc" in
    0 | 3 | 12 | 124)
      case "$child" in block:*) ;; *) echo "launch $name did not return a block ID" >&2; exit 1 ;; esac ;;
    *) check "launch $name reports no block" "$child" '' ;;
  esac
}
launch_close() { cli close "$child" > "$T/launch-close.out" 2> "$T/launch-close.err" || { cat "$T/launch-close.err" >&2; exit 1; }; }
launch_previous_caller=$REX_BLOCK
mkdir -p "$T/launch-agents" "$T/launch-work" "$HOME/.codex"
printf '{}\n' > "$HOME/.codex/auth.json"
launch_fixture claude-code ready claude
launch_fixture claude-code scoped claude-scoped
launch_fixture claude-code trust claude-trust
launch_fixture claude-code trust-no claude-down
launch_fixture claude-code trust-wrong claude-wrong
launch_fixture claude-code bypass claude-bypass
launch_fixture claude-code never claude-never
launch_fixture claude-code exits claude-exits
launch_fixture codex ready codex
launch_fixture codex hooks codex-hooks
launch_fixture antigravity agy-fixture agy
rex_test session new lua-launch --shell none --keep-open --json -- /bin/cat > "$T/launch-session.json"
REX_SESSION=$(jq -r .session_id "$T/launch-session.json")
export REX_BLOCK
REX_BLOCK=$(jq -r '.initial_windows[0].block_ids[0]' "$T/launch-session.json")
rm -f "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude"
for guard in disabled disabled.claude; do
  : > "$REX_ORCHESTRATOR_STATE_DIR/$guard"
  launch_case 2 "$guard" --agent "$T/launch-agents/claude"
  grep -Fq "$REX_ORCHESTRATOR_STATE_DIR/$guard is set" "$T/launch.err"
  rm "$REX_ORCHESTRATOR_STATE_DIR/$guard"
done
launch_case 2 no-recipe --cage --kind muse --agent "$T/launch-agents/claude-never"
grep -q 'no cage recipe' "$T/launch.err"
REX_ORCHESTRATOR_CAGE_PROFILE="$T/missing-profile" launch_case 2 missing-profile --cage --agent "$T/launch-agents/codex"
grep -q 'profile not found' "$T/launch.err"
REX_ORCHESTRATOR_CAGE_TPL="$T/missing-template" launch_case 2 missing-template --cage --agent "$T/launch-agents/codex"
grep -q 'missing template' "$T/launch.err"
check 'failed profile and template builds leave no cage' \
  "$(if [ -d "$REX_ORCHESTRATOR_STATE_DIR/cage" ]; then ls -A "$REX_ORCHESTRATOR_STATE_DIR/cage"; fi)" ''
for crafted in 'claude:❯ Yes, I trust this folder' 'agy:> Yes, I trust this folder' \
  'codex:› 1. Trust and continue' 'muse:⟩ Do you trust' 'grok:Yes, proceed y No, quit n'; do
  kind=${crafted%%:*}
  crafted_dir="$T/launch-work/${crafted#*:}"
  mkdir -p "$crafted_dir"
  launch_case 2 "crafted-$kind" --agent "$T/launch-agents/claude" --kind "$kind" --dir "$crafted_dir" --trust
  grep -q 'refuses a directory name' "$T/launch.err"
  if [ -f "$OLD" ]; then
    expect_error "$kind crafted trust path" "$REX_SESSION" "$REX_BLOCK" 2 'refuses a directory name' \
      launch --no-cage --agent "$T/launch-agents/claude" --kind "$kind" --dir "$crafted_dir" --trust
  fi
done
launch_case 2 previous-directory --agent "$T/launch-agents/claude" --dir -
grep -q 'no such directory: -' "$T/launch.err"
launch_case 0 ready --agent "$T/launch-agents/claude" --split below --ratio 70
sf="$REX_ORCHESTRATOR_STATE_DIR/${child//[^A-Za-z0-9_-]/_}"
check 'launch saves the caller' "$(sed -n '1p' "$sf.own")" "$REX_BLOCK"
check 'launch saves the permission mode' "$(sed -n '6p' "$sf.own")" '⏸ manual mode on'
check 'launch saves the canonical claim' "$(cli claims --json | jq -r --arg id "$child" 'select(.block==$id) | .canonical_dir')" "$(cd "$T/launch-work/ready" && pwd -P)"
first_child=$child
check 'launch respects the split ratio' \
  "$(rex_test block call -s "$REX_SESSION" -b "$child" size | jq '.rows > 12')" true
launch_case 2 overlap --dir "$T/launch-work/ready" --agent "$T/launch-agents/claude"
grep -q 'already has a live write claim' "$T/launch.err"
child=$first_child; launch_close
mkdir -p "$XDG_CONFIG_HOME/rex-orchestrator"
printf 'codex # fixture allowlist\n' > "$XDG_CONFIG_HOME/rex-orchestrator/orchestrators"
launch_case 2 undesignated --agent "$T/launch-agents/claude"
grep -q 'only codex may orchestrate' "$T/launch.err"
rm "$XDG_CONFIG_HOME/rex-orchestrator/orchestrators"
# Reached through a link, so the logical DIR differs from the physical one and both get rules (T itself is physical).
mkdir -p "$T/launch-work/scoped"; ln -s "$T/launch-work/scoped" "$T/scoped-link"
launch_case 0 scoped --agent "$T/launch-agents/claude-scoped" --allow-edits --allow 'Bash(npm test:*)' --dir "$T/scoped-link"
check 'launch includes the approved command and both scoped paths' \
  "$(jq -r '.permissions.allow | length' "$T/launch-work/scoped/scoped-rules")" 5
check 'launch preserves the explicit scoped command' \
  "$(jq -r '.permissions.allow[0]' "$T/launch-work/scoped/scoped-rules")" 'Bash(npm test:*)'
launch_close
launch_case 2 conflicting-settings --agent "$T/launch-agents/claude-scoped" --allow-edits -- --settings '{"permissions":{}}'
grep -q "can't be combined with -- --settings" "$T/launch.err"
launch_case 3 untrusted --agent "$T/launch-agents/claude-trust" --tab untrusted
check 'launch left the trust selection alone' "$([ -e "$T/launch-work/untrusted/presses" ] && echo pressed || echo untouched)" untouched
launch_close
launch_case 0 trusted --agent "$T/launch-agents/claude-trust" --tab trusted --trust
check 'launch approves matching trust once' "$(cat "$T/launch-work/trusted/presses")" enter
launch_close
launch_case 0 trusted-down --agent "$T/launch-agents/claude-down" --tab trusted-down --trust
check 'launch selects the trust option with Down' "$(cat "$T/launch-work/trusted-down/arrow")" "$(printf '\033[B')"
check 'launch confirms the displayed option once' "$(cat "$T/launch-work/trusted-down/presses")" enter
launch_close
launch_case 3 wrong-path --agent "$T/launch-agents/claude-wrong" --tab wrong-path --trust
grep -q "dialog doesn't name" "$T/launch.err"
check 'wrong path trust got no keys' "$([ -e "$T/launch-work/wrong-path/presses" ] && echo pressed || echo untouched)" untouched
launch_close
mkdir -p "$T/launch-work/ancestor/fixture-config"
: > "$T/launch-work/ancestor/ancestor-fixture"
CLAUDE_CONFIG_DIR="$T/launch-work/ancestor/fixture-config" \
  launch_case 3 ancestor --agent "$T/launch-agents/claude-trust" --tab ancestor --trust
check 'launch disables uncaged Claude when its trust answer changed an ancestor' \
  "$([ -s "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude" ] && echo disabled)" disabled
launch_close
rm "$REX_ORCHESTRATOR_STATE_DIR/disabled.claude"
launch_case 3 hooks --agent "$T/launch-agents/codex-hooks" --kind codex --tab hooks --trust
grep -q 'hooks review' "$T/launch.err"
check 'hook review got no keys' "$([ -e "$T/launch-work/hooks/presses" ] && echo pressed || echo untouched)" untouched
launch_close
launch_case 2 bypass --agent "$T/launch-agents/claude-bypass" --tab bypass
grep -q 'started in bypass permissions mode' "$T/launch.err"
grep -q 'launch stopped before the agent was ready; closed block:' "$T/launch.err"
launch_case 12 exits --agent "$T/launch-agents/claude-exits" --tab exits
grep -q 'exited during startup' "$T/launch.err"
launch_close
launch_case 124 never --agent "$T/launch-agents/claude-never" --timeout 0
launch_close
if test_nested_sandbox; then
  test_skip_nested 'a caged codex launch'
else
mkdir "$T/launch-work/caged O'Brien [work]"
launch_case 0 caged --dir "$T/launch-work/caged O'Brien [work]" --cage --agent "$T/launch-agents/codex" \
  --tab 'Caged fixture' --trust
sf="$REX_ORCHESTRATOR_STATE_DIR/${child//[^A-Za-z0-9_-]/_}"
cage="$REX_ORCHESTRATOR_STATE_DIR/cage/$(sed -n '1p' "$sf.cage")"
check 'launch created an executable cage wrapper' "$([ -x "$cage/bin/codex" ] && echo yes)" yes
check 'caged codex trusts the exact task directory' "$(grep -A1 -F "$(cd "$T/launch-work/caged O'Brien [work]" && pwd -P)" "$cage/codex-home/config.toml" | tail -1)" 'trust_level = "trusted"'
check 'caged launch saves harvest metadata' "$(jq -r .block "$cage/run-meta.json")" "$child"
launch_close
check 'close removed the generated cage' "$([ ! -e "$cage" ] && echo removed)" removed
fi
launch_case 2 cage-overlap --dir "$HOME" --cage --agent "$T/launch-agents/codex"
grep -q 'refusing a caged codex' "$T/launch.err"
check 'failed cage setup removes the unused cage' "$(find "$REX_ORCHESTRATOR_STATE_DIR/cage" -mindepth 1 -print)" ''

export REX_ORCHESTRATOR_CAGE_AGY_HOME="$T/agy-login"
if test_nested_sandbox; then
  test_skip_nested 'a caged agy launch'
else
mkdir -p "$REX_ORCHESTRATOR_CAGE_AGY_HOME/.gemini/antigravity-cli"
printf '{"model":"test-only"}\n' > "$REX_ORCHESTRATOR_CAGE_AGY_HOME/.gemini/antigravity-cli/settings.json"
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="printf '%s\\n' '{\"refresh_token\":\"stand-in-only\"}'" \
  launch_case 0 agy --cage --agent "$T/launch-agents/agy" --tab agy
sf="$REX_ORCHESTRATOR_STATE_DIR/${child//[^A-Za-z0-9_-]/_}"
cage="$REX_ORCHESTRATOR_STATE_DIR/cage/$(sed -n '1p' "$sf.cage")"
check 'generated agy cage carries the model setting' "$(jq -r .model "$T/launch-work/agy/agy-settings")" test-only
check 'generated agy wrapper hides the provider command' "$(grep -Fc stand-in-only "$cage/bin/agy" || :)" 0
check 'generated agy deletes the private command after provisioning' \
  "$(find "$REX_ORCHESTRATOR_STATE_DIR/cage-commands" -mindepth 1 -print)" ''
launch_close
check 'close removed the generated agy cage and fixture token' "$([ ! -e "$cage" ] && echo removed)" removed
fi
for linked in gemini antigravity-cli; do
  login="$T/agy-link-$linked"
  outside="$T/agy-outside-$linked"
  mkdir -p "$login" "$outside"
  if [ "$linked" = gemini ]; then
    mkdir "$outside/antigravity-cli"
    ln -s "$outside" "$login/.gemini"
  else
    mkdir "$login/.gemini"
    ln -s "$outside" "$login/.gemini/antigravity-cli"
  fi
  REX_ORCHESTRATOR_CAGE_AGY_HOME="$login" \
    REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="printf '%s\\n' '{\"refresh_token\":\"stand-in-only\"}'" \
    launch_case 12 "agy-linked-$linked" --cage --agent "$T/launch-agents/agy" --tab "agy-linked-$linked"
  grep -Fq 'symlink-free' "$T/launch.err"
  check "agy launch with a symlinked $linked writes no external token" \
    "$(find "$outside" -type f -print)" ''
  launch_close
done
unset REX_ORCHESTRATOR_CAGE_AGY_HOME

mkdir "$T/launch-work/racing"
cli launch --no-cage --agent "$T/launch-agents/claude" --dir "$T/launch-work/racing" --tab first-racer \
  > "$T/first-racer.out" 2> "$T/first-racer.err" & first_racer=$!
cli launch --no-cage --agent "$T/launch-agents/claude" --dir "$T/launch-work/racing" --tab second-racer \
  > "$T/second-racer.out" 2> "$T/second-racer.err" & second_racer=$!
first_code=0 second_code=0
wait "$first_racer" || first_code=$?
wait "$second_racer" || second_code=$?
check 'concurrent launches only issue one write claim' \
  "$(printf '%s\n' "$first_code" "$second_code" | sort -n | paste -sd, -)" '0,2'
child=$(cat "$T/first-racer.out" "$T/second-racer.out")
launch_close

for signal_and_code in HUP:129 INT:130 TERM:143; do
  sig=${signal_and_code%%:*}
  mkdir "$T/launch-work/cancel-$sig"
  : > "$T/cancel.err"
  # The asynchronous test job inherits ignored INT. Reset it the way a terminal does.
  /usr/bin/perl -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec @ARGV or die "exec fixture\n"' \
    /bin/bash "$CLI" launch --no-cage --agent "$T/launch-agents/claude-never" --dir "$T/launch-work/cancel-$sig" \
    --tab cancel --label cancel > "$T/cancel.out" 2> "$T/cancel.err" &
  launch_pid=$!
  for ((n=0;n<160;n++)); do grep -q 'launched block:' "$T/cancel.err" && break; sleep 0.05; done
  if ! grep -q 'launched block:' "$T/cancel.err"; then cat "$T/cancel.err" >&2; exit 1; fi
  cancelled=$(sed -n 's/.*launched \(block:[^ ]*\) in .*/\1/p' "$T/cancel.err")
  kill -s "$sig" "$launch_pid"
  code=0; wait "$launch_pid" || code=$?
  check "launch interrupted by $sig exits with its signal status" "$code" "${signal_and_code#*:}"
  check "launch interrupted by $sig reports no ID" "$(cat "$T/cancel.out")" ''
  check "launch interrupted by $sig removes the claim" "$(cli claims --json | jq -r --arg id "$cancelled" 'select(.block==$id) | .block')" ''
  grep -q 'launch stopped before the agent was ready; closed block:' "$T/cancel.err" || {
    cat "$T/cancel.err" >&2
    exit 1
  }
done

# Simulate Rex making a pane before the launcher receives and stores its ID.
missing="$T/recovery"
rex_test 'do' -e '
  assert(rex.call("session.attach",{session_id=rex.args.s}))
  local term=rex.layout.block{flavor="com.superlogical.terminal.shell",label=rex.args.tag,
    options={command={"/bin/cat"},shell="none",login=false,exit={on_completion=false}}}
  local pane=assert(rex.session.new_split{session_id=rex.args.s,anchor_id=rex.args.b,
    direction="horizontal",side="after",ratio=0.5,layout=term,focus=false})
  print(pane.block_ids[1])' "s=$REX_SESSION" "b=$REX_BLOCK" tag=unreported-launch > "$T/recovery-block"
jq -nc --arg session "$REX_SESSION" --arg owner "$REX_BLOCK" \
  '{session:$session, owner:$owner,tag:"unreported-launch"}' > "$missing"
jq -nc --arg script "${CLI%/*}" --arg journal "$missing" \
  '{recover:true,script_dir:$script,journal:$journal}' | rex_test 'do' "${CLI%/*}/lua/main.lua" --args - --fail-fast \
  > "$T/recovery.out" 2> "$T/recovery.err"
check 'recovery finds an unreported pane by its temporary label' \
  "$(sed -n 's/.*ready; closed \(block:[^ ]*\)$/\1/p' "$T/recovery.err")" "$(cat "$T/recovery-block")"

if test_nested_sandbox; then
  test_skip_nested 'recovery of a caged launch whose close Rex refuses'
else
launch_case 0 recovery-close-refused --agent "$T/launch-agents/codex" --cage --tab recovery-close-refused
sf="$REX_ORCHESTRATOR_STATE_DIR/${child//[^A-Za-z0-9_-]/_}"
cage="$(cd "$REX_ORCHESTRATOR_STATE_DIR/cage/$(sed -n '1p' "$sf.cage")" && pwd -P)"
jq -nc --arg session "$REX_SESSION" --arg owner "$REX_BLOCK" --arg block "$child" --arg cage "$cage" \
  '{session:$session, owner:$owner,block:$block,cage:$cage}' > "$missing"
jq -nc --arg script "${CLI%/*}" --arg journal "$missing" \
  '{recover:true,script_dir:$script,journal:$journal}' | rex_test 'do' -e '
    local api=rex
    rex=setmetatable({call=function(method,args)
      if method=="block.close" then return nil,"injected close refusal" end
      return api.call(method,args)
    end},{__index=api})
    dofile(rex.args.script_dir .. "/lua/main.lua")' --args - --fail-fast > "$T/recovery.out" 2> "$T/recovery.err"
grep -Fq "could not close $child; run close $child" "$T/recovery.err"
check 'recovery keeps the claim if Rex refuses close' \
  "$(cli claims --json | jq -r --arg id "$child" 'select(.block==$id) | .block')" "$child"
check 'recovery keeps ownership and cage state if Rex refuses close' \
  "$([ -s "$sf.own" ] && [ -s "$sf.cage" ] && [ -d "$cage" ] && echo retained)" retained
launch_close
fi

repo="$T/clone-source"
git init -q -b main "$repo"
printf 'fixture\n' > "$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgSign=false commit -qm fixture
printf 'untracked fixture\n' > "$repo/untracked"
check 'Lua clone returns the destination' "$(cli clone "$repo" "$T/clone online" -b isolated)" "$T/clone online"
check 'Lua clone switches branches' "$(git -C "$T/clone online" branch --show-current)" isolated
check 'APFS clone preserves untracked contents' "$(cat "$T/clone online/untracked")" 'untracked fixture'
code=0; cli clone "$repo" "$T/clone online" > "$T/clone.out" 2> "$T/clone.err" || code=$?
check 'clone refuses an existing destination' "$code" 2
check 'clone leaves an existing destination intact' "$(cat "$T/clone online/tracked")" fixture
check 'clone uses the caller working directory' "$(cd "$T" && cli clone clone-source 'clone relative')" 'clone relative'
check 'clone creates missing destination parents' "$(cli clone "$repo" "$T/missing/parents/clone")" "$T/missing/parents/clone"
code=0; cli clone "$T/no-such-source" "$T/unused-dest" > "$T/clone.out" 2> "$T/clone.err" || code=$?
check 'missing source exits 2' "$code" 2
check 'missing source diagnostic names REPO' "$(cat "$T/clone.err")" "rex-orchestrator: clone: no such REPO: $T/no-such-source"
check 'clone works without a running Rex server' "$(REX_SERVER="unix://$T/offline.sock" cli clone "$repo" "$T/clone-offline")" "$T/clone-offline"
REX_BLOCK=$launch_previous_caller
