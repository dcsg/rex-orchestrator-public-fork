#!/bin/bash -p
# Reports program status from a private Rex server without running an agent.
set -eu
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
