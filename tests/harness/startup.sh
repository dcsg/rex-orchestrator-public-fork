#!/bin/bash
# Startup regressions against the fake Rex. No agent binary or real Rex server is run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT=${REX_ORCHESTRATOR_SH:-$here/../../skills/rex-orchestrator/scripts/rex-orchestrator.sh}
SCRIPT=$(cd "$(dirname "$SCRIPT")" && pwd -P)/$(basename "$SCRIPT")
test_bash=${HARNESS_BASH:-/bin/bash}
work=$(mktemp -d /tmp/rex-startup.XXXXXX)
trap 'rm -rf "$work"' EXIT
orch=block:01a1c0de-0000-7000-8000-00000000a0a0
child=block:01a1c0de-0000-7000-8000-00000000c1d1
pass=0 fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf 'PASS  startup: %s\t%s\n' "$1" "$2"; pass=$((pass + 1))
  else
    printf 'FAIL  startup: %s\tgot [%s], want [%s]\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}
setup() {
  case_dir="$work/$1"; mkdir -p "$case_dir/home" "$case_dir/work"
  session='' set_session=0 caller=$orch whoami_rc=0 whoami_out='{"session_id":"session:resolved"}'
  cli_script=$SCRIPT profile='' templates=''
  jq -nc --arg orch "$orch" --arg child "$child" \
    '{orch:$orch,new_block:$child,blocks:{($child):{steps:[{records:[{app:"muse",state:"idle",updated_at:"2026-11-01T10:00:00Z"}],screen:"ready",argv0:"muse",pid:4242}]}}}' \
    >"$case_dir/scenario.json"
}
cli() {
  local session_env=("REX_BLOCK=$caller")
  [ "$set_session" -eq 0 ] || session_env+=("REX_SESSION=$session")
  rc=0
  env -i HOME="$case_dir/home" PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "${session_env[@]}" REX_ORCHESTRATOR_REX_BIN_DIR="$here/bin" \
    REX_ORCHESTRATOR_STATE_DIR="$case_dir/state" FAKE_REX_DIR="$case_dir" \
    REX_ORCHESTRATOR_CAGE_PROFILE="$profile" REX_ORCHESTRATOR_CAGE_TPL="$templates" \
    FAKE_REX_WHOAMI_RC="$whoami_rc" FAKE_REX_WHOAMI_OUT="$whoami_out" \
    "$test_bash" "$cli_script" "$@" >"$case_dir/out" 2>"$case_dir/err" || rc=$?
}
whoami_count() { if [ -f "$case_dir/whoami.log" ]; then wc -l <"$case_dir/whoami.log" | tr -d ' '; else echo 0; fi; }
launch() { cli launch --no-cage --agent "$here/agents/muse" --kind muse -d "$case_dir/work" -b "$orch" --split right --timeout 10; }

for mode in block-only empty-session both; do
  setup "$mode"
  [ "$mode" != empty-session ] || set_session=1
  [ "$mode" != both ] || { session=session:explicit; set_session=1; whoami_rc=1; }
  expected=${session:-session:resolved}
  launch
  check "$mode launch" "$rc" 0
  check "$mode child" "$(cat "$case_dir/out")" "$child"
  count=1; [ "$mode" != both ] || count=0
  check "$mode resolves exactly once, only when needed" "$(whoami_count)" "$count"
  check "$mode stores real session in ownership registry" "$(jq -r .session "$case_dir/state/registry/"*.json)" "$expected"
  check "$mode every later Rex call has the real session ID" \
    "$(jq -sr --arg sid "$expected" 'all(.[]; .argv as $a | ($a | index("-s")) as $i | $i != null and $a[$i+1] == $sid)' "$case_dir/calls.jsonl")" true
done

for mode in neither whoami-fails malformed missing null numeric block-id empty-id whitespace multiple; do
  setup "$mode"
  case "$mode" in
    neither) caller='' ;;
    whoami-fails) whoami_rc=1 ;;
    malformed) whoami_out='not JSON' ;;
    missing) whoami_out='{}' ;;
    null) whoami_out='{"session_id":null}' ;;
    numeric) whoami_out='{"session_id":23}' ;;
    block-id) whoami_out='{"session_id":"block:wrong"}' ;;
    empty-id) whoami_out='{"session_id":"session:"}' ;;
    whitespace) whoami_out='{"session_id":"session:bad id"}' ;;
    multiple) whoami_out='{"session_id":"session:a"} {"session_id":"session:b"}' ;;
  esac
  cli ls
  check "$mode refuses with usage exit" "$rc" 2
  check "$mode error names both variables" "$(grep -c 'REX_SESSION.*REX_BLOCK' "$case_dir/err")" 1
  check "$mode makes no later Rex calls" "$([ ! -s "$case_dir/calls.jsonl" ] && echo yes || echo no)" yes
done

setup standalone; caller='' whoami_rc=1
for command in help claims; do
  cli "$command"
  check "$command needs no caller session" "$rc" 0
done
check 'standalone commands skip whoami' "$(whoami_count)" 0

# Real caged launch setup through installed CLI links; the fake Rex only records the wrapper, never executes it.
assets=$(dirname "$SCRIPT")
mkdir -p "$work/install space/bin"
ln -s "$SCRIPT" "$work/install space/bin/absolute"
ln -s "$assets" "$work/install space/assets"
ln -s "../assets/${SCRIPT##*/}" "$work/install space/bin/relative"
ln -s absolute "$work/install space/bin/chain"
for mode in absolute relative chain overrides; do
  setup "symlink-$mode"
  cli_script="$work/install space/bin/$mode"
  expected_profile="$assets/cage.sb" expected_templates="$assets/cage"
  if [ "$mode" = overrides ]; then
    cli_script="$work/install space/bin/chain"
    profile="$case_dir/override profile.sb" templates="$case_dir/override templates"
    cp "$assets/cage.sb" "$profile"; mkdir -p "$templates"; cp "$assets/cage/codex.toml" "$templates/"
    expected_profile=$profile expected_templates=$templates
  fi
  mkdir -p "$case_dir/home/.codex"; printf '{}\n' >"$case_dir/home/.codex/auth.json"
  jq --arg child "$child" '.blocks[$child].steps[0] |= (.argv0="codex" | .records[0].app="codex" | .screen="? for shortcuts")' \
    "$case_dir/scenario.json" >"$case_dir/scenario.tmp"
  mv "$case_dir/scenario.tmp" "$case_dir/scenario.json"
  cli launch --cage --trust --agent "$here/agents/codex" -d "$case_dir/work" -b "$orch" --split right --timeout 10
  check "$mode symlink caged launch" "$rc" 0
  check "$mode symlink wrapper uses resolved profile" \
    "$(grep -F -c "PROF='$expected_profile'" "$case_dir/state/cage/"*/bin/codex)" 1
  check "$mode symlink wrapper uses resolved templates" \
    "$(grep -F -c "TPL='$expected_templates'" "$case_dir/state/cage/"*/bin/codex)" 1
  check "$mode symlink seeds the template" \
    "$(grep -F -c 'trust_level = "trusted"' "$case_dir/state/cage/"*/codex-home/config.toml)" 1
done
printf 'startup: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
