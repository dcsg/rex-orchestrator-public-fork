# shellcheck shell=bash
mkdir -p "$CT/codex-home" "$CT/tmpdir"
ln -sf "$AUTH" "$CT/codex-home/auth.json"
[ -f "$CT/codex-home/config.toml" ] || cp "$TPL/codex.toml" "$CT/codex-home/config.toml"
exec /usr/bin/env -i HOME="$RH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" \
  CODEX_HOME="$CT/codex-home" TMPDIR="$CT/tmpdir/" \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" -D AGENT_BIN_DIR="$BINDIR" \
    -f "$PROF" "$REAL" --dangerously-bypass-approvals-and-sandbox --no-daemon "$@"
