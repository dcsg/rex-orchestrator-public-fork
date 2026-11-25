# Contributing

Thanks for helping! Bug reports, agent support and safety reviews are especially welcome.

## Ground rules

- **Safety first.** Every change that touches what the tool types, presses or approves needs a test, and should make the
  tool *more* conservative, not less. When unsure, leave the decision to the user (exit 3 / exit 10).
- **Status, not screen scraping.** Turn state comes from the agent's OSC 7501 report. The screen is read only to find
  dialogs and confirm what a key will pick.
- **Small, reviewable PRs.** One behaviour change per PR, with the reason in the description.

## Development setup

macOS with `bash`, `jq`, `git`, `python3`, and optionally `shellcheck` and Homebrew's `bash` (to test bash 5 as well as the
system 3.2).

```sh
tests/install_test.sh    # installer
tests/harness/run.sh     # fake rex + fake agents, every scenario under bash 3.2 (and 5, if installed)
tests/cage/zt.sh         # cage profile: writes, reads, network, mach, plants — no agent, no tokens
shellcheck install.sh skills/rex-orchestrator/scripts/rex-orchestrator{,-bash}.sh
luajit tests/lua/unit.lua .  # Lua 5.1 unit tests with fake Rex and in-memory state
tests/lua/entry.sh          # shell entry point and argument serialization under Bash 3.2 and 5
tests/lua/live.sh           # shell stand-in on a private throwaway Rex server
```

None of these start a real agent or spend tokens. `tests/harness/run.sh` must pass locally before a PR: it polls in real
time, so on slow shared CI runners a few timeout scenarios can miss their windows, and CI reports it as informative only. Before changing dialog handling for an agent, try it by hand in Rex and
capture the screen as a fixture (`rex capture -s "$REX_SESSION" -b BLOCK --trim --unwrap`).

During the Lua migration the Bash harness targets `rex-orchestrator-bash.sh`, which retains the commands not yet
ported. The Lua suites cover the public read commands separately. `tests/lua/live.sh` isolates its socket, state,
HOME and configuration under `/tmp`, disables autostart on every client call, and cleans up only its own server.
Set `REX_TEST_REX` to an absolute CLI path if it is not on the test PATH. For the side-by-side benchmark, set
`REX_LUA_BENCHMARK=/tmp/rex-lua-benchmark.tsv`; it also needs Homebrew Bash and LuaJIT.

## Layout

```text
skills/rex-orchestrator/
  SKILL.md                      instructions an orchestrating agent reads
  scripts/rex-orchestrator.sh   the CLI entry point
  scripts/lua/                  status, ls, screen and event-driven wait
  scripts/rex-orchestrator-bash.sh  commands awaiting migration and cage runtime
  scripts/cage.sb               sandbox-exec profile
  scripts/cage/                 config templates for caged agents
  scripts/harvest.py            copies a caged child's transcripts on close
tests/harness/                  fake `rex` (bin/rex), fake agents, screen fixtures, scenario runners
tests/cage/                     zero-token cage tests and C probes
tests/lua/                      Lua unit tests, isolated live tests and benchmark
tests/install_test.sh           installer tests
docs/                           reference documentation
```

## Adding an agent

1. Make sure it reports Rex program status (OSC 7501); without that `wait` can't work.
2. Capture its trust and startup dialogs at several pane sizes as fixtures.
3. Add its `KIND` (see `pane_kind` and the dialog functions in `rex-orchestrator-bash.sh`) and a fake agent in `tests/harness/agents/`.
4. Document its quirks in `docs/supported-agents.md`.

## Style

- Bash 3.2 compatible (macOS's `/bin/bash`), `shellcheck`-clean.
- Comments explain *why*; keep them neutral and technical.
- English everywhere.

## Commit messages

Imperative mood, short subject (`launch: refuse a trust dialog that names a parent folder`), body explaining the reason.
