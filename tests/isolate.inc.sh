# shellcheck shell=bash
# The re-entry marker is a shell variable, so an exported caller value cannot bypass isolation.
# shellcheck disable=SC2154
if [ "$(declare -p rex_test_isolated 2>/dev/null || :)" != 'declare -- rex_test_isolated="1"' ]; then
  keep=("HOME=${HOME:-~}")
  while IFS= read -r name; do
    case "$name" in
      USER | TERM | REX_TEST_* | REX_LUA_*) keep+=("$name=${!name}") ;;
    esac
  done < <(compgen -e)
  # shellcheck disable=SC2016 # The clean child sets its own marker before sourcing the entry point.
  exec /usr/bin/env -i "${keep[@]}" "$BASH" -p -c 'rex_test_isolated=1; . "$0"' "$0" "$@"
fi
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

test_find_rex() {
  local app exe home=${HOME:-~}
  if [ -n "${REX_TEST_REX:-}" ]; then
    case "$REX_TEST_REX" in /*) ;; *) return 1 ;; esac
    [ -x "$REX_TEST_REX" ] || return 1
    printf '%s\n' "$REX_TEST_REX"
    return
  fi
  exe="$home/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if [ -x "$exe" ]; then printf '%s\n' "$exe"; return; fi
  for app in '/Applications/Rex Beta.app' '/Applications/Rex.app' \
    "$home/Applications/Rex Beta.app" "$home/Applications/Rex.app"; do
    exe="$app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    if [ -x "$exe" ]; then printf '%s\n' "$exe"; return; fi
  done
  return 1
}

test_has_pty() {
  /usr/bin/script -q /dev/null /bin/sh -c '[ -t 0 ] && [ -t 1 ] && printf "PTY OK\n"' \
    </dev/null 2>/dev/null | /usr/bin/grep -q 'PTY OK'
}

test_skip() {
  if [ "${REX_TEST_REQUIRE_ENV:-0}" = 1 ]; then
    printf 'FAIL  required test environment: %s\n' "$*" >&2
    exit 1
  fi
  printf 'SKIP  %s\n' "$*"
}
