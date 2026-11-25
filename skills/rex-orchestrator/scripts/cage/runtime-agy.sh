# shellcheck shell=bash disable=SC2064
unset REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD AGY_TOKEN_CMD
AGY_PID='' AGY_TOKEN_FILE='' AGY_GROUP=0 AGY_PENDING=''
if [ -n "$AGY_CMD_FILE" ]; then
  AGY_TOKEN_FILE="$CT/home/.gemini/antigravity-cli/antigravity-oauth-token"
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
    # The child can replace its writable parents with links. Pin the physical directory as cwd before unlinking,
    # and refuse one outside CT: cleanup runs unsandboxed and must never delete a real-home credential.
    (cd -P -- "${AGY_TOKEN_FILE%/*}" 2>/dev/null || exit 0
      case "$PWD/" in "$CT/"*) /bin/rm -f ./antigravity-oauth-token ;; esac)
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
mkdir -p "$CT/home"
# A one-time provisioned agy login (CAGE_AGY_HOME) is copied in so it is writable in the cage.
[ -n "$RH_AGY" ] && [ -d "$RH_AGY" ] || exit 70
[ -d "$CT/home/.gemini" ] || cp -R "$RH_AGY/." "$CT/home/"
if [ -n "$AGY_CMD_FILE" ]; then
  # Suppress command diagnostics too: a failed shell command can quote its input or the credential in stderr.
  # Only the noninteractive lookup gets its own process group, so cancellation reaches provider subprocesses too.
  # Disable job control again before agy starts: its TUI must stay in the terminal's foreground group.
  { set -m; AGY_GROUP=1
    (umask 077
      mkdir -p "${AGY_TOKEN_FILE%/*}" && /bin/rm -f "$AGY_TOKEN_FILE" && cd / &&
        exec /usr/bin/env -i HOME="$RH" PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
          SHELL=/bin/bash LANG=en_US.UTF-8 /bin/bash --noprofile --norc "$AGY_CMD_FILE" >"$AGY_TOKEN_FILE"
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
  AGY_JQ=/opt/homebrew/bin/jq; [ -x "$AGY_JQ" ] || AGY_JQ=/usr/bin/jq
  if [ "$AGY_TOKEN_RC" -ne 0 ] || ! "$AGY_JQ" -e -s \
    'def nonempty_string: if type == "string" then length > 0 else false end;
     length == 1 and (.[0] | if type == "object" then
       ((.token | if type == "object" then .refresh_token else null end) | nonempty_string)
       or (.refresh_token | nonempty_string)
     else false end)' \
    "$AGY_TOKEN_FILE" >/dev/null 2>&1 || ! chmod 600 "$AGY_TOKEN_FILE"; then
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
