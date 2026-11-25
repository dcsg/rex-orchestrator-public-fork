# shellcheck shell=bash
# Entry scripts use privileged Bash to skip startup hooks and exported functions.
case $- in *p*) ;; *) exec "$BASH" -p "$0" "$@" ;; esac

test_rex_on_path=$(type -P rex || :)
while IFS= read -r name; do
  case "$name" in
    BASH_ENV | ENV | CDPATH | TMPDIR | SSH_AUTH_SOCK | MISE* | DIRENV* | FNOX* | \
    CLAUDE* | CODEX* | ANTHROPIC* | OPENAI* | GROK* | AGY* | GEMINI* | GOOGLE* | \
    BASH_FUNC_* | ZDOTDIR | PROMPT_COMMAND | LUAINIT* | LUA_* | GIT_* | XDG_* | \
    PERL5* | PERLLIB | PYTHON* | RUBYOPT | RUBYLIB | NODE_OPTIONS | NODE_PATH)
      unset -v "$name" ;;
    REX_TEST_REX | REX_LUA_BASELINE | REX_LUA_BENCHMARK) ;; # Explicit test inputs.
    REX_*) unset -v "$name" ;;
  esac
done < <(compgen -A variable)
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

test_find_rex() {
  local app exe home=${HOME:-~}
  if [ -n "${REX_TEST_REX:-}" ]; then
    [ -x "$REX_TEST_REX" ] || return 1
    printf '%s\n' "$REX_TEST_REX"
    return
  fi
  exe=$(type -P rex || :)
  for exe in "$exe" "$test_rex_on_path" \
    "$home/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"; do
    case "$exe" in /*) if [ -x "$exe" ]; then printf '%s\n' "$exe"; return; fi ;; esac
  done
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

test_skip() { printf 'SKIP  %s\n' "$*"; }
