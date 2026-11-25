# shellcheck shell=bash
mkdir -p "$CT/claude-config" "$CT/zdot"
[ -f "$CT/claude-config/.claude.json" ] || cp "$TPL/claude.json" "$CT/claude-config/.claude.json"
[ -f "$CT/claude-config/settings.json" ] || cp "$TPL/claude-settings.json" "$CT/claude-config/settings.json"
# rex_term_text comes from term-text.sh, which the launcher puts ahead of this file in the wrapper.
# CLAUDE_CODE_OAUTH_TOKEN for the child only, from its account's file (outside the cage), loaded silently: a malformed
# line would print itself, the token, on the child's screen.
# shellcheck disable=SC1090 # CRED is the chosen per-account credential file, known only at launch.
. "$CRED" >/dev/null 2>&1 && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ||
  { printf 'rex-orchestrator cage: %s sets no CLAUDE_CODE_OAUTH_TOKEN (its content is not shown)\n' \
      "$(rex_term_text "$CRED")" >&2; exit 1; }
exec /usr/bin/env -i HOME="$RH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh ZDOTDIR="$CT/zdot" \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" REX_SERVER=unix:///dev/null/rex-cage-no-server \
  CLAUDE_CONFIG_DIR="$CT/claude-config" CLAUDE_CODE_TMPDIR="$CT" TMPDIR="$CT/" DISABLE_AUTOUPDATER=1 \
  ENABLE_CLAUDEAI_MCP_SERVERS=false CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
  CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --dangerously-skip-permissions --strict-mcp-config --no-chrome "$@"
