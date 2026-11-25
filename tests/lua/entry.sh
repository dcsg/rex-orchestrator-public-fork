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
[ "$1" = do ] && [ "$3" = --args ] && [ "$5" = --fail-fast ]
printf '%s' "$4"
REX
chmod +x "$T/bin/rex"
ln -s "$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh" "$T/install space/first"
ln -s first "$T/install space/chain"
pass=0
for bash in /bin/bash /opt/homebrew/bin/bash; do
  # shellcheck disable=SC2016 # Pass literal shell syntax through JSON without expanding it.
  [ ! -x "$bash" ] || for value in '' 'a"b\c' $'a\nb\tc\rd\001' '🦊 café' '$(touch SHOULD_NOT_EXIST) `id` $HOME'; do
    out=$(REX_ORCHESTRATOR_REX_BIN_DIR="$T/bin" "$bash" "$T/install space/chain" status "$value")
    printf '%s' "$out" | jq -e --arg value "$value" --arg scripts "$ROOT/skills/rex-orchestrator/scripts" \
      '.argv == ["status",$value] and .script_dir == $scripts' >/dev/null
    pass=$((pass+1))
  done
done
printf 'Lua entry: %d passed\n' "$pass"
