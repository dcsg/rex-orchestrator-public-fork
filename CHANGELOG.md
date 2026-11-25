# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD` provisions a caged agy login from a shell command outside the sandbox.
  The token is private (mode 600), absent from the agent's environment, and deleted on exit or HUP/INT/TERM;
  failed or empty commands stop the wrapper with exit 71 before agy starts. Unset preserves copied logins.

### Changed
- Rex commands run in Lua via `rex do`. LuaJIT is required for local operations, and `jq` and `python3` are no longer
  runtime dependencies.

### Fixed
- Accept agy's nested `token.refresh_token` in token-command output while preserving top-level `refresh_token`
  compatibility; use the complete nested token shape in fake-login regressions.
- Isolate agy's uncaged token lookup from project configs and environment, hide its command text from caged children,
  and validate the returned refresh-token JSON silently. Stop and reap the child before signal cleanup, with a
  five-second grace period and forced termination if needed; cover additional signals and the fork startup race.
  Keep private command files denied after profile read exceptions, including custom state under `~/.config/git`.
- Resolve the session from `REX_BLOCK` when `REX_SESSION` is empty, supporting Rex server 0.1.0-preview.23.
  An explicit `REX_SESSION` selects the session.
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
