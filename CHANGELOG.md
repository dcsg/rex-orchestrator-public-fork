# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Resolve the session once from `REX_BLOCK` when `REX_SESSION` is empty, supporting Rex server 0.1.0-preview.23.
  Explicit `REX_SESSION` values remain unchanged; failed resolution reports both environment variables.
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
