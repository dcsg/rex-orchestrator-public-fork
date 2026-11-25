# shellcheck shell=bash
# The re-entry marker is a shell variable, so an exported caller value cannot bypass isolation.
# shellcheck disable=SC2154
if [ "$(declare -p rex_test_isolated 2>/dev/null || :)" != 'declare -- rex_test_isolated="1"' ]; then
  keep=("HOME=${HOME:-~}")
  while IFS= read -r name; do
    case "$name" in
      # TMPDIR: a caged worker can write only its task folder and its cage home, where its TMPDIR points.
      # REX_TEST_* includes REX_TEST_REX, the Rex CLI for a HOME that has none (grok's and agy's cage home).
      USER | TERM | TMPDIR | REX_TEST_* | REX_LUA_*) keep+=("$name=${!name}") ;;
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

# test_tmpdir NAME: make a private folder for one run and print its physical path. It goes under TMPDIR, so a suite
# runs inside the cage (whose TMPDIR is in the cage home, about the only place a caged worker can write), unless TMPDIR
# is unset, unusable or so deep that a socket in the folder would pass macOS's 104-byte limit: then under /tmp. The
# budget, 103 bytes: a physical TMPDIR of at most 80, "/NAME.XXXXXX" with NAME of at most 4 (11) and "/keys.sock" (10).
# Inside a cage /tmp is not writable, so there an over-long TMPDIR fails here instead of later.
test_tmpdir() {
  local root=${TMPDIR:-} dir
  root=${root%/}
  if [ -z "$root" ] || ! root=$(cd "$root" 2>/dev/null && pwd -P) || [ ! -w "$root" ] || [ ${#root} -gt 80 ]; then
    root=/tmp
  fi
  dir=$(mktemp -d "$root/$1.XXXXXX") || return
  (cd "$dir" && pwd -P)
}

# test_nested_sandbox: true when this process already runs in a macOS sandbox (a cage, say), where sandbox-exec can't
# apply another profile: macOS doesn't nest them. Only that exact refusal counts, so a broken sandbox-exec still fails.
test_nested_sandbox() {
  local err
  err=$(/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>&1) && return 1
  case "$err" in *'sandbox_apply: Operation not permitted'*) return 0 ;; esac
  return 1
}

# test_skip_nested WHAT: report WHAT as skipped because it starts a sandbox inside this one. Not an environment gap that
# REX_TEST_REQUIRE_ENV turns into a failure: no setup lets a sandboxed process start another sandbox.
test_skip_nested() { printf 'SKIP  %s: already inside a sandbox, which macOS does not nest\n' "$*"; }

test_has_pty() {
  /usr/bin/script -q /dev/null /bin/sh -c '[ -t 0 ] && [ -t 1 ] && printf "PTY OK\n"' \
    </dev/null 2>/dev/null | /usr/bin/grep -q 'PTY OK'
}

test_find_bash5() {
  local exe
  # shellcheck disable=SC2016 # Inspect the version in the candidate shell.
  for exe in "${REX_TEST_BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$exe" ] && "$exe" -p -c '[ "${BASH_VERSINFO[0]}" -ge 5 ]'; then
      printf '%s\n' "$exe"
      return
    fi
  done
  return 1
}

test_skip() {
  if [ "${REX_TEST_REQUIRE_ENV:-0}" = 1 ]; then
    printf 'FAIL  required test environment: %s\n' "$*" >&2
    exit 1
  fi
  printf 'SKIP  %s\n' "$*"
}
