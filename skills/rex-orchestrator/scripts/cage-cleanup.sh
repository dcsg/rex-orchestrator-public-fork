#!/bin/bash

# Delete a throwaway cage home (cleanup_cage DIR). A child or a tool it ran (Go's module cache is read-only) can leave
# what rm -rf can't remove: folders without the owner's rwx, the uchg or uappnd flag, an ACL that denies the owner.
# Clear them, nested ones too (find fixes each folder before it reads it); chflags, chmod, find and rm follow no link
# inside, and the cage can't link a file from outside in. The agent may still be writing as it exits: retry once.
cleanup_cage() {
  local n=0
  # A launch that never reached its wrapper can still have a private agy command waiting outside CAGE_ROOT.
  case "${1##*/}" in agy.* | agy-*.*)
    if [ -d "${1%/*}-commands" ] && [ ! -L "${1%/*}-commands" ] && [ -O "${1%/*}-commands" ]; then
      rm -f "${1%/*}-commands/${1##*/}"
    fi ;;
  esac
  # Restore access to sealed transcript directories before reading them.
  { chflags -R nouchg,nouappnd "$1"; chmod -R -N "$1"; chmod -R u+rwX "$1"; } 2>/dev/null || true
  # Measurement never prevents cleanup, including when Lua or storage fails.
  local harvest_status=0
  /bin/bash -p "${SCRIPT_DIR:-${SDIR:-.}}/local-lua.sh" harvest "$1" "${STATE_DIR:-${1%/cage/*}}" || harvest_status=$?
  case "$harvest_status" in
    0) ;;
    69) note "continuing cage removal without a transcript archive" ;;
    *) note "harvest failed for $1; continuing removal; storage failure may prevent a manifest" ;;
  esac
  until { chflags -R nouchg,nouappnd "$1"; chmod -R -N "$1"; chmod -R u+rwX "$1"; rm -rf "$1"; } 2>/dev/null; do
    [ $((n += 1)) -lt 2 ] || { rm -rf "$1"; return; }
    find "$1" -type d -exec chflags nouchg,nouappnd {} \; -exec chmod -N {} \; -exec chmod u+rwx {} \; 2>/dev/null
    sleep 1
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  unset CDPATH
  [ "$#" -eq 2 ] || exit 2
  STATE_DIR=$1
  SCRIPT_DIR=${BASH_SOURCE[0]%/*}
  base=$(cd "$STATE_DIR/cage" && pwd -P) || exit 1
  case "$2" in "$base/"*) leaf=${2#"$base"/} ;; *) exit 2 ;; esac
  case "$leaf" in ''|*/*|.*) exit 2 ;; esac
  note() { printf 'rex-orchestrator: %s\n' "$*" >&2; }
  cleanup_cage "$2" || exit 1
fi
