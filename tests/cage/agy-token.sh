#!/bin/bash -p
# Exercise generated agy wrappers with sandbox-exec and shell probes. No agents, Rex, or real secret-store commands.
set -euo pipefail
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh"
here=$(cd "$(dirname "$0")" && pwd -P)
assets=$(cd "$here/../../skills/rex-orchestrator/scripts" && pwd -P)
ASSETS=$assets
test_bash=${REX_TEST_BASH:-$BASH}
work=$(mktemp -d "${TMPDIR:-/tmp}/rex-agy-token.XXXXXX")
work=$(cd "$work" && pwd -P)
wrapper_pid=
has_pty=0
if test_has_pty; then has_pty=1; fi
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
# shellcheck source=skills/rex-orchestrator/scripts/cage-cleanup.sh
. "$assets/cage-cleanup.sh"
# shellcheck source=tests/cage/build.inc.sh
. "$here/build.inc.sh"
export HOME="$work/home"
# shellcheck disable=SC2034  # read by the fixture driver
CAGE_PROFILE="$assets/cage.sb" CAGE_TPL="$assets/cage"
CAGE_SECRETS="$HOME/.config/rex-orchestrator/cage-secrets"
# shellcheck disable=SC2034  # read by the fixture driver
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
  full) : >"$3"; ulimit -f 0; exec /bin/cat "$2" ;;
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
  replace-dir)
    mv "${file%/*}" "${file%/*}.moved"
    mkdir "${file%/*}"
    printf 'replacement\n' >"$file" ;;
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
cleanup_cage "$reserved_ct" >"$work/close.log" 2>&1
check 'close removes command of an unstarted wrapper' "$([ ! -e "$reserved_cmd" ] && echo yes || echo no)" yes
normal_state=$STATE_DIR
STATE_DIR="$HOME/.config/git/custom-state"
build; git_command_ct=$ct git_command_file=$cmd_file
check 'pending command exists beneath git-config state override' "$([ -f "$git_command_file" ] && echo yes || echo no)" yes
build; run private 0 "$git_command_file"
check 'git-config read exception cannot reopen private commands' "$rc" 0
cleanup_cage "$git_command_ct" >"$work/git-state-close.log" 2>&1
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
spill="$work/inherited-stdout"
marker="$work/read-only-provider"
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=": >$(sq "$marker"); $(command_for success)"
build
mkdir -p "${file%/*}"
chmod 500 "${file%/*}"
# Turn off errexit at the open so this exercises the wrapper's explicit failure path.
sed '/^[[:space:]]*exec 3>\.\/antigravity-oauth-token/i\
      set +e
' "$cage_wrapper" >"$ct/bin/read-only"
mv "$ct/bin/read-only" "$cage_wrapper"; chmod +x "$cage_wrapper"
run normal 0 3>"$spill"
chmod 700 "${file%/*}"
check 'read-only token directory exits 71 before the provider runs' "$rc:$(started):$([ -e "$marker" ] && echo ran || echo blocked)" '71:no:blocked'
check 'read-only token directory leaves neither a token nor output on inherited fd 3' "$(gone):$([ -s "$spill" ] && echo wrote || echo empty)" 'yes:empty'
marker="$work/full-disk-provider"
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD="$(command_for full) $(sq "$marker")"
build; run normal 0 3>"$spill"
check 'full-disk stand-in exits 71 after the provider attempts to write' "$rc:$(started):$([ -e "$marker" ] && echo ran || echo missing)" '71:no:ran'
check 'full-disk stand-in leaves neither a token nor escaped output' "$(gone):$([ -s "$spill" ] && echo wrote || echo empty)" 'yes:empty'
provisioned_home=$CAGE_AGY_HOME
for linked in gemini antigravity-cli home token unrelated; do
  CAGE_AGY_HOME="$work/provisioned-$linked"
  target="$work/external-$linked"
  marker="$work/provider-$linked"
  mkdir -p "$target"
  if [ "$linked" = home ]; then
    mkdir -p "$target/.gemini/antigravity-cli"
    ln -s "$target" "$CAGE_AGY_HOME"
    CAGE_AGY_HOME="$CAGE_AGY_HOME/"
    target="$target/.gemini/antigravity-cli"
  elif [ "$linked" = gemini ]; then
    mkdir "$CAGE_AGY_HOME"
    mkdir "$target/antigravity-cli"
    ln -s "$target" "$CAGE_AGY_HOME/.gemini"
    target="$target/antigravity-cli"
  elif [ "$linked" = antigravity-cli ]; then
    mkdir -p "$CAGE_AGY_HOME/.gemini"
    ln -s "$target" "$CAGE_AGY_HOME/.gemini/antigravity-cli"
  else
    mkdir -p "$CAGE_AGY_HOME/.gemini/antigravity-cli" "$CAGE_AGY_HOME/unrelated/deep"
    if [ "$linked" = token ]; then
      ln -s "$target/antigravity-oauth-token" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
    else
      ln -s "$target" "$CAGE_AGY_HOME/unrelated/deep/link"
    fi
  fi
  printf 'keep fixture\n' > "$target/antigravity-oauth-token"
  REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=": >$(sq "$marker"); $(command_for success)"
  build; run normal 0
  check "symlinked $linked fails before agy starts" "$rc:$(started)" '71:no'
  check "symlinked $linked is diagnosed before the provider runs" \
    "$([ ! -e "$marker" ] && grep -Fq 'symlink-free' "$work/err" && echo rejected)" rejected
  check "symlinked $linked leaves the external fixture untouched" "$(cat "$target/antigravity-oauth-token")" 'keep fixture'
  check "symlinked $linked removes its unused lookup command" "$([ ! -e "$cmd_file" ] && echo removed)" removed
done
CAGE_AGY_HOME="$work/swap-home"
mkdir -p "$CAGE_AGY_HOME/.gemini/antigravity-cli" "$CAGE_AGY_HOME.decoy/.gemini/antigravity-cli"
marker="$work/swap-provider"
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=": >$(sq "$marker"); $(command_for success)"
build
awk '/^[[:space:]]*\(cd -P -- "\$source_dir"/ {
  print "  /bin/mv \"$source_dir\" \"$source_dir.before\""
  print "  /bin/ln -s \"$source_dir.decoy\" \"$source_dir\""
} {print}' "$cage_wrapper" >"$ct/bin/swap"
mv "$ct/bin/swap" "$cage_wrapper"; chmod +x "$cage_wrapper"
run normal 0
check 'swapping the provisioned home after the scan stops startup' "$rc:$(started):$([ -L "$CAGE_AGY_HOME" ] && echo swapped || echo missing)" '71:no:swapped'
check 'the source swap never runs the provider or writes a token' "$([ ! -e "$marker" ] && [ ! -e "$CAGE_AGY_HOME.decoy/.gemini/antigravity-cli/antigravity-oauth-token" ] && echo safe)" safe
# Split the copy's cd into its path walk and chdir so every attempt exercises a stale cached PWD.
rm "$CAGE_AGY_HOME"; mv "$CAGE_AGY_HOME.before" "$CAGE_AGY_HOME"
build
cat >"$work/split-cd" <<'FIXTURE'
  cd() {
    local walked
    walked=$(builtin cd "$@" && /bin/pwd -P) || return
    /bin/mv "$source_dir" "$source_dir.before" || return
    /bin/ln -s "$REX_TEST_AGY_DECOY" "$source_dir" || return
    builtin cd "$@" || return
    [ "$(/bin/pwd -P && printf .)" = "$REX_TEST_AGY_DECOY"$'\n.' ] || return
    PWD=$walked
    : >"$CT/swapped-during-cd"
  }
FIXTURE
awk -v fixture="$work/split-cd" '/^[[:space:]]*\(cd -P -- "\$source_dir"/ {
  while ((getline line < fixture) > 0) print line
  close(fixture)
} {print}' "$cage_wrapper" >"$ct/bin/split-cd"
mv "$ct/bin/split-cd" "$cage_wrapper"; chmod +x "$cage_wrapper"
attempts=0 refused=0 copied=0
for decoy in "$CAGE_AGY_HOME.decoy" "$CAGE_AGY_HOME"$'\n'; do
  mkdir -p "$decoy"
  : >"$decoy/decoy-marker"
  for ((attempt=0; attempt<16; attempt++)); do
    rm -f "$ct/swapped-during-cd"
    (umask 077; printf '%s\n' "$REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD" >"$cmd_file")
    REX_TEST_AGY_DECOY="$decoy" run normal 0
    [ ! -f "$ct/swapped-during-cd" ] || attempts=$((attempts + 1))
    [ "$rc:$(started)" != '71:no' ] || refused=$((refused + 1))
    [ ! -e "$ct/home/decoy-marker" ] || copied=$((copied + 1))
    if [ -L "$CAGE_AGY_HOME" ]; then rm "$CAGE_AGY_HOME"; mv "$CAGE_AGY_HOME.before" "$CAGE_AGY_HOME"; fi
  done
done
check 'all 32 split cd attempts reach the decoy with a stale PWD' "$attempts" 32
check 'a swap during cd always stops startup before copying from the decoy' "$refused:$copied" '32:0'
check 'a swap during cd never runs the provider' "$([ ! -e "$marker" ] && echo safe)" safe
# Swap the unmodified wrapper's source home for a symlink concurrently. Whatever the interleaving, a launch either
# copies the real home or refuses; the bounded attempt count keeps pass/fail independent of timing.
race_home="$work/race-home"
mkdir -p "$race_home/.gemini/antigravity-cli" "$race_home.decoy/.gemini/antigravity-cli"
: >"$race_home/real-marker"
: >"$race_home.decoy/decoy-marker"
printf 'legacy fixture\n' >"$race_home/.gemini/antigravity-cli/antigravity-oauth-token"
printf 'legacy fixture\n' >"$race_home.decoy/.gemini/antigravity-cli/antigravity-oauth-token"
saved_token_cmd=$REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
unset REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
CAGE_AGY_HOME=$race_home build
export REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$saved_token_cmd
# Flip the state every few milliseconds with direct syscalls, so launches see both states and the moments between.
# The real home stays longer, so some launches get through the whole copy while a flip is due.
/usr/bin/perl -e '
  my ($home, $stop, $count) = @ARGV;
  my $flips = 0;
  while (!-e $stop && -d "$home.decoy") {
    rename($home, "$home.before") or next;
    symlink("$home.decoy", $home) or die "cannot plant the race symlink\n";
    select(undef, undef, undef, rand(0.003));
    unlink($home) or die "cannot remove the race symlink\n";
    rename("$home.before", $home) or die "cannot restore the race home\n";
    $flips++;
    select(undef, undef, undef, rand(0.02));
  }
  open(my $out, ">", $count) or die "cannot record the race flips\n";
  print $out "$flips\n";' "$race_home" "$work/race-stop" "$work/race-flips" & swapper_pid=$!
race_runs=0 race_copied=0 race_decoy=0 race_refused=0 race_other=0
for ((attempt=0; attempt<300; attempt++)); do
  rm -rf "${ct:?}/home"
  run legacy 0
  race_runs=$((race_runs + 1))
  if [ -e "$ct/home/decoy-marker" ]; then race_decoy=$((race_decoy + 1)); fi
  case "$rc" in
    0) if [ -e "$ct/home/real-marker" ]; then race_copied=$((race_copied + 1)); else race_other=$((race_other + 1)); fi ;;
    70) if [ "$(started)" = no ]; then race_refused=$((race_refused + 1)); else race_other=$((race_other + 1)); fi ;;
    *) race_other=$((race_other + 1)) ;;
  esac
done
: >"$work/race-stop"
swapper_rc=0
wait "$swapper_pid" || swapper_rc=$?
rm -f "$work/race-stop"
if [ -L "$race_home" ]; then rm "$race_home"; fi
if [ ! -e "$race_home" ]; then mv "$race_home.before" "$race_home"; fi
printf 'INFO  agy token: concurrent swap race copied %s and refused %s of %s launches across %s flips\n' \
  "$race_copied" "$race_refused" "$race_runs" "$(cat "$work/race-flips" 2>/dev/null || echo 0)"
check 'concurrent swapper flipped the home and stopped cleanly' \
  "$swapper_rc:$([ "$(cat "$work/race-flips" 2>/dev/null || echo 0)" -gt 0 ] && echo flipped)" '0:flipped'
check 'concurrent symlink swaps run 300 bounded launches' "$race_runs" 300
check 'concurrent symlink swaps never copy from the other folder' "$race_decoy" 0
check 'concurrent symlink swaps either copy the real home or refuse with 70' "$race_other" 0
CAGE_AGY_HOME="$work/project/shared-login"
mkdir -p "$CAGE_AGY_HOME" "$CAGE_AGY_HOME/task"
ln -s "$CAGE_AGY_HOME" "$work/alias-login"
for task in "$work/project" "$CAGE_AGY_HOME" "$CAGE_AGY_HOME/task"; do
  overlap_rc=0
  CAGE_AGY_HOME="$work/alias-login" cage_build agy "$work/bin/probe" "$task" >"$work/overlap.log" 2>&1 || overlap_rc=$?
  check "provisioned home overlapping DIR ${task##*/} is refused" "$overlap_rc:$(grep -Fc 'overlaps DIR' "$work/overlap.log")" '2:1'
done
mkdir "$work/separate-login"
ln -s "$work/separate-login" "$work/project/external-login"
overlap_rc=0
CAGE_AGY_HOME="$work/project/external-login" cage_build agy "$work/bin/probe" "$work/project" >"$work/overlap.log" 2>&1 || overlap_rc=$?
check 'provisioned home named through a link inside DIR is refused' "$overlap_rc:$(grep -Fc 'overlaps DIR' "$work/overlap.log")" '2:1'
check_aliased_overlap() {
  local label=$1 login=$2 task=$3 overlap_rc=0
  CAGE_AGY_HOME="$login" cage_build agy "$work/bin/probe" "$task" >"$work/overlap.log" 2>&1 || overlap_rc=$?
  check "launcher refuses $label" "$overlap_rc:$(grep -Fc 'overlaps DIR' "$work/overlap.log")" '2:1'

  # Build with a separate home to exercise the wrapper's own check for the alternate spelling.
  CAGE_AGY_HOME="$work/separate-login" cage_build agy "$work/bin/probe" "$task" >"$work/build.log" 2>&1
  ct=$cage_tmp
  sed "s|RH_AGY='[^']*'|RH_AGY=$(sq "$login")|" "$cage_wrapper" >"$ct/bin/alias-wrapper"
  mv "$ct/bin/alias-wrapper" "$cage_wrapper"; chmod +x "$cage_wrapper"
  run normal 0
  check "wrapper refuses $label before copying" \
    "$rc:$([ ! -e "$ct/home" ] && grep -Fc 'overlaps DIR' "$work/err")" '71:1'
}
if [ -d "$work/Project" ]; then
  check_aliased_overlap 'a case-different home inside DIR' "$work/Project/shared-login" "$work/project"
  check_aliased_overlap 'DIR inside a case-different home' "$work/Project" "$work/project/shared-login/task"
else
  test_skip 'agy overlap checks need a case-insensitive test volume'
fi
data_work="/System/Volumes/Data$work"
if [ -d "$data_work/project" ] && [ "$(stat -f '%d:%i' "$data_work")" = "$(stat -f '%d:%i' "$work")" ]; then
  check_aliased_overlap 'a home inside a firmlink spelling of DIR' "$work/project/shared-login" "$data_work/project"
  check_aliased_overlap 'a firmlink spelling of DIR inside a home' "$work/project/shared-login" "$data_work/project/shared-login/task"
else
  test_skip 'agy overlap checks need a Data volume firmlink for the test directory'
fi
CAGE_AGY_HOME="$work/separate-login"
for unsafe in tab:$'\t' invalid-utf8:$'\377' bidi-override:$'\342\200\256' bidi-isolate:$'\342\201\246'; do
  # The refusal comes before any use of DIR; APFS cannot even create the invalid UTF-8 name.
  unsafe_dir="$work/unsafe-${unsafe%%:*}-${unsafe#*:}-dir"
  unsafe_rc=0
  cage_build agy "$work/bin/probe" "$unsafe_dir" >"$work/unsafe.log" 2>&1 || unsafe_rc=$?
  check "caged DIR with ${unsafe%%:*} is refused" \
    "$unsafe_rc:$(grep -Fc 'contains terminal controls, invalid UTF-8, or bidirectional overrides or isolates' "$work/unsafe.log")" '2:1'
done
CAGE_AGY_HOME=$provisioned_home
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
ct=$(
  cd "$work"
  CAGE_AGY_HOME="${provisioned_home#"$work/"}" cage_build agy "$work/bin/probe" "$work/project" 2>"$work/build.log"
  printf '%s\n' "$cage_tmp"
)
cage_wrapper="$ct/bin/agy"
run normal 0
check 'a relative provisioned home resolves against the launcher cwd' "$rc:$(started)" '0:yes'
build; run crash 0
check 'agent crash status forwarded' "$rc" 137
check 'agent crash removes token' "$(gone)" yes
mkdir -p "$work/outside"
cp "$work/expected" "$work/outside/antigravity-oauth-token"
build; run redirect 0 "$work/outside"
check 'child can replace token parent with a link' "$rc" 0
check 'cleanup leaves external token behind a parent link alone' \
  "$(cmp -s "$work/expected" "$work/outside/antigravity-oauth-token" && echo yes || echo no)" yes
build; run replace-dir 0
check 'a replacement directory is left for close' "$rc:$(cat "$file")" '0:replacement'
check 'wrapper exit leaves the moved original directory for close' "$([ -f "${file%/*}.moved/antigravity-oauth-token" ] && echo kept)" kept
cleanup_cage "$ct" >"$work/moved-close.log" 2>&1
check 'close removes the cage including the moved token' "$([ ! -e "$ct" ] && echo removed)" removed
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

REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
build
printf '#!/bin/bash\nexit 69\n' > "$work/missing-lua.sh"
sed "s| LOCAL_LUA='[^']*'| LOCAL_LUA='$work/missing-lua.sh'|" "$cage_wrapper" > "$ct/bin/without-lua"
mv "$ct/bin/without-lua" "$cage_wrapper"; chmod +x "$cage_wrapper"
run normal 0
check 'missing LuaJIT fails closed before startup' "$rc:$(started)" '71:no'
check 'missing LuaJIT reports the dependency' "$(grep -Fc 'requires LuaJIT' "$work/err")" 1
check 'missing LuaJIT removes the token' "$(gone)" yes
if [ "$has_pty" -eq 1 ]; then
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
else
  test_skip 'agy terminal signal and fork-race checks cannot allocate a pty in this environment'
fi
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
if [ "$has_pty" -eq 1 ]; then
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
else
  test_skip 'agy provider-drain and foreground terminal checks cannot allocate a pty in this environment'
fi
unset REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
cp "$work/expected" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
chmod 644 "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token"
build; run legacy 23
check 'unset command forwards original exit status' "$rc" 23
check 'unset command keeps copied login' "$([ -f "$file" ] && echo yes || echo no)" yes
check 'unset command keeps original mode' "$(stat -f %Lp "$file")" 644
check 'source login unchanged' "$(cmp -s "$work/expected" "$CAGE_AGY_HOME/.gemini/antigravity-cli/antigravity-oauth-token" && echo yes || echo no)" yes
# Force known cage names to verify refusal never unlinks a pre-existing file or follows a rejected parent link.
export REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD
REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD=$(command_for success)
guard_leaf=agy.collision
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
cleanup_cage "$STATE_DIR/cage/$guard_leaf" >"$work/guard-close.log" 2>&1
check 'close removes the refused cage' "$([ ! -e "$STATE_DIR/cage/$guard_leaf" ] && echo yes || echo no)" yes
check 'close never follows a linked private-command root' \
  "$(cmp -s "$work/preserve" "$work/linked-command-root/$guard_leaf" && echo yes || echo no)" yes
rm "$STATE_DIR/cage-commands"; mv "$work/saved-command-root" "$STATE_DIR/cage-commands"
printf 'agy token: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
