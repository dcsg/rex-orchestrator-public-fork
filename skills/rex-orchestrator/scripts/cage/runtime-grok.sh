# shellcheck shell=bash
mkdir -p "$CT/home/.grok"
[ -f "$CT/home/.grok/config.toml" ] || cp "$TPL/grok.toml" "$CT/home/.grok/config.toml"
exec /usr/bin/env -i HOME="$CT/home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL=/bin/zsh \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  TERM="${TERM:-xterm-256color}" TERM_PROGRAM="${TERM_PROGRAM:-}" TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}" \
  COLORTERM="${COLORTERM:-}" LANG="${LANG:-en_US.UTF-8}" REX_SERVER=unix:///dev/null/rex-cage-no-server \
  GROK_HOME="$CT/home/.grok" GROK_AUTH_PATH="$AUTH" TMPDIR="$CT/" \
  GROK_DISABLE_AUTOUPDATER=1 GROK_AUTH_EARLY_INVALIDATION_SECS=0 \
  /usr/bin/sandbox-exec -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO" -D HOOKSPATH="$HOOKS" -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$TTY" -D CAGE_SECRETS="$SEC" -D AGENT_BIN_FILE="$BINFILE" \
    -f "$PROF" "$REAL" --always-approve "$@"
