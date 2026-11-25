#!/bin/bash -p
# Stands in for an orchestrator agent in an interactive shell pane: reports program status until it reads "quit".
set -eu
stty -echo
# shellcheck disable=SC1003 # OSC ends with ESC and a backslash.
printf '\033]7501;app=claude-code:state=idle\033\\'
while IFS= read -r line; do [ "$line" != quit ] || exit 0; done
