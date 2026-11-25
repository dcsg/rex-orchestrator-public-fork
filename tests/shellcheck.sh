#!/bin/bash
# Run ShellCheck, following sourced files (-x), over every tracked shell script: each *.sh file and each tracked file
# whose first line is a sh or bash shebang. CI runs this same script. Source directives are relative to the repository
# root, so it runs from there.
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
printf 'shellcheck -x: %s files\n' "${#files[@]}"
shellcheck -x "${files[@]}"
