#!/bin/bash -p
# Entry-point serialization tests; fake rex never connects to any server.
set -euo pipefail
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
T=$(mktemp -d /tmp/rex-lua-entry.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/install space"
cat > "$T/bin/rex" <<'REX'
#!/bin/bash
set -eu
case "${REX_TEST_NO_WAIT_RESULT:-}" in
  yes) exit 0 ;;
  old) printf 'Error: unknown flag: --all\n' >&2; exit 2 ;;
  lost) printf '\036rex-orchestrator:started\n' >&4; printf 'Error: no Rex server is running at fixture\n' >&2; exit 4 ;;
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
bashes=(/bin/bash /opt/homebrew/bin/bash)
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
