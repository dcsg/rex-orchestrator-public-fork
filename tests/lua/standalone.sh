#!/bin/bash -p
# Exercise local commands without a Rex server, jq or Python.
set -euo pipefail
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh"
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
scripts="$ROOT/skills/rex-orchestrator/scripts"
fixture=$(mktemp -d /tmp/rex-standalone.XXXXXX)
fixture=$(cd "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/home" "$fixture/bin"
checker=$(command -v jq)
lua_bin=$(command -v luajit)
ln -s "$lua_bin" "$fixture/bin/luajit"
cat > "$fixture/bin/rex" <<'REX'
#!/bin/sh
echo 'Error: REX_SERVER: no Rex server is running at fixture' >&2
exit 4
REX
cat > "$fixture/bin/jq" <<'SH'
#!/bin/sh
printf '%s\n' "$0" >> "$HOME/unexpected-dependency"
exit 99
SH
cp "$fixture/bin/jq" "$fixture/bin/python3"
chmod +x "$fixture/bin/rex" "$fixture/bin/jq" "$fixture/bin/python3"
export PATH="$fixture/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/home/.config" REX_ORCHESTRATOR_STATE_DIR="$fixture/state"
export REX_SERVER="unix://$fixture/never-started.sock" REX_BLOCK='' REX_SESSION=''
export REX_ORCHESTRATOR_REX_BIN_DIR="$fixture/bin"
pass=0
check() {
  if [ "$2" != "$3" ]; then printf 'FAIL %s: got [%s], expected [%s]\n' "$1" "$2" "$3" >&2; exit 1; fi
  pass=$((pass+1))
}
cli() { /bin/bash "$scripts/rex-orchestrator.sh" "$@"; }
local_lua() { /bin/bash -p "$scripts/local-lua.sh" "$@"; }
cleanup_cage() { /bin/bash "$scripts/cage-cleanup.sh" "$REX_ORCHESTRATOR_STATE_DIR" "$1"; }

cli help > "$fixture/help"
check 'help is available offline' "$(grep -c '^rex-orchestrator launch' "$fixture/help")" 1
git init -q "$fixture/source"
printf 'this stays in the APFS copy\n' > "$fixture/source/untracked"
check 'clone works offline and creates parents' \
  "$(cli clone "$fixture/source" "$fixture/new/parent/task")" "$fixture/new/parent/task"
check 'clone preserves untracked content' "$(cat "$fixture/new/parent/task/untracked")" 'this stays in the APFS copy'
mkdir -p "$REX_ORCHESTRATOR_STATE_DIR/registry"
printf '{"pid":99999999,"block":"block:stale","session":"session:fixture"}\n' > "$REX_ORCHESTRATOR_STATE_DIR/registry/stale.json"
check 'offline claims prune a dead pid' "$(cli claims --json)" ''
check 'dead claim is removed from disk' "$([ ! -e "$REX_ORCHESTRATOR_STATE_DIR/registry/stale.json" ] && echo gone)" gone
printf '{"pid":%s,"block":"block:alive","session":"session:fixture"}\n' "$$" > "$REX_ORCHESTRATOR_STATE_DIR/registry/live.json"
rc=0; cli claims --json > "$fixture/claims.out" 2> "$fixture/claims.err" || rc=$?
check 'offline claims refuse to report an unchecked live claim' "$rc:$(cat "$fixture/claims.out")" '1:'
check 'offline claims retain the live claim on disk' "$([ -s "$REX_ORCHESTRATOR_STATE_DIR/registry/live.json" ] && echo kept)" kept

offline_error() {
  local diagnostic=$1 rc=0
  shift
  REX_SESSION=session:fixture REX_BLOCK=block:caller cli "$@" > "$fixture/offline.out" 2> "$fixture/offline.err" || rc=$?
  check "offline $1 rejects malformed arguments" "$rc:$(cat "$fixture/offline.out")" '2:'
  check "offline $1 reports the argument error" "$(grep -Fc -- "$diagnostic" "$fixture/offline.err")" 1
}
offline_error 'missing BLOCK' status
offline_error 'LINES takes a whole number' screen block:fixture bad
offline_error '--timeout needs a value' wait block:fixture --timeout
offline_error 'wait: unknown option' wait --force block:fixture --bogus
offline_error 'keys: no keys given' keys --force block:fixture
offline_error 'send: empty prompt' send block:fixture '  '
offline_error 'send: no such file' send block:fixture -f
offline_error 'missing BLOCK' close --force
offline_error 'launch: unknown option' launch --bogus
offline_error '--ratio must be between 1 and 99' launch --ratio 100
rc=0; REX_SESSION=session:fixture REX_BLOCK=block:caller cli wait block:fixture --timeout 5 > "$fixture/offline.out" 2> "$fixture/offline.err" || rc=$?
check 'valid offline calls report a transport failure' "$rc:$(cat "$fixture/offline.out")" '1:'

printf '%s\n' '{"token":{"refresh_token":"\u0066ixture","emoji":"\ud83e\udd8a","n":-0.3e+10}}' > "$fixture/valid.json"
printf '\n{"refresh_token":"dummy","token":{"refresh_token":false}}\r\n' > "$fixture/alternate.json"
for path in "$fixture/valid.json" "$fixture/alternate.json"; do
  check 'standalone token validator accepts one object' "$(local_lua validate-agy "$path" && echo ok)" ok
done
for invalid in '{"refresh_token":""}' '{"refresh_token":"dummy"}{}' '["dummy"]' '{"refresh_token":"\udbff"}' '{"refresh_token":"dummy","n":01}'; do
  printf '%s' "$invalid" > "$fixture/invalid.json"
  rc=0; local_lua validate-agy "$fixture/invalid.json" > "$fixture/token.out" 2> "$fixture/token.err" || rc=$?
  check 'token validator rejects invalid input silently' "$rc:$(cat "$fixture/token.out" "$fixture/token.err")" '1:'
done
mkdir -p "$fixture/login/.gemini/antigravity-cli" "$fixture/linked-gemini" "$fixture/linked-cli/.gemini"
cp "$fixture/valid.json" "$fixture/login/.gemini/antigravity-cli/token"
ln -s "$fixture/login/.gemini" "$fixture/linked-gemini/.gemini"
ln -s "$fixture/login/.gemini/antigravity-cli" "$fixture/linked-cli/.gemini/antigravity-cli"
for link in linked-gemini linked-cli; do
  rc=0; local_lua validate-agy "$fixture/$link/.gemini/antigravity-cli/token" || rc=$?
  check "$link refuses a symlinked login path" "$rc" 1
done

# Exercise dependency discovery without hiding the user's installation.
missing="$fixture/missing-lua"
mkdir "$missing"
sed 's|/opt/homebrew/bin/luajit /usr/local/bin/luajit ||' "$scripts/local-lua.sh" > "$missing/local-lua.sh"
cp "$scripts/rex-orchestrator.sh" "$scripts/cage-cleanup.sh" "$missing/"
rc=0; PATH=/usr/bin:/bin /bin/bash "$missing/rex-orchestrator.sh" clone ignored ignored 2> "$fixture/missing.err" || rc=$?
check 'clone reports the missing interpreter' "$rc" 2
check 'clone names the missing dependency' "$(grep -Fc 'clone requires LuaJIT' "$fixture/missing.err")" 1
rc=0; PATH=/usr/bin:/bin /bin/bash "$missing/rex-orchestrator.sh" claims 2> "$fixture/missing.err" || rc=$?
check 'missing LuaJIT during an offline check is a connection error' "$rc" 1
check 'offline checks name both missing prerequisites' \
  "$(grep -Fc 'Rex is not running. Offline checks require LuaJIT.' "$fixture/missing.err")" 1
rc=0; PATH=/usr/bin:/bin /bin/bash "$missing/local-lua.sh" validate-agy "$fixture/valid.json" 2> "$fixture/missing.err" || rc=$?
check 'token validation reports the missing interpreter to its wrapper' "$rc" 69
check 'token validation names the missing dependency' "$(grep -Fc 'agy token validation requires LuaJIT' "$fixture/missing.err")" 1
cage="$REX_ORCHESTRATOR_STATE_DIR/cage/codex.missing-lua"
mkdir -p "$cage"
PATH=/usr/bin:/bin /bin/bash "$missing/cage-cleanup.sh" "$REX_ORCHESTRATOR_STATE_DIR" "$cage" 2> "$fixture/missing.err"
check 'cleanup reports the missing archive interpreter' "$(grep -Fc 'harvest requires LuaJIT' "$fixture/missing.err")" 1
check 'cleanup still removes the cage' "$([ ! -e "$cage" ] && echo gone)" gone

printf 'external fixture\n' > "$fixture/external"
mkdir "$fixture/external-dir"
cp "$fixture/external" "$fixture/external-dir/transcript-file.jsonl"
for entry in 'claude:claude-config/projects/sub/session.jsonl' 'codex:codex-home/sessions/sub/session.jsonl' \
  'grok:home/.grok/sessions/sub/terminal/session.log' 'agy-team:home/.gemini/antigravity-cli/brain/sub/.system_generated/logs/transcript-1.jsonl'; do
  kind=${entry%%:*}
  rel=${entry#*:}
  cage="$REX_ORCHESTRATOR_STATE_DIR/cage/$kind.fixture"
  mkdir -p "$cage/${rel%/*}"
  # shellcheck disable=SC2016 # jq expands $kind.
  "$checker" -nc --arg kind "$kind" '{kind:$kind,label:"fixture label",block:"block:fixture",account:"one"}' > "$cage/run-meta.json"
  printf 'transcript\n' > "$cage/$rel"
  ln -s "$fixture/external" "$cage/${rel%/*}/symlink.${rel##*.}"
  ln -s "$fixture/external-dir" "$cage/${rel%/*}/symlink-dir"
  ln "$fixture/external" "$cage/${rel%/*}/transcript-hardlink.${rel##*.}"
  mkfifo "$cage/${rel%/*}/transcript-fifo.${rel##*.}"
  cp "$fixture/external" "$cage/${rel%/*}/transcript-auth.${rel##*.}"
  expected=$(/usr/bin/shasum -a 256 < "$cage/$rel" | cut -d' ' -f1)
  cleanup_cage "$cage" > "$fixture/cleanup.out" 2> "$fixture/cleanup.err"
  check "$kind cage removed after archival" "$([ ! -e "$cage" ] && echo gone)" gone
  manifest=$(find "$REX_ORCHESTRATOR_STATE_DIR/runs" -name manifest.json -exec grep -l "\"kind\":\"$kind\"" {} \;)
  check "$kind manifest only includes the allowlisted transcript" \
    "$("$checker" -r '.files|length' "$manifest")" 1
  check "$kind manifest keeps the original block and digest" \
    "$("$checker" -r '[.block,.files[0].sha256,.files[0].bytes]|join(":")' "$manifest")" "block:fixture:$expected:11"
  check "$kind archived transcript is private" "$(stat -f '%Lp' "${manifest%/*}/$rel")" 600
  check "$kind manifest is private" "$(stat -f '%Lp' "$manifest")" 600
done
check 'archive leaves external targets alone' "$(cat "$fixture/external")" 'external fixture'
bad_name=$(printf 'transcript\033[2J\n\302\233\t-café.jsonl')
for label in unsafe-kind unsafe-name; do
  cage="$REX_ORCHESTRATOR_STATE_DIR/cage/codex.$label"
  mkdir -p "$cage/codex-home/sessions"
  if [ "$label" = unsafe-kind ]; then
    printf '%s\n' '{"kind":"fake\u001b[2J\n","label":"unsafe-kind"}' > "$cage/run-meta.json"
    expected='unknown cage kind: fake\x1B[2J\x0A'
  else
    printf '%s\n' '{"kind":"codex","label":"unsafe-name"}' > "$cage/run-meta.json"
    ln "$fixture/external" "$cage/codex-home/sessions/$bad_name"
    expected='transcript\x1B[2J\x0A\u009B\x09-café.jsonl'
  fi
  cleanup_cage "$cage" > "$fixture/cleanup.out" 2> "$fixture/cleanup.err"
  check "$label escapes control sequences in diagnostics" "$(grep -Fc "$expected" "$fixture/cleanup.err")" 1
  check "$label emits one terminal line" "$(wc -l < "$fixture/cleanup.err" | tr -d ' ')" 1
done
mv "$REX_ORCHESTRATOR_STATE_DIR/runs" "$fixture/runs-before"
mkdir "$fixture/outside-runs"
ln -s "$fixture/outside-runs" "$REX_ORCHESTRATOR_STATE_DIR/runs"
cage="$REX_ORCHESTRATOR_STATE_DIR/cage/codex.failure"
mkdir "$cage"
cleanup_cage "$cage" > "$fixture/cleanup.out" 2> "$fixture/cleanup.err"
check 'failed archival still removes the cage' "$([ ! -e "$cage" ] && echo gone)" gone
check 'harvest never follows a symlink at runs' "$(ls -A "$fixture/outside-runs")" ''
check 'no removed runtime dependency was invoked' "$([ ! -e "$HOME/unexpected-dependency" ] && echo yes)" yes
printf 'Lua standalone: %s passed\n' "$pass"
