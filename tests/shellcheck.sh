#!/bin/bash
# Check every tracked shell script (each *.sh file and each tracked file whose first line is a sh or bash shebang):
# it must parse under macOS's Bash 3.2 (/bin/bash -n), which the scripts and CI run, and under Bash 5, and pass
# ShellCheck following sourced files (-x). ShellCheck alone misses Bash 3.2 parser limits, such as a case pattern
# without its leading '(' inside $(...). CI runs this same script. Source directives are relative to the repository
# root, so it runs from there. Bash 5 comes from REX_TEST_BASH, Homebrew or /usr/local; without it the script fails.
set -euo pipefail
cd "$(dirname "$0")/.."
files=()
while IFS= read -r -d '' file; do
  case "$file" in
    *.sh) files+=("$file") ;;
    *) if head -n 1 -- "$file" 2>/dev/null | grep -qE '^#! *(/usr/bin/env +)?(/[^ ]*/)?(ba)?sh( |$)'; then files+=("$file"); fi ;;
  esac
done < <(git ls-files -z)
[ "${#files[@]}" -gt 0 ] || { echo 'shellcheck.sh: no shell scripts found' >&2; exit 2; }
bash5=''
# shellcheck disable=SC2016 # The candidate shell expands it.
for candidate in "${REX_TEST_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [ -x "$candidate" ] && "$candidate" -c '[ "${BASH_VERSINFO[0]}" -ge 5 ]' 2>/dev/null; then bash5=$candidate; break; fi
done
[ -n "$bash5" ] || { echo 'shellcheck.sh: Bash 5 not found (set REX_TEST_BASH or install bash)' >&2; exit 2; }
bad=0
for file in "${files[@]}"; do
  for shell in /bin/bash "$bash5"; do
    "$shell" -n "$file" || { printf 'shellcheck.sh: %s does not parse under %s\n' "$file" "$shell" >&2; bad=1; }
  done
done
[ "$bad" = 0 ] || exit 1
# shellcheck disable=SC2016 # Bash 5 expands it.
printf 'bash -n (3.2 and %s): %s files\n' "$("$bash5" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"')" "${#files[@]}"
printf 'shellcheck -x: %s files\n' "${#files[@]}"
shellcheck -x "${files[@]}"
