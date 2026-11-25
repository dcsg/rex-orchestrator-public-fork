#!/bin/bash
# Token-free program-status emitter. Only live.sh starts it, on its private server.
set -eu
work=$1
stty -echo
# shellcheck disable=SC1003 # OSC terminates with ESC followed by a literal backslash.
report() { printf '\033]7501;app=claude-code:state=%s%s\033\\' "$1" "${2:-}"; }
report working
printf '\033]0;%s\\\007' '<&>"'
while IFS= read -r line; do
  case "$line" in
    done | working | idle) report "$line" ;;
    blocked) report blocked ':kind=question:msg=QSBxdWVzdGlvbg==' ;;
    error) report error ':msg=Qm9vbQ==' ;;
    composer)
      printf '\033[2J\033[H────────────────────\n ❯ \n────────────────────\n ⏸ manual mode on\n\033[2;4H'
      stty echo
      report idle ;;
    bg)
      printf '\033[2J\033[H────────────────────\n ❯\n────────────────────\n  1 shell\n'
      report 'done' ;;
    agy-cut)
      printf '\033[2J\033[H────────────────────────────────────────────────────────────────────────────────\n %s/notes.txt  +1\n\n ❯ 1. Yes\n   2. No\n' "$work"
      msg=$(printf 'Approve WriteFile: Write: %s/not…' "$work" | /usr/bin/base64 | tr -d '\n')
      # shellcheck disable=SC1003 # End OSC with ESC and a literal backslash.
      printf '\033]7501;app=antigravity:state=blocked:kind=permission:msg=%s\033\\' "$msg" ;;
    permission | permission\ *)
      target=${line#permission}; target=${target# }; target=${target:-new.txt}
      printf '\033[2J\033[H────────────────────────────────────────────────────────────────────────────────\n Create file\n %s\n Do you want to create %s?\n ❯ 1. Yes\n   2. Yes, always allow\n   3. No\n' "$target" "${target##*/}"
      msg=$(printf 'approve Write: %s/%s' "$work" "$target" | /usr/bin/base64 | tr -d '\n')
      report blocked ":kind=permission:msg=$msg" ;;
    '') printf 'enter\n' >> "$work/presses"
        [ ! -e "$work/mode-change" ] || printf '────────────────────────────────────────────────────────────────────────────────\n ⏵⏵ accept edits on\n'
        report 'done' ;;
    exit) exit 0 ;;
    *) printf '%s\n' "$line" >> "$work/prompts"
       stty -echo
       report 'done' ;;
  esac
done
