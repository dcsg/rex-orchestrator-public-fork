#!/bin/bash
# Exercise generated agy wrappers with sandbox-exec and shell probes. No agents, Rex, or real secret-store commands.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT=${REX_ORCHESTRATOR_SH:-$here/../../skills/rex-orchestrator/scripts/rex-orchestrator.sh}
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
for f in note ere_escape sq real_path cage_emit acct_ok claude_account cage_build; do
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
printf '{"refresh_token":"fixture-login"}\n' >"$work/expected"
cat >"$work/bin/token-command" <<'CMD'
#!/bin/bash
case "$1" in
  success) cat "$2" ;;
  fail) cat "$2"; cat "$2" >&2; exit 9 ;;
  empty) exit 0 ;;
  hold) cat "$2"; : >"$3"; exec /bin/sleep 30 ;;
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
  crash) kill -KILL "$$" ;;
  redirect) rm -f "$file"; rmdir "${file%/*}"; ln -s "$3" "${file%/*}" ;;
  tty) [ -t 0 ] && [ -t 1 ] && /bin/stty -g >/dev/null || exit 94
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
  # Run the generated body under the selected bash, including 5.x (the deployed wrapper uses /bin/bash).
}
run() {
  rc=0
  "$test_bash" "$cage_wrapper" "$@" >"$work/out" 2>"$work/err" || rc=$?
}
gone() { [ ! -e "$file" ] && [ ! -L "$file" ] && echo yes || echo no; }
started() { [ -f "$ct/home/started" ] && echo yes || echo no; }
wait_file() {
  local i
  # shellcheck disable=SC2034  # bounded retry count
  for i in {1..100}; do [ ! -f "$1" ] || return 0; sleep 0.05; done
  return 1
}
command_for() { printf '%s %s %s' "$(sq "$work/bin/token-command")" "$1" "$(sq "$work/expected")"; }
for code in 0 17; do
  export REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
  build
  check 'command not evaluated while building wrapper' "$(gone)" yes
  run normal "$code"
  check "child status $code forwarded" "$rc" "$code"
  check "token present with mode 600 and environment scrubbed (exit $code)" "$(started)" yes
  check "token bytes preserved (exit $code)" "$(cmp -s "$work/expected" "$ct/home/observed" && echo yes || echo no)" yes
  check "token removed after exit $code" "$(gone)" yes
done
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
build; run crash 0
check 'agent crash status forwarded' "$rc" 137
check 'agent crash removes token' "$(gone)" yes
mkdir -p "$work/outside"
cp "$work/expected" "$work/outside/antigravity-oauth-token"
build; run redirect 0 "$work/outside"
check 'child can replace token parent with a link' "$rc" 0
check 'cleanup leaves external token behind a parent link alone' \
  "$(cmp -s "$work/expected" "$work/outside/antigravity-oauth-token" && echo yes || echo no)" yes
for mode in fail empty; do
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for "$mode")
  build; run normal 0
  check "$mode command exits distinctly" "$rc" 71
  check "$mode command prevents agent startup" "$(started)" no
  check "$mode command removes partial file" "$(gone)" yes
  check "$mode command emits one safe diagnostic" "$(wc -l <"$work/err" | tr -d ' ')" 1
  check "$mode diagnostic names variable" "$(grep -c 'REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD' "$work/err")" 1
  check "$mode stdout empty" "$([ ! -s "$work/out" ] && echo yes || echo no)" yes
done
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=''
build; run normal 0
check 'set but empty command fails closed' "$rc" 71
check 'set but empty command removes token' "$(gone)" yes
for signal in HUP INT TERM; do
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
  build
  # Start in a pty: shells started directly with & inherit SIGINT ignored, unlike a Rex pane.
  /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "cannot start terminal fixture\n"' \
    /usr/bin/script -q "$work/signal-log" "$work/bin/terminal-runner" "$ct/wrapper-pid" "$ct/status" \
    "$test_bash" "$cage_wrapper" hold 0 </dev/null >"$work/out" 2>"$work/err" & terminal_pid=$!
  if wait_file "$ct/wrapper-pid" && wait_file "$ct/home/started"; then
    wrapper_pid=$(cat "$ct/wrapper-pid")
    child_pid=$(cat "$ct/home/started")
    kill -s "$signal" "$wrapper_pid"
    wait_file "$ct/status" || :
    rc=$(cat "$ct/status" 2>/dev/null || echo missing); wrapper_pid=
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    check "$signal wrapper status" "$rc" "$expected"
    check "$signal removes token" "$(gone)" yes
    # A shell probe may inherit ignored INT in the asynchronous child; agy installs its own TUI signal handlers.
    kill -TERM "$child_pid" 2>/dev/null || :
  else
    check "$signal fixture starts" no yes
    [ ! -f "$ct/wrapper-pid" ] || kill -TERM "$(cat "$ct/wrapper-pid")" 2>/dev/null || :
  fi
  wait "$terminal_pid" || :
done
# HUP while the command is still writing also removes its partial output and never starts the agent.
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="$(command_for hold) $(sq "$work/command-started")"
build
"$test_bash" "$cage_wrapper" normal 0 >"$work/out" 2>"$work/err" & wrapper_pid=$!
if wait_file "$work/command-started"; then
  kill -HUP "$wrapper_pid"; rc=0; wait "$wrapper_pid" || rc=$?; wrapper_pid=
  check 'HUP during provisioning returns 129' "$rc" 129
  check 'HUP during provisioning removes partial token' "$(gone)" yes
  check 'HUP during provisioning prevents agent startup' "$(started)" no
else check 'provisioning fixture starts' no yes; fi
# A real pty catches /dev/null stdin and background process group regressions without starting a TUI.
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
build
rc=0
/usr/bin/script -q "$work/tty-log" "$test_bash" "$cage_wrapper" tty 0 </dev/null >/dev/null 2>&1 || rc=$?
check 'pty child exits successfully' "$rc" 0
check 'child keeps terminal stdin and stdout' "$([ -f "$ct/home/tty-ok" ] && echo yes || echo no)" yes
check 'pty exit removes token' "$(gone)" yes
unset REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
cp "$work/expected" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
chmod 644 "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
build; run legacy 23
check 'unset command forwards original exit status' "$rc" 23
check 'unset command keeps copied login' "$([ -f "$file" ] && echo yes || echo no)" yes
check 'unset command keeps original mode' "$(stat -f %Lp "$file")" 644
check 'source login unchanged' "$(cmp -s "$work/expected" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token" && echo yes || echo no)" yes
printf 'agy token: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
