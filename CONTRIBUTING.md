# Contributing

Thanks for helping! Bug reports, agent support and safety reviews are especially welcome.

## Ground rules

- **Safety first.** Every change that touches what the tool types, presses or approves needs a test, and should make the
  tool *more* conservative, not less. When unsure, leave the decision to the user (exit 3 / exit 10).
- **Status, not screen scraping.** Turn state comes from the agent's OSC 7501 report. The screen is read only to find
  dialogs and confirm what a key will pick.
- **Small, reviewable PRs.** One behaviour change per PR, with the reason in the description.

## Development setup

macOS with Bash, Git and LuaJIT. The test fixtures use `jq` and `python3`. Homebrew Bash also checks Bash 5 alongside
the system's Bash 3.2.

```sh
tests/install_test.sh    # installer
tests/harness/run.sh     # CLI entry and wrapper checks under Bash 3.2 and 5
tests/cage/zt.sh         # cage profile: writes, reads, network, mach, plants — no agent, no tokens
tests/shellcheck.sh       # every tracked shell script: parses under Bash 3.2 and 5, passes shellcheck -x (CI runs it)
luajit tests/lua/unit.lua .  # Lua 5.1 unit tests with fake Rex and in-memory state
tests/lua/entry.sh          # shell entry point and argument serialization under Bash 3.2 and 5
tests/lua/standalone.sh     # offline clone, claims, token validation and transcript archival
tests/lua/live.sh           # shell stand-in on a private throwaway Rex server
```

None of these start a real agent or spend tokens. Before changing dialog handling for an agent, try it by hand in Rex and
capture the screen as a fixture (`rex capture -s "$REX_SESSION" -b BLOCK --trim --unwrap`).

The Lua suites exercise the public commands, including launch, trust, and cage creation. `tests/lua/live.sh` isolates
its socket, state, home and configuration in a fresh folder, disables autostart, and cleans up only its own server.
The suites make their folders under `TMPDIR` (or `/tmp` when it is unset or too deep for a socket path), so they also
run inside the cage: see [Running the suites in a cage](docs/cage.md#running-the-suites-in-a-cage). Set
`REX_TEST_REX` to an absolute CLI path for a Rex executable outside the usual bundle locations. Run shell tests directly
or with `bash -p` to suppress startup hooks before the script runs. The entry points restart with only `HOME`, `USER`,
`TERM`, `TMPDIR`, and `REX_TEST_*` or `REX_LUA_*` inputs from the caller. Set `REX_TEST_REQUIRE_ENV=1` to make environmental
skips fail as they do in CI. To compare with the historical Bash implementation, extract revision `a8913d6` with
`git archive` into a scratch directory. Point `REX_TEST_LEGACY_SH` at that checkout's script to run the legacy fake-Rex
harness, or set `REX_LUA_BASELINE` to compare real Rex responses. Set
`REX_LUA_BENCHMARK=/tmp/rex-lua-benchmark.tsv` in addition to `REX_LUA_BASELINE` for the side-by-side benchmark.

## Layout

```text
skills/rex-orchestrator/
  SKILL.md                      instructions an orchestrating agent reads
  scripts/rex-orchestrator.sh   the CLI entry point
  scripts/lua/                  pane reads, mutations and launch, event-driven wait, and claims
  scripts/local-lua.sh          locates LuaJIT for commands that work offline
  scripts/help.txt              CLI command reference
  scripts/cage-cleanup.sh       shared shell cleanup and transcript harvest entry point
  scripts/cage.sb               sandbox-exec profile
  scripts/cage/                 config templates and shell runtimes for caged agents
  scripts/lua/harvest.lua       copies a caged child's transcripts on close
tests/harness/                  fake `rex` (bin/rex), fake agents, screen fixtures, scenario runners
tests/cage/                     zero-token cage tests and C probes
tests/lua/                      Lua unit tests, isolated live tests and benchmark
tests/install_test.sh           installer tests
docs/                           reference documentation
```

## Adding an agent

1. Make sure it reports Rex program status (OSC 7501); without that `wait` can't work.
2. Capture its trust and startup dialogs at several pane sizes as fixtures.
3. Add its `KIND` to the launch and dialog modules in `scripts/lua/` and extend the stand-in fixtures.
4. Document its quirks in `docs/supported-agents.md`.

## Style

- Bash 3.2 compatible (macOS's `/bin/bash`), `shellcheck`-clean.
- Comments explain *why*; keep them neutral and technical.
- English everywhere.

## Commit messages

Imperative mood, short subject (`launch: refuse a trust dialog that names a parent folder`), body explaining the reason.
