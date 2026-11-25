#!/bin/bash -p
# Reports program status from a private Rex server without running an agent.
set -eu
# claude-token: check the caged environment before isolation below replaces it (isolation runs this file again, then
# with rex_test_isolated set). Only the verdict goes on.
if [ "${2:-}" = claude-token ] && [ "${rex_test_isolated:-}" != 1 ]; then
  REX_TEST_CLAUDE_TOKEN=wrong
  [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" != "sk-ant-oat01-$(printf 'Stand_in-%.0s' 1 2 3 4 5 6)" ] || REX_TEST_CLAUDE_TOKEN=fixture
  [ -z "${CLAUDE_CMD_FILE:-}${CLAUDE_CMD_NAME:-}${REX_ORCHESTRATOR_CAGE_CLAUDE_TOKEN_CMD:-}" ] || REX_TEST_CLAUDE_TOKEN=leaked
  export REX_TEST_CLAUDE_TOKEN
fi
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh"
app=$1 mode=$2
root=$(cd "$3" && pwd -P)
shift 3
work=$(pwd -P)
case "$work" in "$root"/launch-work/*) ;; *) exit 90 ;; esac
stty -echo
# shellcheck disable=SC1003 # OSC ends with ESC and a backslash.
report() { printf '\033]7501;app=%s:state=%s\033\\' "$app" "$1"; }
ready() {
  printf '\033[2J\033[H'
  if [ "$app" = codex ]; then
    printf ' ? for shortcuts\n'
    report working
  else
    printf ' ❯ \n ⏸ manual mode on\n'
    report idle
  fi
}
case "$mode" in
  ready) ready ;;
  scoped)
    [ "$1" = --settings ]
    printf '%s\n' "$2" > scoped-rules
    ready ;;
  claude-token)
    # A caged claude whose token came from REX_ORCHESTRATOR_CAGE_CLAUDE_TOKEN_CMD: it had exactly the fixture token,
    # and nothing of the lookup (checked above). Only "ok" is written, never the token.
    [ "${REX_TEST_CLAUDE_TOKEN:-}" = fixture ] || { echo "stand-in: token check ${REX_TEST_CLAUDE_TOKEN:-unset}"; exit 92; }
    [ "${1:-}" = --dangerously-skip-permissions ] || { echo "stand-in: unexpected arguments"; exit 94; }
    printf 'ok\n' > token-ok
    ready ;;
  agy-fixture)
    case "$HOME" in "$root"/orchestrator-state/cage/agy.*/home) ;; *) exit 91 ;; esac
    token="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
    [ "$(stat -f '%Lp' "$token")" = 600 ]
    jq -e '.refresh_token == "stand-in-only"' "$token" >/dev/null
    [ "$4" = --settings ]
    printf '%s\n' "$5" > agy-settings
    ready ;;
  trust | trust-wrong | trust-no)
    path=$(pwd -P)
    [ "$mode" != trust-wrong ] || path="$path-neighbor"
    report blocked
    if [ "$mode" = trust-no ]; then
      printf 'Accessing workspace\n%s\n   Yes, I trust this folder\n ❯ No, exit\n' "$path"
      IFS= read -r -n 3 key
      printf '%s' "$key" > arrow
    fi
    printf '\033[2J\033[HAccessing workspace\n%s\n ❯ Yes, I trust this folder\n   No, exit\n' "$path"
    IFS= read -r key
    [ -n "$key" ] || printf 'enter\n' >> presses
    if [ "$app" = claude-code ] && [ "$mode" = trust ] && [ -f ancestor-fixture ]; then
      parent=$(cd .. && pwd -P)
      [ -d "$work/fixture-config" ]
      printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$parent" > "$work/fixture-config/.claude.json"
    fi
    ready ;;
  hooks) printf 'Hooks need review\n Trust all and continue\n Continue without trusting\n'; report blocked ;;
  bypass) printf ' ❯ \n ⏵⏵ bypass permissions on\n'; report idle ;;
  exits) printf 'stand-in exited\n'; exit 8 ;;
  never) report working ;;
  steer)
    # A child the orphan tests drive: a state name typed into it becomes its status, any other line is a prompt.
    ready
    while IFS= read -r line; do
      case "$line" in
        working | done | idle | error) report "$line" ;;
        *) printf '%s\n' "$line" >> prompts; report 'done' ;;
      esac
    done
    exit 0 ;;
  *) exit 9 ;;
esac
while IFS= read -r key; do printf '%s\n' "$key" >> presses; done
