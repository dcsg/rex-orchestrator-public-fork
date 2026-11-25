# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD` provisions a caged agy login from a shell command outside the sandbox.
  The token is private (mode 600), absent from the agent's environment, and deleted on exit or HUP/INT/TERM;
  failed or empty commands stop the wrapper with exit 71 before agy starts. Unset preserves copied logins.
- `REX_ORCHESTRATOR_CAGE_CODEX_BIN`, `REX_ORCHESTRATOR_CAGE_CLAUDE_BIN` and `REX_ORCHESTRATOR_CAGE_GROK_BIN` name the
  executable a caged agent runs. They never apply to an uncaged launch.

### Changed
- Rex commands run in Lua via `rex do`. LuaJIT is required for local operations, and `jq` and `python3` are no longer
  runtime dependencies.

### Fixed
- Validate `launch --ratio` during argument parsing so an invalid split percentage exits 2 before placement.
- Check the global launch kill switch before parsing launch options. Validate `--account` spelling and cage eligibility
  before looking up the agent executable.
- Accept agy's nested `token.refresh_token` in token-command output while preserving top-level `refresh_token`
  compatibility; use the complete nested token shape in fake-login regressions.
- Isolate agy's uncaged token lookup from project configs and environment, hide its command text from caged children,
  and validate the returned refresh-token JSON silently. Stop and reap the child before signal cleanup, with a
  five-second grace period and forced termination if needed; cover additional signals and the fork startup race.
  Keep private command files denied after profile read exceptions, including custom state under `~/.config/git`.
- Resolve the session from `REX_BLOCK` when `REX_SESSION` is empty, supporting Rex server 0.1.0-preview.23.
  An explicit `REX_SESSION` selects the session.
- Escape terminal controls, invalid UTF-8 and bidi controls in every diagnostic: Lua's notes, refusals and raw
  diagnostics (screen tails, Rex and git errors) are escaped where they are written. The shell entry point,
  installer, cage cleanup and claude wrapper share `scripts/term-text.sh`, which escapes exactly as the Lua side
  does (C0, DEL, raw C1 bytes and invalid UTF-8 as `\xNN`, UTF-8 C1 controls and bidi overrides and isolates as
  `\uNNNN`, backslashes doubled), so Rex's own error lines print the same way. Each line of Rex's own output that the
  CLI forwards starts with `rex: `, and text meant to span lines (screen tails, a tool's stderr) is indented, so
  neither can pass for a `rex-orchestrator: ` diagnostic.
- Match agent homes and the other protected locations without regard to ASCII case in `launch`'s checks, as the
  home volume and the cage profile do: a DIR in `~/.CODEX`, a link spelled `~/.CODEX`, or a HOME spelled in another
  case no longer slips past them.
- Run a caged grok from its standard install (`~/.grok/downloads/<file>`, linked from `~/.grok/bin/grok`): the cage runs
  that one file by its physical path and re-opens only it, read and execute only, for that launch.
- Run a caged codex from a standalone install (`~/.codex/packages/standalone/releases/<version>/`): the cage runs it by
  its physical path and re-opens only that release folder, read and execute only, for that launch. A caged codex,
  claude or grok launched by name skips script shims on `PATH` (anything but a compiled executable or a Node launcher of an exact shape)
  instead of running them in the cage. The cage
  now denies execution under agent homes as well as reads, and `launch` refuses an agent executable it can't start
  there with exit 2. An executable reached through a link inside an agent home runs by its physical path.
- Find cage assets beside the real CLI script through absolute and relative install symlinks and symlink chains,
  while keeping environment overrides first.

## [0.1.0] - 2026-11-11

First public release.

### Added
- `rex-orchestrator` CLI: `launch`, `send`, `wait`, `keys`, `screen`, `status`, `ls`, `close`, `clone`, `claims`.
- Works with any orchestrating agent in a Rex pane; children: Claude Code, Codex, Grok, Gemini (agy), Muse, or any command.
- Turn tracking from Rex program status (OSC 7501), including background-work holds.
- Guard rails: ownership checks, idle-input-only typing, refused shell/permission-widening prompts, one-time-only dialog
  answers, permission-mode pin, kill switches, `wait --approve-in` for scoped file edits.
- Write claims across Rex sessions, and `clone` for isolated checkouts.
- Optional macOS `sandbox-exec` cage with transcript harvesting.
- Agent Skill (`SKILL.md`) and an installer for Claude Code, `~/.agents/skills` readers and custom folders.
- Designated orchestrators: an optional `orchestrators` file limits who may `launch` (by agent and account).

### Credits
- Based on the MIT-licensed `rex-claude` skill from [davila7/claude-code-templates](https://github.com/davila7/claude-code-templates).

[0.1.0]: https://github.com/mkltxo/rex-orchestrator/releases/tag/v0.1.0
