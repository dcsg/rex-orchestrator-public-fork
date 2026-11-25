#!/usr/bin/env bash
# Locate the installed CLI and forward arguments to Rex's Lua runner.
set -euo pipefail
unset CDPATH
SCRIPT_SRC=$0
while [ -L "$SCRIPT_SRC" ]; do
  SCRIPT_PARENT=$(cd "$(dirname "$SCRIPT_SRC")" && pwd -P)
  SCRIPT_LINK=$(readlink "$SCRIPT_SRC")
  case "$SCRIPT_LINK" in
    /*) SCRIPT_SRC=$SCRIPT_LINK ;;
    *) SCRIPT_SRC="$SCRIPT_PARENT/$SCRIPT_LINK" ;;
  esac
done
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_SRC")" && pwd -P)
case "${1:-help}" in
  status | ls | screen | wait | send | keys | close | claims | launch | clone) ;;
  *) exec "$BASH" "$SCRIPT_DIR/rex-orchestrator-bash.sh" "$@" ;;
esac
REX="${REX_ORCHESTRATOR_REX_BIN_DIR:+$REX_ORCHESTRATOR_REX_BIN_DIR/}rex"
if ! command -v "$REX" >/dev/null 2>&1; then
  for app in "/Applications/Rex Beta.app" "/Applications/Rex.app" "$HOME/Applications/Rex Beta.app" "$HOME/Applications/Rex.app"; do
    REX="$app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    [ -x "$REX" ] && break
    REX=""
  done
  if [ -z "$REX" ]; then
    if [ "$1" = clone ]; then exec "$BASH" "$SCRIPT_DIR/rex-orchestrator-bash.sh" "$@"; fi
    echo "rex-orchestrator: rex is not on PATH and no Rex app bundle was found; set REX_ORCHESTRATOR_REX_BIN_DIR" >&2
    exit 2
  fi
fi
# Rex's JSON decoder replaces invalid UTF-8. Transport argv as bytes so
# diagnostics and file arguments retain the same spelling as in Bash.
json_string() {
  local LC_ALL=C v="$1" bytes="$2" c i byte
  printf '"'
  for ((i=0; i<${#v}; i++)); do
    c=${v:i:1}
    case "$c" in
      '"' | "\\") printf '\\%s' "$c" ;;
      [[:cntrl:]]) printf '\\u%04x' "'$c" ;;
      [$'\200'-$'\377'])
        if [ "$bytes" = yes ]; then
          printf -v byte '%d' "'$c"
          printf '\\u00%02x' "$((byte & 255))"
        else
          printf '%s' "$c"
        fi ;;
      *) printf '%s' "$c" ;;
    esac
  done
  printf '"'
}
launch_dir=''
launch_pid=''
launch_reported=0
finish_launch() {
  trap '' HUP INT TERM
  if [ "$launch_reported" = 0 ] && [ -s "$launch_dir/state" ]; then
    local recovery
    recovery=$(printf '{"recover":true,"script_dir":'; json_string "$SCRIPT_DIR" no
      printf ',"journal":'; json_string "$launch_dir/state" no; printf '}')
    if ! REX_SESSION='' REX_BLOCK='' "$REX" --autostart=false "do" "$SCRIPT_DIR/lua/main.lua" --args - --fail-fast <<<"$recovery"; then
      printf 'rex-orchestrator: launch recovery is pending in %s\n' "$launch_dir/state" >&2
      return
    fi
  fi
  rm -rf -- "$launch_dir"
}
cancel_launch() {
  trap '' HUP INT TERM
  if [ -n "$launch_pid" ]; then
    kill -TERM "$launch_pid" 2>/dev/null || :
    wait "$launch_pid" 2>/dev/null || :
  fi
  exit "$1"
}
if [ "$1" = launch ]; then
  launch_dir=$(mktemp -d "${TMPDIR:-/tmp}/rex-orchestrator-launch.XXXXXX")
  trap finish_launch EXIT
  trap 'cancel_launch 129' HUP
  trap 'cancel_launch 130' INT
  trap 'cancel_launch 143' TERM
fi
args=$(printf '{"forward_errors":true,"script_dir":'; json_string "$SCRIPT_DIR" no
  printf ',"rex_bin":'; json_string "$REX" no
  printf ',"journal":'; json_string "$launch_dir/state" no
  printf ',"session":'; json_string "${REX_SESSION:-}" yes
  printf ',"block":'; json_string "${REX_BLOCK:-}" yes
  printf ',"argv":['
  sep=''; for arg in "$@"; do printf '%s' "$sep"; json_string "$arg" yes; sep=,; done; printf ']}')
run_lua() {
  local command=$1 diagnostics line rc=0 started=0 rejected=0
  local flags=(--fail-fast)
  # Keep wait alive long enough to handle destruction of its target's session itself.
  if [ "$command" = wait ]; then flags+=(--all); fi
  # Let Lua resolve explicit targets even when their session has no focused block.
  if [ "$command" = launch ]; then
    REX_SESSION='' REX_BLOCK='' "$REX" "do" "$SCRIPT_DIR/lua/main.lua" --args - "${flags[@]}" \
      5>&2 2>"$launch_dir/diagnostics" 4>&2 >&3 <<<"$args" &
    launch_pid=$!
    wait "$launch_pid" || rc=$?
    launch_pid=''
    diagnostics=$(<"$launch_dir/diagnostics")
  else
    local no_autostart=''
    if [ "$command" = clone ]; then no_autostart=--autostart=false; fi
    diagnostics=$(REX_SESSION='' REX_BLOCK='' "$REX" ${no_autostart:+"$no_autostart"} "do" "$SCRIPT_DIR/lua/main.lua" \
      --args - "${flags[@]}" 5>&2 2>&1 4>&2 >&3 <<<"$args") || rc=$?
  fi
  case "$diagnostics" in *$'\036rex-orchestrator:started'*) started=1 ;; esac
  case "$diagnostics" in *$'\036rex-orchestrator:rejected'*) rejected=1 ;; esac
  case "$diagnostics" in
    'Error: unknown flag: --all'* | 'Error: unknown flag: --fail-fast'* | 'Error: unknown flag: --args'* | \
    'Error: unknown flag: --autostart'* | 'Error: unknown command "do"'*)
      if [ "$command$started" = clone0 ]; then "$BASH" "$SCRIPT_DIR/rex-orchestrator-bash.sh" "$@" >&3; return $?; fi
      printf '%s\n' 'rex-orchestrator: this Rex CLI lacks rex do with --args, --all and --fail-fast; update Rex' >&2
      return 1 ;;
    'Error: REX_SERVER: no Rex server is running'* | 'Error: no Rex server is running'*)
      # Rex failed before executing Lua. Preserve startup diagnostics and offline dead-claim pruning.
      if [ "$started$rc" = 04 ]; then "$BASH" "$SCRIPT_DIR/rex-orchestrator-bash.sh" "$@" >&3; return $?; fi ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      '' | $'\036rex-orchestrator:started' | $'\036rex-orchestrator:rejected' | 'listening: '*'; Ctrl-C to stop') ;;
      *) printf '%s\n' "$line" >&2 ;;
    esac
  done <<<"$diagnostics"
  case "$command" in
    send | keys | close | launch | clone)
      if [ "$rc" = 4 ] && [ "$rejected" = 0 ]; then
        printf '%s\n' 'rex-orchestrator: rex did not answer' >&2
        return 1
      fi ;;
  esac
  return "$rc"
}
if [ "$1" = wait ]; then
  rc=0
  result=$(run_lua "$@" 3>&1) || rc=$?
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
  elif [ "$rc" = 0 ] || [ "$rc" = 4 ]; then
    printf '%s\n' 'rex-orchestrator: rex did not answer' >&2
    rc=1
  fi
  exit "$rc"
fi
if [ "$1" = launch ]; then
  rc=0
  run_lua "$@" 3>"$launch_dir/result" || rc=$?
  case "$rc" in
    0 | 3 | 12 | 124)
      if [ -s "$launch_dir/result" ]; then
        trap '' HUP INT TERM
        cat "$launch_dir/result" && launch_reported=1 || rc=1
      else
        printf '%s\n' 'rex-orchestrator: rex did not report launching a block' >&2
        rc=1
      fi ;;
  esac
  exit "$rc"
fi
run_lua "$@" 3>&1
