# shellcheck shell=bash
# The zero-token suites build with the production Lua module and run the emitted wrappers directly.
cage_build() {
  local built
  built=$(REX_ORCHESTRATOR_CAGE_PROFILE="$CAGE_PROFILE" REX_ORCHESTRATOR_CAGE_TPL="$CAGE_TPL" \
    REX_ORCHESTRATOR_CAGE_SECRETS="$CAGE_SECRETS" REX_ORCHESTRATOR_CAGE_AGY_HOME="$CAGE_AGY_HOME" \
    luajit "$(dirname "${BASH_SOURCE[0]}")/build.lua" "$ASSETS" "$SCRIPT_DIR" "$STATE_DIR" \
    "$1" "$2" "$3" "${account:-}" "${guard_leaf:-}" "${cage_agent:-}") || return $?
  # shellcheck disable=SC2034 # Consumed by the calling suite.
  cage_tmp=$built cage_wrapper="$built/bin/$1"
}
note() { printf 'rex-orchestrator: %s\n' "$*" >&2; }
sq() { local q="'" e="'\\''"; printf "'%s'" "${1//$q/$e}"; }
