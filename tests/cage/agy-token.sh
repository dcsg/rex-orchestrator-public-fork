#!/bin/bash
# Exercise generated agy wrappers with sandbox-exec and shell probes. No agents, Rex, or real secret-store commands.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT=${REX_ORCHESTRATOR_SH:-$here/../../skills/rex-orchestrator/scripts/rex-orchestrator-bash.sh}
assets=$(cd "$(dirname "$SCRIPT")" && pwd -P)
test_bash=${HARNESS_BASH:-$BASH}
work=$(mktemp -d "${TMPDIR:-/tmp}/rex-agy-token.XXXXXX")
work=$(cd "$work" && pwd -P)
wrapper_pid=
trap '[ -z "$wrapper_pid" ] || kill -TERM "$wrapper_pid" 2>/dev/null || :; rm -rf "$work"' EXIT
pass=0 fail=0
check() {
  if [ "$2" = "$3" ]; then
    printf 'PASS  agy token: %s\n' "$1"; pass=$((pass + 1))
  else
    # Do not print actual/expected: even a failed check must never disclose token contents.
    printf 'FAIL  agy token: %s\n' "$1"; fail=$((fail + 1))
  fi
}
for f in note ere_escape sq real_path rmcage cage_emit acct_ok claude_account cage_build; do
  eval "$(awk -v f="$f() {" 'index($0, f) == 1 { on = 1; one = /}[[:space:]]*$/ } on { print } on && (one || /^}/) { exit }' "$SCRIPT")"
done
export HOME="$work/home"
unset CODEX_HOME XDG_CONFIG_HOME REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
# shellcheck disable=SC2034  # globals read by the extracted cage functions
CAGE_PROFILE="$assets/cage.sb" CAGE_TPL="$assets/cage"
CAGE_SECRETS="$HOME/.config/rex-orchestrator/cage-secrets"
# shellcheck disable=SC2034  # globals read by the extracted cage functions
CAGE_AGY_HOME="$CAGE_SECRETS/agy-home" STATE_DIR="$work/state" SCRIPT_DIR="$assets"
cage_tmp='' cage_wrapper=''
mkdir -p "$CAGE_AGY_HOME/.gemini/antigravity-cli" "$work/project" "$work/bin"
# Dummy bytes are only ever written to files or compared silently.
cat >"$work/expected" <<'TOKEN'
{"token":{"access_token":"fixture-access","token_type":"Bearer","refresh_token":"fixture-refresh","expiry":"2099-01-01T00:00:00Z","expires_in":3600},"auth_method":"oauth","id_token_email":"fixture@example.invalid"}
TOKEN
jq '.token' "$work/expected" >"$work/expected-top-level"
jq '.refresh_token = 5' "$work/expected" >"$work/expected-nested-mixed"
jq '.token = false' "$work/expected-top-level" >"$work/expected-top-level-mixed"
cat >"$work/bin/token-command" <<'CMD'
#!/bin/bash
case "$1" in
  success) cat "$2" ;;
  fail) cat "$2"; cat "$2" >&2; exit 9 ;;
  empty) exit 0 ;;
  invalid) printf '{' ;;
  missing) printf '{"token":{}}' ;;
  null) printf '{"token":{"refresh_token":null}}' ;;
  number) printf '{"token":{"refresh_token":5}}' ;;
  blank) printf '{"token":{"refresh_token":""}}' ;;
  top-null) printf '{"refresh_token":null}' ;;
  top-number) printf '{"refresh_token":5}' ;;
  top-blank) printf '{"refresh_token":""}' ;;
  array) jq -s . "$2" ;;
  multiple) cat "$2" "$2" ;;
  context)
    pwd -P >"$3/cwd"
    printf '%s' "$HOME" >"$3/home"
    /usr/bin/env | /usr/bin/sed 's/=.*//' | LC_ALL=C /usr/bin/sort >"$3/env-names"
    for plant in fnox.toml .mise.toml .envrc; do [ ! -e "$plant" ] || : >"$3/plant-used"; done
    cat "$2" ;;
  hold) cat "$2"; printf '%s' "$$" >"$3.pid"; : >"$3"; exec /bin/sleep 30 ;;
  background) /bin/sleep 30 & printf '%s' "$!" >"$3"; cat "$2" ;;
  drain)
    (trap ': >"$3.term"' TERM
      : >"$3.ready"
      while :; do /bin/sleep 0.05; done) &
    printf '%s' "$!" >"$3.pid"
    while [ ! -f "$3.ready" ]; do /bin/sleep 0.05; done
    cat "$2" ;;
esac
CMD
cat >"$work/bin/probe" <<'PROBE'
#!/bin/bash
while :; do case "${1:-}" in --mode | --settings) shift 2 ;; --*) shift ;; *) break ;; esac; done
mode=$1 code=$2
file="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
printf '%s\n' "$$" >"$HOME/started"
[ "${REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD+x}" != x ] && [ "${AGY_TOKEN_CMD+x}" != x ] || exit 91
case "$mode" in
  legacy) [ -s "$file" ] || exit 92 ;;
  *) [ -s "$file" ] && [ "$(stat -f %Lp "$file")" = 600 ] || exit 93 ;;
esac
cp "$file" "$HOME/observed"
case "$mode" in
  hold) exec /bin/sleep 30 ;;
  rewrite)
    trap '/bin/sleep 0.2; cp "$HOME/observed" "$file"; : >"$HOME/rewritten"; exit 0' HUP
    : >"$HOME/ready"
    while :; do /bin/sleep 0.05; done ;;
  stubborn)
    trap '' HUP TERM
    : >"$HOME/ready"
    while :; do /bin/sleep 0.05; done ;;
  private)
    if cat "$3" >/dev/null 2>&1; then exit 96; fi
    if (: >"$3") 2>/dev/null; then exit 97; fi ;;
  crash) kill -KILL "$$" ;;
  redirect) rm -f "$file"; rmdir "${file%/*}"; ln -s "$3" "${file%/*}" ;;
  tty) [ -t 0 ] && [ -t 1 ] && /bin/stty -g >/dev/null &&
         /usr/bin/perl -MPOSIX -e 'exit(POSIX::tcgetpgrp(0) == getpgrp(0) ? 0 : 1)' || exit 94
       : >"$HOME/tty-ok" ;;
esac
exit "$code"
PROBE
chmod +x "$work/bin/"*
cat >"$work/bin/terminal-runner" <<'RUNNER'
#!/bin/bash
pidfile=$1 statusfile=$2; shift 2
/bin/bash -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' -- "$pidfile" "$@"
printf '%s\n' "$?" >"$statusfile"
RUNNER
chmod +x "$work/bin/terminal-runner"
build() {
  cage_build agy "$work/bin/probe" "$work/project" >"$work/build.log" 2>&1
  ct=$cage_tmp file="$cage_tmp/home/.gemini/antigravity-cli/antigravity-oauth-token"
  cmd_file="${ct%/*}-commands/${ct##*/}"
  # Run the generated body under the selected bash, including 5.x (the deployed wrapper uses /bin/bash).
}
run() {
  rc=0
  (cd "$work/project" && "$test_bash" -p "$cage_wrapper" "$@") >"$work/out" 2>"$work/err" || rc=$?
}
gone() { [ ! -e "$file" ] && [ ! -L "$file" ] && echo yes || echo no; }
started() { [ -f "$ct/home/started" ] && echo yes || echo no; }
wait_file() {
  local i
  # shellcheck disable=SC2034  # bounded retry count
  for i in {1..200}; do [ ! -f "$1" ] || return 0; sleep 0.05; done
  return 1
}
command_for() { printf '%s %s %s' "$(sq "$work/bin/token-command")" "$1" "$(sq "${2:-$work/expected}")"; }
dead() { if kill -0 "$1" 2>/dev/null; then echo no; else echo yes; fi; }
start_terminal() {
  # Reset inherited dispositions as a real terminal does, before starting the supervising wrapper.
  /usr/bin/perl -e '$SIG{$_} = "DEFAULT" for qw(INT QUIT PIPE HUP TERM USR1 USR2 ALRM); exec @ARGV or die "cannot start terminal fixture\n"' \
    /usr/bin/script -q "$work/signal-log" "$work/bin/terminal-runner" "$ct/wrapper-pid" "$ct/status" \
    "$test_bash" -p "$cage_wrapper" "$@" </dev/null >"$work/out" 2>"$work/err" & terminal_pid=$!
  wait_file "$ct/wrapper-pid"
  wrapper_pid=$(cat "$ct/wrapper-pid")
}
finish_terminal() {
  wait_file "$ct/status" || :
  rc=$(cat "$ct/status" 2>/dev/null || echo missing); wrapper_pid=
  wait "$terminal_pid" || :
}
for code in 0 17; do
  export REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
  build
  check 'command file is private' "$(stat -f %Lp "$cmd_file")" 600
  check 'command text absent from agent-readable wrapper' "$(grep -Fq "$REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD" "$cage_wrapper" && echo shown || echo hidden)" hidden
  check 'command not evaluated while building wrapper' "$(gone)" yes
  run normal "$code"
  check "child status $code forwarded" "$rc" "$code"
  check "token present with mode 600 and environment scrubbed (exit $code)" "$(started)" yes
  check "token bytes preserved (exit $code)" "$(cmp -s "$work/expected" "$ct/home/observed" && echo yes || echo no)" yes
  check "token removed after exit $code" "$(gone)" yes
  check "command file removed after exit $code" "$([ ! -e "$cmd_file" ] && echo yes || echo no)" yes
done
# Accept both supported locations independently, including a malformed unused alternative path.
for shape in nested top-level nested-mixed top-level-mixed; do
  shape_fixture="$work/expected"
  [ "$shape" = nested ] || shape_fixture="$work/expected-$shape"
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success "$shape_fixture")
  build; run normal 0
  check "$shape refresh token accepted" "$rc" 0
  check "$shape payload preserved byte for byte" "$(cmp -s "$shape_fixture" "$ct/home/observed" && echo yes || echo no)" yes
  check "$shape token removed on exit" "$(gone)" yes
done
# The uncaged lookup cannot discover project configs or inherit project environment/startup hooks.
mkdir -p "$work/context" "$work/project/bin"
for plant in fnox.toml .mise.toml .envrc; do : >"$work/project/$plant"; done
printf '%s\n' ": >$(sq "$work/startup-hook-used")" >"$work/project/startup-hook"
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="$(command_for context) $(sq "$work/context")"
build
rc=0
(cd "$work/project" && /usr/bin/env BASH_ENV="$work/project/startup-hook" ENV="$work/project/startup-hook" \
  FNOX_CONFIG_FILE="$work/project/fnox.toml" MISE_ENV=planted DIRENV_DIR="$work/project" PROJECT_VALUE=planted \
  PATH="$work/project/bin:/usr/bin:/bin" "$cage_wrapper" normal 0) >"$work/out" 2>"$work/err" || rc=$?
check 'isolated command succeeds from a planted project' "$rc" 0
check 'command cwd is fixed at root' "$(cat "$work/context/cwd")" /
check 'command HOME is the trusted real home' "$(cat "$work/context/home")" "$HOME"
printf '%s\n' HOME LANG PATH PWD SHELL SHLVL _ >"$work/context/expected-names"
check 'command environment contains only the fixed allowlist' "$(cmp -s "$work/context/expected-names" "$work/context/env-names" && echo yes || echo no)" yes
check 'project configs are never discovered' "$([ ! -e "$work/context/plant-used" ] && echo yes || echo no)" yes
check 'BASH_ENV and ENV hooks never run' "$([ ! -e "$work/startup-hook-used" ] && echo yes || echo no)" yes
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
build; reserved_ct=$ct reserved_cmd=$cmd_file
command_outside=yes
case "$cmd_file/" in "${ct%/*}/"*) command_outside=no ;; esac
check 'command stored outside CAGE_ROOT' "$command_outside" yes
build; run private 0 "$reserved_cmd"
check 'agent cannot read or modify another pending command' "$rc" 0
rmcage "$reserved_ct" >"$work/close.log" 2>&1
check 'close removes command of an unstarted wrapper' "$([ ! -e "$reserved_cmd" ] && echo yes || echo no)" yes
normal_state=$STATE_DIR
STATE_DIR="$HOME/.config/git/custom-state"
build; git_command_ct=$ct git_command_file=$cmd_file
check 'pending command exists beneath git-config state override' "$([ -f "$git_command_file" ] && echo yes || echo no)" yes
build; run private 0 "$git_command_file"
check 'git-config read exception cannot reopen private commands' "$rc" 0
rmcage "$git_command_ct" >"$work/git-state-close.log" 2>&1
check 'close removes private command beneath git-config state override' "$([ ! -e "$git_command_file" ] && echo yes || echo no)" yes
STATE_DIR=$normal_state
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="$(command_for background) $(sq "$work/provider-pid")"
build; run normal 0
check 'lookup with a background provider succeeds' "$rc" 0
check 'background provider is stopped before agent startup' "$(dead "$(cat "$work/provider-pid")")" yes
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
build; : >"$ct/home"; run normal 0
check 'failed home seeding stops the wrapper' "$([ "$rc" -ne 0 ] && echo yes || echo no)" yes
check 'failed home seeding removes the private command' "$([ ! -e "$cmd_file" ] && echo yes || echo no)" yes
check 'failed home seeding never starts the agent' "$(started)" no
build; run crash 0
check 'agent crash status forwarded' "$rc" 137
check 'agent crash removes token' "$(gone)" yes
mkdir -p "$work/outside"
cp "$work/expected" "$work/outside/antigravity-oauth-token"
build; run redirect 0 "$work/outside"
check 'child can replace token parent with a link' "$rc" 0
check 'cleanup leaves external token behind a parent link alone' \
  "$(cmp -s "$work/expected" "$work/outside/antigravity-oauth-token" && echo yes || echo no)" yes
for mode in fail empty invalid missing null number blank top-null top-number top-blank array multiple; do
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for "$mode")
  build; run normal 0
  check "$mode command exits distinctly" "$rc" 71
  check "$mode command prevents agent startup" "$(started)" no
  check "$mode command removes partial file" "$(gone)" yes
  check "$mode command file removed" "$([ ! -e "$cmd_file" ] && echo yes || echo no)" yes
  check "$mode command emits one safe diagnostic" "$(wc -l <"$work/err" | tr -d ' ')" 1
  check "$mode diagnostic names variable" "$(grep -c 'REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD' "$work/err")" 1
  check "$mode stdout empty" "$([ ! -s "$work/out" ] && echo yes || echo no)" yes
done
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=''
build; run normal 0
check 'set but empty command fails closed' "$rc" 71
check 'set but empty command removes token' "$(gone)" yes
for signal in HUP INT TERM QUIT PIPE USR1 USR2 ALRM; do
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
  build
  start_terminal hold 0
  if wait_file "$ct/home/started"; then
    child_pid=$(cat "$ct/home/started")
    kill -s "$signal" "$wrapper_pid"
    finish_terminal
    expected=$((128 + $(kill -l "$signal")))
    check "$signal wrapper status" "$rc" "$expected"
    check "$signal removes token" "$(gone)" yes
    check "$signal child is dead before wrapper returns" "$(dead "$child_pid")" yes
  else
    check "$signal fixture starts" no yes
    [ ! -f "$ct/wrapper-pid" ] || kill -TERM "$(cat "$ct/wrapper-pid")" 2>/dev/null || :
  fi
done
for mode in rewrite stubborn; do
  build; start_terminal "$mode" 0
  if wait_file "$ct/home/ready"; then
    child_pid=$(cat "$ct/home/started")
    signal_start=$SECONDS
    kill -HUP "$wrapper_pid"
    finish_terminal
    check "$mode HUP returns 129" "$rc" 129
    check "$mode child is reaped" "$(dead "$child_pid")" yes
    check "$mode shutdown token removed" "$(gone)" yes
    if [ "$mode" = rewrite ]; then
      check 'HUP handler actually rewrote the token before exit' "$([ -f "$ct/home/rewritten" ] && echo yes || echo no)" yes
    else
      check 'uncooperative child is killed within a bounded wait' "$([ $((SECONDS - signal_start)) -le 10 ] && echo yes || echo no)" yes
    fi
  else check "$mode fixture starts" no yes; fi
done
# Interrupt exactly between fork and AGY_PID assignment. The job-table fallback must reap that child too.
build
awk '{print} /^  agy_run "\$@" <&0 &$/ {print "  jobs -p >\"$CT/race-pid\"\n  kill -HUP \"$$\""}' \
  "$cage_wrapper" >"$ct/bin/race"
mv "$ct/bin/race" "$cage_wrapper"; chmod +x "$cage_wrapper"
start_terminal hold 0
finish_terminal
check 'signal in fork-to-PID-assignment window returns 129' "$rc" 129
check 'fork-race child is dead' "$(dead "$(cat "$ct/race-pid")")" yes
check 'fork-race token removed' "$(gone)" yes
# HUP while the command is still writing also removes its partial output and never starts the agent.
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="$(command_for hold) $(sq "$work/command-started")"
build
"$test_bash" -p "$cage_wrapper" normal 0 >"$work/out" 2>"$work/err" & wrapper_pid=$!
if wait_file "$work/command-started"; then
  kill -HUP "$wrapper_pid"; rc=0; wait "$wrapper_pid" || rc=$?; wrapper_pid=
  check 'HUP during provisioning returns 129' "$rc" 129
  check 'HUP during provisioning removes partial token' "$(gone)" yes
  check 'HUP during provisioning prevents agent startup' "$(started)" no
  check 'HUP during provisioning reaps command process' "$(dead "$(cat "$work/command-started.pid")")" yes
  check 'HUP during provisioning removes private command' "$([ ! -e "$cmd_file" ] && echo yes || echo no)" yes
else check 'provisioning fixture starts' no yes; fi
# Cancellation during the normal provider-drain grace period must be replayed before agent startup.
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="$(command_for drain) $(sq "$work/draining-provider")"
build; start_terminal normal 0
if wait_file "$work/draining-provider.term"; then
  kill -HUP "$wrapper_pid"
  finish_terminal
  check 'HUP while draining providers returns 129' "$rc" 129
  check 'HUP while draining providers prevents agent startup' "$(started)" no
  check 'HUP while draining providers removes token' "$(gone)" yes
  check 'HUP while draining providers removes private command' "$([ ! -e "$cmd_file" ] && echo yes || echo no)" yes
else check 'draining-provider fixture starts' no yes; fi
# A real pty catches /dev/null stdin and background process group regressions without starting a TUI.
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
build
rc=0
/usr/bin/script -q "$work/tty-log" "$test_bash" -p "$cage_wrapper" tty 0 </dev/null >/dev/null 2>&1 || rc=$?
check 'pty child exits successfully' "$rc" 0
check 'child keeps terminal stdin, stdout and foreground process group' "$([ -f "$ct/home/tty-ok" ] && echo yes || echo no)" yes
check 'pty exit removes token' "$(gone)" yes
unset REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
cp "$work/expected" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
chmod 644 "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
build; run legacy 23
check 'unset command forwards original exit status' "$rc" 23
check 'unset command keeps copied login' "$([ -f "$file" ] && echo yes || echo no)" yes
check 'unset command keeps original mode' "$(stat -f %Lp "$file")" 644
check 'source login unchanged' "$(cmp -s "$work/expected" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token" && echo yes || echo no)" yes
# Force known cage names to verify refusal never unlinks a pre-existing file or follows a rejected parent link.
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
guard_leaf=agy.collision
# shellcheck disable=SC2329  # Called indirectly by the extracted cage_build function.
mktemp() { mkdir "$STATE_DIR/cage/$guard_leaf"; printf '%s' "$STATE_DIR/cage/$guard_leaf"; }
printf 'preserve\n' >"$work/preserve"
cp "$work/preserve" "$STATE_DIR/cage-commands/$guard_leaf"
guard_rc=0
cage_build agy "$work/bin/probe" "$work/project" >"$work/guard.log" 2>&1 || guard_rc=$?
check 'private-command collision fails closed' "$guard_rc" 2
check 'private-command collision preserves existing file' \
  "$(cmp -s "$work/preserve" "$STATE_DIR/cage-commands/$guard_leaf" && echo yes || echo no)" yes
mv "$STATE_DIR/cage-commands" "$work/saved-command-root"
mkdir "$work/linked-command-root"
ln -s "$work/linked-command-root" "$STATE_DIR/cage-commands"
guard_leaf=agy.link
cp "$work/preserve" "$work/linked-command-root/$guard_leaf"
guard_rc=0
cage_build agy "$work/bin/probe" "$work/project" >"$work/guard.log" 2>&1 || guard_rc=$?
check 'linked private-command root fails closed' "$guard_rc" 2
check 'linked private-command root leaves external file alone' \
  "$(cmp -s "$work/preserve" "$work/linked-command-root/$guard_leaf" && echo yes || echo no)" yes
rmcage "$STATE_DIR/cage/$guard_leaf" >"$work/guard-close.log" 2>&1
check 'close removes the refused cage' "$([ ! -e "$STATE_DIR/cage/$guard_leaf" ] && echo yes || echo no)" yes
check 'close never follows a linked private-command root' \
  "$(cmp -s "$work/preserve" "$work/linked-command-root/$guard_leaf" && echo yes || echo no)" yes
unset -f mktemp
rm "$STATE_DIR/cage-commands"; mv "$work/saved-command-root" "$STATE_DIR/cage-commands"
printf 'agy token: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
