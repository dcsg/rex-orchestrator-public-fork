#!/bin/bash -p
# Tests for install.sh in a throwaway HOME: dry run, install, idempotence, uninstall, refusal to clobber.
set -uo pipefail
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/isolate.inc.sh" || exit 2

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0

check() { # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi
}
inst() { env HOME="$T" PATH="/usr/bin:/bin" "$ROOT/install.sh" "$@"; }
links() { find "$T" -type l | wc -l | tr -d ' '; }

check "dry run plans 3 links" 3 "$(inst --dry-run | grep -c 'would link')"
check "dry run creates nothing" 0 "$(links)"

inst >/dev/null
check "install creates 3 links" 3 "$(links)"
check "CLI link target" "$ROOT/skills/rex-orchestrator/scripts/rex-orchestrator.sh" "$(readlink "$T/.local/bin/rex-orchestrator")"
check "claude skill link" "$ROOT/skills/rex-orchestrator" "$(readlink "$T/.claude/skills/rex-orchestrator")"
check "CLI is executable through its link" yes "$([ -x "$T/.local/bin/rex-orchestrator" ] && echo yes)"
check "re-install is idempotent" 3 "$(inst | grep -c '^ok')"

check "uninstall removes 3 links" 3 "$(inst --uninstall | grep -c removed)"
check "nothing left" 0 "$(links)"

mkdir -p "$T/.local/bin" && touch "$T/.local/bin/rex-orchestrator"
inst --agents none >/dev/null 2>&1
check "refuses to replace a real file" 1 "$?"
check "real file kept" "file" "$([ -f "$T/.local/bin/rex-orchestrator" ] && [ ! -L "$T/.local/bin/rex-orchestrator" ] && echo file)"

inst --agents bogus >/dev/null 2>&1
check "unknown agent target exits 2" 2 "$?"

mkdir -p "$T/custom"
inst --agents none --skills-dir "$T/custom" >/dev/null 2>&1 || true
check "--skills-dir links the skill" "$ROOT/skills/rex-orchestrator" "$(readlink "$T/custom/rex-orchestrator")"

mkdir -p "$T/ro" && chmod 555 "$T/ro"
out=$(inst --agents none --bin-dir "$T/ro" 2>/dev/null); rc=$?
chmod 755 "$T/ro"
check "a link that cannot be made exits 1" 1 "$rc"
check "a link that cannot be made is not reported as linked" 0 "$(printf '%s\n' "$out" | grep -c '^linked')"

# Caller-supplied text is printed with its controls escaped, never raw.
esc=$(printf '\033]0;owned\007')
out=$(inst "--bogus$esc" 2>&1 >/dev/null); rc=$?
check "unknown option with controls exits 2" 2 "$rc"
check "unknown option is shown escaped" 1 "$(printf '%s\n' "$out" | grep -cF 'unknown option --bogus\x1B]0;owned\x07')"
check "unknown option prints no raw control" 0 "$(printf '%s' "$out" | tr -d '\n' | LC_ALL=C grep -c '[[:cntrl:]]')"
mkdir -p "$T/bin$esc"
out=$(inst --agents none --dry-run --bin-dir "$T/bin$esc" 2>&1)
check "a planned link shows its path escaped" 1 "$(printf '%s\n' "$out" | grep -cF "would link $T/bin\x1B]0;owned\x07/rex-orchestrator")"
check "a planned link prints no raw control" 0 "$(printf '%s' "$out" | tr -d '\n' | LC_ALL=C grep -c '[[:cntrl:]]')"

printf 'install_test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
