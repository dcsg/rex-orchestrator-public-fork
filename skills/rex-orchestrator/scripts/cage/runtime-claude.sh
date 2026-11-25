# shellcheck shell=bash
mkdir -p "$CT/claude-config" "$CT/zdot"
[ -f "$CT/claude-config/.claude.json" ] || cp "$TPL/claude.json" "$CT/claude-config/.claude.json"
[ -f "$CT/claude-config/settings.json" ] || cp "$TPL/claude-settings.json" "$CT/claude-config/settings.json"
# rex_term_text comes from term-text.sh, which the launcher puts ahead of this file in the wrapper.
if [ -n "$CLAUDE_CMD_FILE" ]; then
  # CLAUDE_CODE_OAUTH_TOKEN from CLAUDE_CMD_NAME (REX_ORCHESTRATOR_CAGE_CLAUDE_TOKEN_CMD[_ACCOUNT]), whose text waits in a
  # private file the cage denies to every child. It runs here, outside the cage, from / with only HOME, a fixed PATH,
  # SHELL and LANG, stdin closed and stderr dropped (a failing command can print the credential). The token stays in
  # this shell's memory and the child's environment: it is never written to disk, so nothing is left to remove on exit.
  # The command file goes as soon as the command ends, on a signal before that, and with the cage home on close.
  trap '/bin/rm -f "$CLAUDE_CMD_FILE"; exit 129' HUP
  trap '/bin/rm -f "$CLAUDE_CMD_FILE"; exit 130' INT
  trap '/bin/rm -f "$CLAUDE_CMD_FILE"; exit 143' TERM
  CLAUDE_CODE_OAUTH_TOKEN=$(cd / && exec /usr/bin/env -i HOME="$RH" PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    SHELL=/bin/bash LANG=en_US.UTF-8 /bin/bash --noprofile --norc "$CLAUDE_CMD_FILE" </dev/null 2>/dev/null) ||
    CLAUDE_CODE_OAUTH_TOKEN=
  /bin/rm -f "$CLAUDE_CMD_FILE"
  trap - HUP INT TERM
  # The shape of a claude setup-token token, checked without showing it: sk-ant-oat, two digits, a dash, then base64url
  # characters only, 40 to 512 bytes in all (the command's trailing newlines are already gone). Anything else, a
  # partial line, a message or an export line, stops the wrapper before claude starts.
  case "$CLAUDE_CODE_OAUTH_TOKEN" in
    sk-ant-oat[0-9][0-9]-*) claude_token_rest=${CLAUDE_CODE_OAUTH_TOKEN#sk-ant-oat[0-9][0-9]-} ;;
    *) claude_token_rest='!' ;;
  esac
  case "$claude_token_rest" in '' | *[!A-Za-z0-9_-]*) claude_token_rest='!' ;; esac
  if [ "$claude_token_rest" = '!' ] || [ "${#CLAUDE_CODE_OAUTH_TOKEN}" -lt 40 ] || [ "${#CLAUDE_CODE_OAUTH_TOKEN}" -gt 512 ]; then
    CLAUDE_CODE_OAUTH_TOKEN=
    printf 'rex-orchestrator cage: %s failed or printed something that is not a Claude OAuth token (the output is not shown); claude not started\n' \
      "$(rex_term_text "$CLAUDE_CMD_NAME")" >&2
    exit 71
  fi
  unset claude_token_rest
else
  # CLAUDE_CODE_OAUTH_TOKEN for the child only, from its account's file (outside the cage), loaded silently: a
  # malformed line would print itself, the token, on the child's screen.
  # shellcheck disable=SC1090 # CRED is the chosen per-account credential file, known only at launch.
  . "$CRED" >/dev/null 2>&1 && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ||
    { printf 'rex-orchestrator cage: %s sets no CLAUDE_CODE_OAUTH_TOKEN (its content is not shown)\n' \
        "$(rex_term_text "$CRED")" >&2; exit 1; }
fi
exec /usr/bin/env -i HOME="$RH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh ZDOTDIR="$CT/zdot" \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" REX_SERVER=unix:///dev/null/rex-cage-no-server \
  CLAUDE_CONFIG_DIR="$CT/claude-config" CLAUDE_CODE_TMPDIR="$CT" TMPDIR="$CT/" DISABLE_AUTOUPDATER=1 \
  ENABLE_CLAUDEAI_MCP_SERVERS=false CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 \
  CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" \
    -f "$PROF" "$REAL" --dangerously-skip-permissions --strict-mcp-config --no-chrome "$@"
