#!/bin/bash -p
# Run the current shell entry and wrapper checks under both Bash versions.
# REX_TEST_LEGACY_SH selects a historical Bash implementation for the legacy fake-Rex scenarios.
set -u
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh" || exit 2
here=$(cd "$(dirname "$0")" && pwd)
runs=${REX_TEST_HARNESS_RUNS:-$(mktemp -d /tmp/rex-orchestrator-harness.XXXXXX)}
bashes=/bin/bash
[ -x /opt/homebrew/bin/bash ] && bashes="$bashes /opt/homebrew/bin/bash"
# shellcheck disable=SC2016  # the inner bash expands it
ver() { "$1" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"'; }

for b in $bashes; do
  v=$(ver "$b")
  mkdir -p "$runs/bash-$v"
  (
    export REX_TEST_BASH="$b"
    if [ -n "${REX_TEST_LEGACY_SH:-}" ]; then
      export REX_ORCHESTRATOR_SH="$REX_TEST_LEGACY_SH" HARNESS_BASH="$b" HARNESS_RUNS="$runs/bash-$v"
      [ -z "${REX_TEST_HARNESS_JOBS:-}" ] || export HARNESS_JOBS="$REX_TEST_HARNESS_JOBS"
      python3 -I "$here/harness.py" "$@" || echo "FAIL  harness.py exited $?"
      python3 -I "$here/harness2.py" "$@" || echo "FAIL  harness2.py exited $?"
      python3 -I "$here/harness4.py" "$@" || echo "FAIL  harness4.py exited $?"
      "$b" -p "$here/unit.sh" || echo "FAIL  unit.sh exited $?"
      "$b" -p "$here/startup.sh" || echo "FAIL  startup.sh exited $?"
    else
      "$b" -p "$here/../lua/entry.sh" && echo "PASS  Lua entry checks" || echo "FAIL  entry.sh exited $?"
    fi
    "$b" -p "$here/../cage/agy-token.sh" || echo "FAIL  agy-token.sh exited $?"
  ) >"$runs/bash-$v.log" 2>&1 &
done
wait

fail=0
for b in $bashes; do
  v=$(ver "$b")
  log="$runs/bash-$v.log"
  p=$(grep -c '^PASS' "$log"); f=$(grep -c '^FAIL' "$log")
  echo "bash $v: $p/$((p + f)) passed"
  grep '^SKIP ' "$log"
  grep '^FAIL' "$log" | cut -f1 | sed 's/^FAIL  /  FAIL /' | sort
  [ "$f" -eq 0 ] && [ "$p" -gt 0 ] || fail=1
done
echo "logs and runs: $runs"
exit "$fail"
