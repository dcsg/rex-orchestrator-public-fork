# shellcheck shell=bash disable=SC2064
unset REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD AGY_TOKEN_CMD
AGY_PID='' AGY_TOKEN_FILE='' AGY_GROUP=0 AGY_PENDING=''
if [ -n "$AGY_CMD_FILE" ]; then
  agy_active() { jobs -pr; jobs -ps; }
  agy_stop() {
    local sig="$1" p active pending deadline pids target
    # A signal can arrive after the fork but before AGY_PID=$!: the shell's job table already owns that child.
    pids=${AGY_PID:-$(jobs -p)}
    agy_traps "${2:-ignore}"
    # A pipeline gives jobs an empty job table in bash 3.2; capture directly, then normalize in the shell.
    active=$(agy_active); active=" ${active//$'\n'/ } "
    for p in $pids; do
      target=$p; [ "$AGY_GROUP" -eq 0 ] || target="-$p"
      if [ "$AGY_GROUP" -eq 1 ]; then kill -s "$sig" -- "$target" 2>/dev/null || :
      else case "$active" in *" $p "*) kill -s "$sig" -- "$target" 2>/dev/null || : ;; esac; fi
    done
    deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$deadline" ]; do
      active=$(agy_active); active=" ${active//$'\n'/ } " pending=0
      for p in $pids; do
        if [ "$AGY_GROUP" -eq 1 ]; then
          kill -0 -- "-$p" 2>/dev/null && pending=1
        else case "$active" in *" $p "*) pending=1 ;; esac; fi
      done
      [ "$pending" -eq 1 ] || break
      /bin/sleep 0.05
    done
    active=$(agy_active); active=" ${active//$'\n'/ } "
    for p in $pids; do
      if [ "$AGY_GROUP" -eq 1 ]; then kill -KILL -- "-$p" 2>/dev/null || :
      else case "$active" in *" $p "*) kill -KILL "$p" 2>/dev/null || : ;; esac; fi
      wait "$p" 2>/dev/null || :
    done
    AGY_PID=
  }
  agy_cleanup() {
    agy_stop TERM
    /bin/rm -f "$AGY_CMD_FILE"
    [ -n "$AGY_TOKEN_FILE" ] || return 0
    # The child can replace its writable parents with links. Pin the physical directory as cwd before unlinking,
    # and require the original directory: cleanup runs unsandboxed and must never delete a real-home credential.
    (cd -P -- "${AGY_TOKEN_FILE%/*}" 2>/dev/null || exit 0
      if [ "$PWD" = "${AGY_TOKEN_FILE%/*}" ]; then /bin/rm -f ./antigravity-oauth-token; fi)
  }
  agy_signal() {
    local sig="${AGY_PENDING:-$1}" status
    status=$((128 + $(kill -l "$sig")))
    # Asynchronous children inherit ignored INT/QUIT without job control. TERM guarantees they can be stopped.
    case "$sig" in INT | QUIT) sig=TERM ;; esac
    agy_stop "$sig"
    exit "$status"
  }
  agy_traps() {
    local sig
    for sig in HUP INT TERM QUIT PIPE USR1 USR2 ALRM; do
      case "${1:-handle}" in
        defer) trap "AGY_PENDING=\${AGY_PENDING:-$sig}" "$sig" ;;
        ignore) trap '' "$sig" ;;
        *) trap "agy_signal $sig" "$sig" ;;
      esac
    done
  }
  trap agy_cleanup EXIT
  agy_traps
fi
agy_safe_home() {
  local link
  [ -n "$1" ] && [ ! -L "$1" ] && [ -d "$1" ] &&
    link=$(/usr/bin/find -P "$1" -type l -print -quit 2>/dev/null) && [ -z "$link" ]
}
agy_refuse_home() {
  echo 'rex-orchestrator cage: agy requires symlink-free provisioned and cage homes; agy not started' >&2
  if [ -n "$AGY_CMD_FILE" ]; then exit 71; fi
  exit 70
}
# Copy physically, and check the private copy before doing any uncaged token work.
source_home=$RH_AGY
case "$source_home" in /*) ;; ?*) source_home="$PWD/$source_home" ;; esac
# A trailing slash would make the directory tests follow a symlink at the home itself.
while [ "$source_home" != / ] && [[ "$source_home" == */ ]]; do source_home=${source_home%/}; done
agy_safe_home "$source_home" || agy_refuse_home
if [ -L "$CT/home" ] || ! /bin/mkdir -p "$CT/home"; then agy_refuse_home; fi
if [ ! -d "$CT/home/.gemini" ]; then
  (cd -P -- "$source_home" && [ ! -L "$source_home" ] && /bin/cp -RP . "$CT/home/") 2>/dev/null || agy_refuse_home
fi
agy_safe_home "$CT/home" || agy_refuse_home
if [ -n "$AGY_CMD_FILE" ]; then
  token_dir="$CT/home/.gemini/antigravity-cli"
  (umask 077; /bin/mkdir -p "$token_dir") || agy_refuse_home
  AGY_TOKEN_FILE="$token_dir/antigravity-oauth-token"
  # Suppress command diagnostics too: a failed shell command can quote its input or the credential in stderr.
  # Only the noninteractive lookup gets its own process group, so cancellation reaches provider subprocesses too.
  # Disable job control again before agy starts: its TUI must stay in the terminal's foreground group.
  { set -m; AGY_GROUP=1
    (umask 077
      # Pin the checked directory and create an exclusive 0600 file before changing to the lookup's cwd.
      cd -P -- "$token_dir" && [ "$PWD" = "$token_dir" ] &&
        [ ! -L ./antigravity-oauth-token ] && /bin/rm -f ./antigravity-oauth-token || exit 71
      set -C
      exec 3>./antigravity-oauth-token
      cd / && exec /usr/bin/env -i HOME="$RH" PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
        SHELL=/bin/bash LANG=en_US.UTF-8 /bin/bash --noprofile --norc "$AGY_CMD_FILE" >&3 3>&-
    ) </dev/null &
    AGY_PID=$!
    AGY_TOKEN_RC=0
    wait "$AGY_PID" || AGY_TOKEN_RC=$?
    # Reap/stop any provider subprocesses left behind even when the command shell has already exited.
    agy_stop TERM defer
    set +m; AGY_GROUP=0
    agy_traps
    [ -z "$AGY_PENDING" ] || agy_signal "$AGY_PENDING"
  } 2>/dev/null
  AGY_PID=
  /bin/rm -f "$AGY_CMD_FILE"
  validation_status=0
  if [ "$AGY_TOKEN_RC" -eq 0 ]; then
    /bin/bash -p "$LOCAL_LUA" validate-agy "$AGY_TOKEN_FILE" >/dev/null 2>&1 || validation_status=$?
  fi
  if [ "$validation_status" -eq 69 ]; then
    echo 'rex-orchestrator cage: agy token validation requires LuaJIT. Install it with brew install luajit.' >&2
    exit 71
  fi
  if [ "$AGY_TOKEN_RC" -ne 0 ] || [ "$validation_status" -ne 0 ]; then
    echo 'rex-orchestrator cage: REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD failed or returned invalid token JSON; agy not started' >&2
    exit 71
  fi
fi
agy_run() {
  exec /usr/bin/env -i HOME="$CT/home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" TMPDIR="$CT/" \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --dangerously-skip-permissions --mode auto \
    --settings "$AGYSET" "$@"
  }
if [ -n "${AGY_TOKEN_FILE:-}" ]; then
  # No job control: the child stays in the terminal's foreground process group. Explicit stdin keeps the TUI's
  # input (bash otherwise gives an asynchronous command /dev/null). wait lets signal traps run immediately.
  agy_run "$@" <&0 &
  AGY_PID=$!
  AGY_RC=0
  wait "$AGY_PID" || AGY_RC=$?
  exit "$AGY_RC"
fi
agy_run "$@"
