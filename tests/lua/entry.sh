#!/bin/bash -p
# Entry-point serialization tests; fake rex never connects to any server.
set -euo pipefail
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
T=$(mktemp -d /tmp/rex-lua-entry.XXXXXX)
trap 'rm -rf "$T"' EXIT
export REX_ORCHESTRATOR_STATE_DIR="$T/state"
mkdir -p "$T/bin" "$T/install space"
cat > "$T/bin/rex" <<'REX'
#!/bin/bash
set -eu
[ "$REX_ORCHESTRATOR_STATE_DIR" = "${0%/bin/rex}/state" ]
case "${REX_TEST_NO_WAIT_RESULT:-}" in
  yes) exit 0 ;;
  old) printf 'Error: unknown flag: --all\n' >&2; exit 2 ;;
  lost) printf '\036rex-orchestrator:started\n' >&4; printf 'Error: no Rex server is running at fixture\n' >&2; exit 4 ;;
  controls) printf '\036rex-orchestrator:started\n' >&4
    printf 'Error: bad \033]0;x\007 \302\233 \342\200\256 \377 \205 a\\b\n' >&2; exit 1 ;;
  rejected)
    printf '\036rex-orchestrator:started\n\036rex-orchestrator:rejected\n' >&4
    exit 4 ;;
esac
[ "$1" = do ] && [ "$3" = --args ] && [ "$4" = - ] && [ "$5" = --fail-fast ]
cat
REX
chmod +x "$T/bin/rex"
ln -s "$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh" "$T/install space/first"
ln -s first "$T/install space/chain"
pass=0
# Bash 5 can crash while restoring function-local or temporary locales in a forked substitution.
# Scan the production shell sources, allowing an explicit export inside a substitution.
# shellcheck disable=SC2016 # An awk program, not shell text.
locale_scan='
  FNR == 1 { pending = 0 }
  /^[[:space:]]*(#|$)/ { next }
  {
    locale = "(LC_[[:alnum:]_]+|LANG)"
    assignment = "[[:space:]]*" locale "=[^;)]*[[:space:]]+[^[:space:]);]"
    substitution = "\\$\\(([^)]*[;&|])?"
    if ($0 ~ ("(^|[[:space:];&(])local[[:space:]]+([^;&|]*[[:space:]])?" locale "([[:space:]=;)]|$)") ||
        $0 ~ (substitution assignment) || (pending && $0 ~ ("^" assignment))) {
      print FILENAME ":" FNR ": " $0
      bad = 1
    }
    pending = ($0 ~ /\$\([[:space:]\\]*$/)
  }
  END { exit bad }
'
# The scanner must flag each unsafe form and accept the safe ones, or a broken pattern would pass everything.
# shellcheck disable=SC2016 # Fixture shell text is scanned, never run.
printf '%s\n' 'f() { local LC_ALL=C x; }' 'g() { local x LANG=C; }' 'h() { local LC_CTYPE; }' \
  'y=$(LC_ALL=C sort file)' 'z=$(cd /; LANG=C ls)' 'w=$(' '  LC_ALL=C printf x)' >"$T/locale-unsafe.sh"
# shellcheck disable=SC2016
printf '%s\n' '# local LC_ALL=C' 'x=$(export LC_ALL=C; sort)' 'LC_ALL=C sort file' \
  'v=$(printf "%s" "$LANG")' 'local_value=1' >"$T/locale-safe.sh"
flagged=$(awk "$locale_scan" "$T/locale-unsafe.sh" | wc -l | tr -d ' ') || :
[ "$flagged" = 6 ] || { printf 'Locale scanner flagged %s of 6 unsafe fixture lines\n' "$flagged" >&2; exit 1; }
awk "$locale_scan" "$T/locale-safe.sh" >&2 || { printf 'Locale scanner rejected a safe fixture\n' >&2; exit 1; }
pass=$((pass+1))
find "$ROOT/install.sh" "$ROOT/skills/rex-orchestrator/scripts" -type f -name '*.sh' -exec awk "$locale_scan" {} + ||
  { printf 'Unsafe shell locale assignment\n' >&2; exit 1; }
pass=$((pass+1))
bashes=(/bin/bash)
if bash5=$(test_find_bash5); then bashes+=("$bash5"); else test_skip 'Lua entry checks require Bash 5'; fi
[ -z "${REX_TEST_BASH:-}" ] || bashes=("$REX_TEST_BASH")
for bash in "${bashes[@]}"; do
  # shellcheck disable=SC2016 # Pass literal shell syntax through JSON without expanding it.
  [ ! -x "$bash" ] || for value in '' 'a"b\c' $'a\nb\tc\rd\001' '🦊 café' $'\377' '$(touch SHOULD_NOT_EXIST) `id` $HOME'; do
    out=$(REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" "$bash" "$T/install space/chain" status "$value") || {
      rc=$?
      printf 'Lua entry serialization case %s failed under %s with status %s\n' "$((pass+1))" "$bash" "$rc" >&2
      exit "$rc"
    }
    bytes=$(printf '%s' "$value" | od -An -v -tu1 | jq -Rs '[splits("[[:space:]]+") | select(length>0) | tonumber]')
    printf '%s' "$out" | jq -e --argjson bytes "$bytes" --arg scripts "$ROOT/skills/rex-orchestrator/scripts" \
      '.argv[0] == "status" and (.argv[1] | explode) == $bytes and .script_dir == $scripts' >/dev/null
    pass=$((pass+1))
  done
done
# The shell's escaping (term-text.sh) prints every byte sequence exactly as core.lua's M.terminal_text does, under
# Bash 3.2 and 5: C0, DEL, raw C1, UTF-8 C1, bidi overrides and isolates, invalid and truncated UTF-8, backslashes.
command -v luajit >/dev/null 2>&1 || test_skip 'shell and Lua escaping parity requires LuaJIT'
printf 'local M=dofile(arg[1]); io.write(M.terminal_text(arg[2]))\n' > "$T/terminal_text.lua"
# shellcheck disable=SC1003 # Octal escapes and backslashes for printf, not shell quoting.
parity_inputs=('plain' 'a\\b\\' '\033]0;x\007\033[31m' '\t\r\001\037' '\177' '\200' '\205' '\233[2J' '\237' '\302\200'
  '\302\205' '\302\233' '\302\237' '\302\240' '\342\200\252' '\342\200\256' '\342\201\246' '\342\201\251'
  '\342\200\251' '\342\200\257' '\342\201\245' '\342\201\252' '\342\200\246' 'caf\303\251' '\360\237\246\212'
  '\300\200' '\301\277' '\340\237\200' '\355\240\200' '\364\220\200\200' '\365\200\200\200' '\370'
  '\342\200' '\302' '\277' '\377\376' '\303\050' 'x\342\200\256y\\z\033\302\205\377'
  "it's \"q\" \\033 literal")
for bash in "${bashes[@]}"; do
  [ -x "$bash" ] || continue
  for spec in "${parity_inputs[@]}"; do
    # shellcheck disable=SC2059 # Each input is a printf format of octal escapes.
    input=$(printf "$spec.") && input=${input%.}
    want=$(luajit "$T/terminal_text.lua" "$ROOT/skills/rex-orchestrator/scripts/lua/core.lua" "$input")
    # shellcheck disable=SC2016 # The child shell expands its own arguments.
    got=$("$bash" -p -c '. "$1"; rex_term_text "$2"' sh "$ROOT/skills/rex-orchestrator/scripts/term-text.sh" "$input")
    [ "$got" = "$want" ] || { printf 'escaping parity under %s for %s: shell [%s], Lua [%s]\n' "$bash" "$spec" "$got" "$want" >&2; exit 1; }
    # keep mode differs only in leaving backslashes single, for text Lua already escaped.
    # shellcheck disable=SC2016 # The child shell expands its own arguments.
    kept=$("$bash" -p -c '. "$1"; rex_term_text "$2" keep' sh "$ROOT/skills/rex-orchestrator/scripts/term-text.sh" "$input")
    [ "$kept" = "${want//\\\\/\\}" ] || { printf 'keep mode under %s for %s: [%s]\n' "$bash" "$spec" "$kept" >&2; exit 1; }
    [ "$(printf '%s' "$got$kept" | LC_ALL=C tr -d '\040-\176\200-\377' | wc -c | tr -d ' ')" = 0 ] ||
      { printf 'escaping left a C0 control or DEL for %s\n' "$spec" >&2; exit 1; }
    pass=$((pass+1))
  done
done
# Rex's own error lines reach the terminal through the shell alone: escaped the same way, backslashes kept.
rc=0
REX_TEST_NO_WAIT_RESULT=controls REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" \
  "${REX_TEST_BASH:-/bin/bash}" "$T/install space/chain" status block:fixture > "$T/out" 2> "$T/err" || rc=$?
if [ "$rc" -ne 1 ] || ! grep -qxF 'Error: bad \x1B]0;x\x07 \u009B \u202E \xFF \x85 a\b' "$T/err"; then
  cat -v "$T/err" >&2; exit 1
fi
[ "$(LC_ALL=C tr -d '\040-\176\n' < "$T/err" | wc -c | tr -d ' ')" = 0 ] || { echo 'raw bytes in forwarded Rex errors' >&2; exit 1; }
pass=$((pass+1))
for scenario in yes old; do
  rc=0
  REX_TEST_NO_WAIT_RESULT="$scenario" REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" \
    "${REX_TEST_BASH:-/bin/bash}" "$T/install space/chain" wait block:fixture > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" -eq 1 ] && [ ! -s "$T/out" ] || exit 1
  if [ "$scenario" = yes ]; then grep -qx 'rex-orchestrator: rex did not answer' "$T/err"
  else grep -qx 'rex-orchestrator: this Rex CLI lacks rex do with --args, --all and --fail-fast; update Rex' "$T/err"; fi
  pass=$((pass+1))
done
for scenario in lost rejected; do
  for verb in send keys close; do
    rc=0
    REX_TEST_NO_WAIT_RESULT="$scenario" REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" \
      "${REX_TEST_BASH:-/bin/bash}" "$T/install space/chain" "$verb" block:fixture > "$T/out" 2> "$T/err" || rc=$?
    if [ "$scenario" = lost ]; then
      [ "$rc" -eq 1 ] && grep -qx 'rex-orchestrator: rex did not answer' "$T/err"
    else
      [ "$rc" -eq 4 ] && [ ! -s "$T/err" ]
    fi
    pass=$((pass+1))
  done
done
printf '#!/bin/bash -p\nset -eu\n. %q\n' "$ROOT/tests/isolate.inc.sh" > "$T/environment"
cat >> "$T/environment" <<'CHECK'
if [ "${1:-}" = skip ]; then test_skip 'fixture unavailable'; exit 0; fi
[ -z "${UNEXPECTED_TEST_CALLER_VALUE+x}${BASH_ENV+x}${REX_ORCHESTRATOR_STATE_DIR+x}" ]
[ "$REX_TEST_SAMPLE:$REX_LUA_SAMPLE:$TERM:$USER" = 'keep:keep:dumb:fixture' ]
[ "$(test_find_rex || :)" != "$REX_TEST_FAKE_REX" ]
CHECK
printf ': > %q\n' "$T/startup-ran" > "$T/startup"
chmod +x "$T/environment"
# The caller's PATH contains the fake Rex used above. Discovery must ignore it.
rex_test_isolated=1 UNEXPECTED_TEST_CALLER_VALUE=set BASH_ENV="$T/startup" REX_ORCHESTRATOR_STATE_DIR=bad \
  PATH="$T/bin:$PATH" REX_TEST_REX='' REX_TEST_FAKE_REX="$T/bin/rex" REX_TEST_SAMPLE=keep REX_LUA_SAMPLE=keep \
  TERM=dumb USER=fixture "$T/environment"
[ ! -e "$T/startup-ran" ]
pass=$((pass+1))
REX_TEST_REQUIRE_ENV=0 "$T/environment" skip > "$T/skip.out"
grep -Fxq 'SKIP  fixture unavailable' "$T/skip.out"
pass=$((pass+1))
rc=0
REX_TEST_REQUIRE_ENV=1 "$T/environment" skip > "$T/skip.out" 2> "$T/skip.err" || rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$T/skip.out" ] && grep -Fxq 'FAIL  required test environment: fixture unavailable' "$T/skip.err"
pass=$((pass+1))
printf 'Lua entry: %d passed\n' "$pass"
