#!/bin/bash
# Entry-point serialization tests; fake rex never connects to any server.
set -euo pipefail
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
esac
[ "$1" = do ] && [ "$3" = --args ] && [ "$4" = - ] && [ "$5" = --fail-fast ]
cat
REX
chmod +x "$T/bin/rex"
ln -s "$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh" "$T/install space/first"
ln -s first "$T/install space/chain"
pass=0
for bash in /bin/bash /opt/homebrew/bin/bash; do
  # shellcheck disable=SC2016 # Pass literal shell syntax through JSON without expanding it.
  [ ! -x "$bash" ] || for value in '' 'a"b\c' $'a\nb\tc\rd\001' '🦊 café' $'\377' '$(touch SHOULD_NOT_EXIST) `id` $HOME'; do
    out=$(REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" "$bash" "$T/install space/chain" status "$value")
    bytes=$(printf '%s' "$value" | od -An -v -tu1 | jq -Rs '[splits("[[:space:]]+") | select(length>0) | tonumber]')
    printf '%s' "$out" | jq -e --argjson bytes "$bytes" --arg scripts "$ROOT/skills/rex-orchestrator/scripts" \
      '.argv[0] == "status" and (.argv[1] | explode) == $bytes and .script_dir == $scripts' >/dev/null
    pass=$((pass+1))
  done
done
for scenario in yes old; do
  rc=0
  REX_TEST_NO_WAIT_RESULT="$scenario" REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" \
    /bin/bash "$T/install space/chain" wait block:fixture > "$T/out" 2> "$T/err" || rc=$?
  [ "$rc" -eq 1 ] && [ ! -s "$T/out" ] || exit 1
  if [ "$scenario" = yes ]; then grep -qx 'rex-orchestrator: rex did not answer' "$T/err"
  else grep -qx 'rex-orchestrator: this Rex CLI lacks rex do with --args, --all and --fail-fast; update Rex' "$T/err"; fi
  pass=$((pass+1))
done
printf 'Lua entry: %d passed\n' "$pass"
