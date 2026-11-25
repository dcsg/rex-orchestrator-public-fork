#!/bin/bash -p
# zt.sh: a zero-token regression for the rex-orchestrator sandbox-exec cage. No agent, no network, no tokens; a few seconds.
# Each cage is built by the Lua builder used by `launch`, with a probe in the
# agent's place, and every check runs through the generated wrapper itself: its env -i, the -D set it computes and the
# flags it gives the agent. A fixture HOME stands in for the real one, so nothing of the user's is read. It checks:
#   - the profile loads, and fails closed when a required param (DIR_RE, DIR) is missing or HOOKSPATH or AGENT_BIN_DIR
#     is empty;
#   - the child's environment holds only its cage's own variables (codex, grok, and claude and agy with dummy cage
#     credentials): no REX_*, SSH_AUTH_SOCK or tokens of the caller's;
#   - a caged claude runs with CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1;
#   - a caged claude gets exactly its account's token (claude-one.env and claude-two.env hold different dummies: the
#     one --account names, else the alphabetically first), never a claude.env's, and a malformed per-account file stops
#     the wrapper without showing its content;
#   - writes land only in DIR and the cage temp (outside, symlink-out, rename-out and hardlink-out denied), and the
#     wrapper and the one locked config file stay write-denied;
#   - what runs or is sourced outside the cage (the cage secrets, also through a link, and the launcher's skill folder)
#     stays write-locked even in a DIR that holds it: no write, swapped link, move or hard link;
#   - reads of the secret stores, of every agent home by prefix (~/.claude*, ~/.codex*, ~/.grok*, ~/.gemini*), of
#     ~/.config but its git folder, of the keychains and of other sessions' scratchpads are denied; the one AGENT_AUTH
#     file is readable and a file beside it is not; other home files stay readable;
#   - the child writes its own tty, /dev/tty and the sub-ptys it opens (any /dev/ttysN, by design);
#   - other repos under ~/Repos are unreadable (contents, listings; stat works), DIR's own is not, in or outside ~/Repos;
#   - a child reads its own cage home and not a sibling's (another home under the same cage root), nor the root itself;
#   - every DIR auto-run plant lock holds (.agents, which agy loads as instructions, too: the entry itself as well), for a plain DIR and for DIRs holding each regex metacharacter, while ordinary
#     writes there work; a repo's core.hooksPath inside DIR is locked (also a missing one, one from a subfolder DIR,
#     one written "~/");
#   - the child can't signal a process outside the cage, connect to a loopback port or a unix socket, or run
#     /usr/bin/open or launchctl;
#   - close's rmcage removes a cage home the child sealed (folders without rwx, uchg/uappnd flags, ACLs, nested), and
#     leaves a file a link in it points to alone;
#   - a standalone codex under HOME/.codex/packages/standalone/releases/<version>/, reached through a link on PATH,
#     runs in the cage from its physical path with only its release folder readable: auth.json (with CODEX_HOME
#     elsewhere), config, sessions, history, logs and a sibling release stay unreadable and unexecutable, the release
#     folder unwritable; script shims first on PATH (shell in every #! form, no #!, fish, Python, Perl, Ruby) are
#     skipped and never run while a Node script is taken, a PATH of shims only is refused
#     naming the override, REX_ORCHESTRATOR_CAGE_CODEX_BIN picks the executable, an agent executable elsewhere
#     under an agent home is refused, and one outside them reached through a link inside one runs by its physical path;
#     agent homes match whatever their case (a link spelled ~/.CODEX, HOME spelled otherwise, an on-disk ~/.Claude-zt);
#     paths with terminal controls in launch's notes and refusals are escaped;
#   - a grok download, HOME/.grok/downloads/<file> reached through ~/.local/bin/grok and ~/.grok/bin/grok, runs in the
#     cage from its physical path with only that file readable and executable: sibling downloads, the folder, the
#     links, config, sessions, logs and (with AGENT_AUTH elsewhere) auth.json stay closed;
#   - a seeding step of the wrapper that fails stops it before the agent starts (its set -e);
#   - if clang is present, a Mach-O compiled in-cage reaches exactly the 7 allowlisted mach services and can't open
#     an IOKit user client.
# Usage: tests/cage/zt.sh
# Prints one PASS/FAIL line per check; exits non-zero on any FAIL.
set -u
# shellcheck source=tests/isolate.inc.sh
. "${BASH_SOURCE[0]%/*}/../isolate.inc.sh" || exit 2
HERE=$(cd "$(dirname "$0")" && pwd -P)
SCRIPT=$HERE/../../skills/rex-orchestrator/scripts/rex-orchestrator.sh
SDIR=$(cd "$(dirname "$SCRIPT")" && pwd -P)
ASSETS=$SDIR
PROFILE="$SDIR/cage.sb"

P=0; F=0
ok()  { P=$((P + 1)); printf 'PASS  %s\n' "$1"; }
bad() { F=$((F + 1)); printf 'FAIL  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: want [$2] got [$3]"; fi; }

[ -r "$PROFILE" ] || { echo "zt: no profile at $PROFILE"; exit 2; }
command -v luajit >/dev/null 2>&1 || { echo "zt: luajit required"; exit 2; }

# shellcheck source=tests/cage/build.inc.sh
. "$HERE/build.inc.sh"

# --- Hermetic: a work dir outside /private/tmp/claude-<uid> (the profile hides that tree's data), a fixture HOME, a
#     private STATE_DIR and dummy cage credentials; none of the caller's homes. What a failed check sealed is cleared
#     too. ---
WORK=$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)/rex-cage-zt.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
SLEEPER="" LISTENER="" SCRATCH_FIXTURE="" SCRATCH_ROOT=""
unseal() {
  find "$1" -type d -exec chflags nouchg,nouappnd {} \; -exec chmod -N {} \; -exec chmod u+rwx {} \; 2>/dev/null
  chflags -R nouchg,nouappnd "$1" 2>/dev/null; chmod -R -N "$1" 2>/dev/null
}
trap 'kill $SLEEPER $LISTENER 2>/dev/null; unseal "$WORK"; rm -rf "$WORK"
  [ -z "$SCRATCH_FIXTURE" ] || rm -rf "$SCRATCH_FIXTURE"
  [ -z "$SCRATCH_ROOT" ] || rmdir "$SCRATCH_ROOT" 2>/dev/null || :' EXIT
FH="$WORK/home"; STATE_DIR="$WORK/state"; mkdir -p "$FH" "$STATE_DIR"
export HOME="$FH" REX_SESSION=session:zt REX_BLOCK=block:zt SSH_AUTH_SOCK="$WORK/agent.sock" ZT_TOKEN=zt-secret-must-not-leak
# Use fixture secrets and a stand-in skill folder whose parent the cage write-locks.
# shellcheck disable=SC2034
{ CAGE_PROFILE="$PROFILE"; CAGE_TPL="$SDIR/cage"; CAGE_SECRETS="$FH/.config/rex-orchestrator/cage-secrets"
  account=""; CAGE_AGY_HOME="$WORK/no-agy-home"; SCRIPT_DIR="$WORK/skill/scripts"; }
OUT="$WORK/outside"; mkdir -p "$OUT"
# Fixture secrets and agent homes, the AGENT_AUTH files, and files that must stay readable.
CS=.config/rex-orchestrator/cage-secrets
for p in .ssh/id_x .aws/credentials .gnupg/x .netrc $CS/claude.env $CS/claude-one.env $CS/claude-two.env \
  Library/Keychains/login.keychain-db Library/Messages/chat.db Library/Mail/x \
  .config/gh/hosts.yml .config/rclone/rclone.conf .config/gcloud/credentials.db .config/anthropic/x \
  .config/configstore/firebase-tools.json .config/some-cli/token .cloudflared/cert.pem .mcp-auth/x .supabase/access-token \
  .zsh_history .bash_history .zsh_sessions/x \
  .claude.json .claude.json.backup .claude.json.bak-trust .claude/x .claude-work/x \
  .claude-server-commander/x .codex/auth.json .codex/other .codex-alt/x .grok/auth.json .grok/other \
  .grokbot/x .gemini/x .cursor/x .copilot/x .hermes/x .pi/x .mastracode/x "Library/Application Support/Claude/x" \
  "Library/Application Support/Codex/x" "Library/Application Support/com.openai.codex/x" \
  "Library/Application Support/Muse/x" \
  notes.txt .gitconfig .config/git/config "Library/Application Support/SomeApp/x" Repos/other/x; do
  mkdir -p "$FH/$(dirname "$p")"; printf 'fixture\n' >"$FH/$p"
done
printf '[user]\n\tname = zt\n\temail = zt@example.invalid\n' | tee "$FH/.gitconfig" >"$FH/.config/git/config"
mkdir -p "$SCRIPT_DIR/cage"
cp "$SDIR/cage/"runtime-*.sh "$SDIR/cage/agy-paths.sh" "$SCRIPT_DIR/cage/"
for p in rex-orchestrator.sh cage.sb cage/claude.json ../SKILL.md; do printf 'fixture\n' >"$SCRIPT_DIR/$p"; done
# One dummy token per account; claude.env keeps the fixture line above, which no wrapper may load.
mkdir -p "$WORK/agy-home/.gemini"
for a in one two; do printf 'export CLAUDE_CODE_OAUTH_TOKEN=zt-dummy-%s\n' "$a" >"$CAGE_SECRETS/claude-$a.env"; done

# The agent's stand-in: it drops the flags each recipe gives its agent, then runs sh with the rest (-c PROG, or a
# script).
PROBE="$WORK/bin/probe"; mkdir -p "$WORK/bin"
cat >"$PROBE" <<'EOF'
#!/bin/sh
while :; do case "${1:-}" in --mode | --settings) shift 2 ;; --*) shift ;; *) break ;; esac; done
exec /bin/sh "$@"
EOF
# In-cage helpers, one line per path: ALLOW/DENY a write (its folder made first), READ/DENY a read (a folder: listed).
cat >"$WORK/bin/w" <<'EOF'
for p in "$@"; do mkdir -p "${p%/*}" 2>/dev/null; if (: >"$p") 2>/dev/null; then echo "ALLOW $p"; else echo "DENY $p"; fi; done
EOF
cat >"$WORK/bin/r" <<'EOF'
for p in "$@"; do
  if [ -d "$p" ]; then ls "$p" >/dev/null 2>&1 && echo "READ $p" || echo "DENY $p"
  else dd if="$p" bs=1 count=1 >/dev/null 2>&1 && echo "READ $p" || echo "DENY $p"; fi
done
EOF
chmod +x "$PROBE"

# mk AGENT DIR: build AGENT's cage for DIR as launch does; sets W (its wrapper), CT (its cage temp) and CWD (DIR).
mk() { cage_wrapper=""; cage_build "$1" "$PROBE" "$2" >"$WORK/build.log" 2>&1 && W=$cage_wrapper CT=$cage_tmp CWD=$2; }
cg() { (cd "$CWD" && "$W" "$@") 2>&1; }   # sh ARGS in the current cage, through its real wrapper, started in DIR as rex does
q() { sq "$1"; }
# want VERB WORD PATH...: run the in-cage helper VERB (w or r) on the PATHs and check each answer is WORD.
want() {
  local verb="$1" word="$2" line n=0; shift 2
  while IFS= read -r line; do
    case "$line" in ALLOW\ * | DENY\ * | READ\ *) n=$((n + 1)); chk "$verb ${line#* }" "$word" "${line%% *}" ;; esac
  done < <(cg "$WORK/bin/$verb" "$@")
  [ "$n" -eq "$#" ] || bad "$verb: only $n of $# paths answered in the cage"
}
# env_is AGENT NAME...: the child's variables are exactly NAME... (plus the PWD and SHLVL sh sets itself).
env_is() {
  local a="$1" got exp; shift
  got=$(cg -c 'exec /usr/bin/env' | sed 's/=.*//' | grep -vxE 'PWD|SHLVL' | sort | tr '\n' ' ')
  exp=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  chk "$a: the child's environment holds only the cage's variables" "$exp" "$got"
}
BASEV=(HOME USER LOGNAME SHELL PATH TERM TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM LANG TMPDIR)

PD="$WORK/proj"; mkdir -p "$PD/.git/hooks"; : >"$PD/.git/config"
mk codex "$PD" || { cat "$WORK/build.log"; echo "zt: cage_build failed for a plain DIR (codex)"; exit 2; }
eval "$(grep -m1 '^REAL=' "$W")"   # the wrapper's own values: DIR DRE CT RH AUTH CFGRO HOOKS ...
: >"$CFGRO"                        # made before the cage by the wrapper's own seeding in real use

echo "== profile loads / fails closed =="
chk "profile loads through the wrapper" OK "$(cg -c 'echo OK')"
# shellcheck disable=SC2153 # DIR comes from the eval of the wrapper's assignments above.
D=(-D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$AUTH" -D AGENT_CFG_RO="$CFGRO"
  -D LOCK_RE="${LRE:-}" -D CAGE_ROOT="${CT%/*}" -D TTY="$CT/.notty" -D CAGE_SECRETS="$SEC")
chk "fail closed: missing DIR_RE" 65 "$(/usr/bin/sandbox-exec "${D[@]:0:2}" "${D[@]:4}" -f "$PROFILE" /usr/bin/true >/dev/null 2>&1; echo $?)"
chk "fail closed: missing DIR" 65 "$(/usr/bin/sandbox-exec "${D[@]:2}" -f "$PROFILE" /usr/bin/true >/dev/null 2>&1; echo $?)"
chk "fail closed: missing LOCK_RE" 65 "$(/usr/bin/sandbox-exec "${D[@]:0:12}" "${D[@]:14}" -f "$PROFILE" /usr/bin/true >/dev/null 2>&1; echo $?)"
chk "fail closed: missing CAGE_ROOT" 65 "$(/usr/bin/sandbox-exec "${D[@]:0:14}" "${D[@]:16}" -f "$PROFILE" /usr/bin/true >/dev/null 2>&1; echo $?)"
chk "fail closed: missing TTY" 65 "$(/usr/bin/sandbox-exec "${D[@]:0:16}" "${D[@]:18}" -f "$PROFILE" /usr/bin/true >/dev/null 2>&1; echo $?)"
chk "fail closed: missing CAGE_SECRETS" 65 "$(/usr/bin/sandbox-exec "${D[@]:0:18}" -f "$PROFILE" /usr/bin/true >/dev/null 2>&1; echo $?)"
chk "fail closed: empty AGENT_BIN_DIR" nonzero "$(/usr/bin/sandbox-exec "${D[@]}" -D AGENT_BIN_DIR= -f "$PROFILE" /usr/bin/true >/dev/null 2>&1 && echo zero || echo nonzero)"
chk "fail closed: empty HOOKSPATH" nonzero "$(/usr/bin/sandbox-exec "${D[@]}" -D HOOKSPATH= -f "$PROFILE" /usr/bin/true >/dev/null 2>&1 && echo zero || echo nonzero)"

echo "== environment: only the cage's own variables =="
env_is codex "${BASEV[@]}" CODEX_HOME
# shellcheck disable=SC2016  # the child's shell expands it
chk "codex: CODEX_HOME is the cage's" "$CT/codex-home" "$(cg -c 'printf %s "$CODEX_HOME"')"
# shellcheck disable=SC2016  # the child's shell expands it
chk "codex: HOME is the real (fixture) home" "$RH" "$(cg -c 'printf %s "$HOME"')"

echo "== writes: only DIR and the cage temp =="
want w ALLOW "$DIR/src.txt" "$CT/state.json"
want w DENY "$RH/.rex-cage-zt-probe" "/tmp/.rex-cage-zt-probe" "$OUT/probe" "$CT/bin/codex" "$CFGRO"
chk "symlink-out then write" DENY "$(cg -c "( ln -s $(q "$OUT/sl") $(q "$DIR/sl"); echo x > $(q "$DIR/sl") ) 2>/dev/null; [ -f $(q "$OUT/sl") ] && echo ALLOW || echo DENY")"
chk "rename DIR->outside" DENY "$(cg -c "( echo x > $(q "$DIR/mv"); mv $(q "$DIR/mv") $(q "$OUT/mv") ) 2>/dev/null && echo ALLOW || echo DENY")"
chk "hardlink DIR->outside" DENY "$(cg -c "( echo x > $(q "$DIR/hl"); ln $(q "$DIR/hl") $(q "$OUT/hl") ) 2>/dev/null && echo ALLOW || echo DENY")"
chk "hardlink a locked DIR file into the cage temp" DENY "$(cg -c "ln $(q "$DIR/.git/config") $(q "$CT/hl") 2>/dev/null && echo ALLOW || echo DENY")"

echo "== reads: secrets and agent homes denied, AGENT_AUTH re-opened =="
chk "codex: AGENT_AUTH is HOME/.codex/auth.json" "$RH/.codex/auth.json" "$AUTH"
want r READ "$AUTH" "$RH/notes.txt" "$RH/.gitconfig" "$RH/.config/git/config" "$RH/Library/Application Support/SomeApp/x"
want r DENY "$RH/.codex/other" "$RH/.codex" "$RH/.ssh" "$RH/.ssh/id_x" "$RH/.aws/credentials" "$RH/.gnupg/x" "$RH/.netrc" \
  "$RH/$CS/claude.env" "$RH/$CS/claude-one.env" "$RH/$CS/claude-two.env" "$RH/Library/Keychains/login.keychain-db" \
  "$RH/Library/Messages/chat.db" "$RH/Library/Mail/x" \
  "$RH/.config/gh/hosts.yml" "$RH/.config/rclone/rclone.conf" "$RH/.config/gcloud/credentials.db" \
  "$RH/.config/anthropic/x" "$RH/.config/configstore/firebase-tools.json" "$RH/.config/some-cli/token" \
  "$RH/.cloudflared/cert.pem" "$RH/.mcp-auth/x" "$RH/.supabase/access-token" \
  "$RH/.zsh_history" "$RH/.bash_history" "$RH/.zsh_sessions/x" "$RH/.claude.json" "$RH/.claude.json.backup" \
  "$RH/.claude.json.bak-trust" "$RH/.claude/x" "$RH/.claude-work/x" \
  "$RH/.claude-server-commander/x" "$RH/.codex-alt/x" "$RH/.grok/auth.json" "$RH/.grokbot/x" \
  "$RH/.gemini/x" "$RH/.cursor/x" "$RH/.copilot/x" "$RH/.hermes/x" "$RH/.pi/x" "$RH/.mastracode/x" \
  "$RH/Library/Application Support/Claude/x" "$RH/Library/Application Support/Codex/x" \
  "$RH/Library/Application Support/com.openai.codex/x" "$RH/Library/Application Support/Muse/x"
CT5="/private/tmp/claude-$(id -u)"
if [ ! -e "$CT5" ] && [ ! -L "$CT5" ] && (umask 077; mkdir "$CT5" 2>/dev/null); then SCRATCH_ROOT=$CT5; fi
if [ -d "$CT5" ] && [ ! -L "$CT5" ] && [ -O "$CT5" ] && SCRATCH_FIXTURE=$(mktemp -d "$CT5/rex-cage-zt.XXXXXX"); then
  printf 'other session\n' >"$SCRATCH_FIXTURE/f"; want r DENY "$SCRATCH_FIXTURE/f"
else test_skip "scratchpad check requires a private fixture in $CT5"; fi

echo "== the pty: own tty, /dev/tty and other ptys are writable (sub-ptys must work) =="
# The wrapper looks up its own tty (stdin) at run time, so this runs it on a pty of its own (python's pty.fork) next to
# a second pty it must not write: the stand-in for another pane. /dev/tty (the controlling terminal) stays open.
if ! command -v python3 >/dev/null 2>&1; then
  test_skip 'cage pty checks require python3'
else
  mk codex "$PD" || bad "pty: cage_build failed"
  pty_status=0
  # shellcheck disable=SC2016  # the child's shell expands it
  ptyout=$(python3 -I -c '
import errno, os, pty, sys
w, cwd = sys.argv[1], sys.argv[2]
try:
    m2, s2 = pty.openpty()
    other = os.ttyname(s2)
    open(other, "w").close()
    pid, fd = pty.fork()
except OSError as exc:
    print(f"PRECONDITION: {exc}", file=sys.stderr)
    sys.exit(77)
prog = "own=$(tty); echo OWN=$own; (: >\"$own\") 2>/dev/null && echo OWN=ALLOW || echo OWN=DENY; (: >\"$1\") 2>/dev/null && echo OTHER=ALLOW || echo OTHER=DENY; (: >/dev/tty) 2>/dev/null && echo DEVTTY=ALLOW || echo DEVTTY=DENY"
if pid == 0:
    os.chdir(cwd)
    os.execv(w, [w, "-c", prog, "sh", other])
out = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError as exc:
        if exc.errno != errno.EIO:
            raise
        break
    if not d:
        break
    out += d
_, status = os.waitpid(pid, 0)
print(out.decode(errors="replace").replace("\r", ""))
sys.exit(1 if status else 0)
' "$W" "$CWD" 2>&1) || pty_status=$?
  pty_detail=$(printf '%s\n' "$ptyout" | tail -1)
  if [ "$pty_status" -eq 77 ] && [[ "$pty_detail" == PRECONDITION:* ]]; then
    test_skip "cage pty checks: $pty_detail"
  elif [ "$pty_status" -ne 0 ]; then
    bad "pty fixture exited $pty_status: $pty_detail"
  else
    chk "pty: write to the child's own tty" ALLOW "$(sed -nE 's/^OWN=(ALLOW|DENY)$/\1/p' <<<"$ptyout")"
    chk "pty: write to a second pty (sub-pty case)" ALLOW "$(sed -nE 's/^OTHER=(ALLOW|DENY)$/\1/p' <<<"$ptyout")"
    chk "pty: write to /dev/tty" ALLOW "$(sed -nE 's/^DEVTTY=(ALLOW|DENY)$/\1/p' <<<"$ptyout")"
  fi
fi

echo "== other repos under ~/Repos are unreadable, DIR's own is not =="
# DIR = ~/Repos/zt-proj; ~/Repos/other (fixture), a repo whose name starts like DIR's, and one below DIR's name as a
# prefix must stay unreadable; DIR (and a repo inside it) readable; stat still works so a walk up from DIR does.
RD="$FH/Repos/zt-proj"; mkdir -p "$RD/sub/.git" "$FH/Repos/zt-proj-evil" "$FH/Repos/zt"
printf 'mine\n' >"$RD/f.txt"; printf 'mine\n' >"$RD/sub/.git/HEAD"; printf 'evil\n' >"$FH/Repos/zt-proj-evil/f.txt"; printf 'z\n' >"$FH/Repos/zt/f.txt"
mk codex "$RD" || bad "Repos: cage_build failed"
want r READ "$RD/f.txt" "$RD" "$RD/sub/.git/HEAD"
want r DENY "$RH/Repos/other/x" "$RH/Repos/other" "$RH/Repos" "$FH/Repos/zt-proj-evil/f.txt" "$FH/Repos/zt/f.txt"
chk "Repos: stat of ~/Repos and of another repo still works" OK "$(cg -c "[ -d $(q "$RH/Repos") ] && [ -f $(q "$RH/Repos/other/x") ] && echo OK || echo NO")"
chk "Repos: cat of another repo's file" DENY "$(cg -c "cat $(q "$RH/Repos/other/x") >/dev/null 2>&1 && echo ALLOW || echo DENY")"
want w ALLOW "$RD/new.txt"
# A DIR outside ~/Repos reads none of it, and a symlink in DIR to another repo leads nowhere.
ln -s "$FH/Repos/other" "$RD/link-to-other"
chk "Repos: a link in DIR to another repo" DENY "$(cg -c "cat $(q "$RD/link-to-other/x") >/dev/null 2>&1 && echo ALLOW || echo DENY")"
rm -f "$RD/link-to-other"
mk codex "$PD" || bad "Repos: cage_build failed (DIR outside ~/Repos)"
want r DENY "$RH/Repos/other/x" "$FH/Repos/zt-proj/f.txt"

echo "== a child can't read a sibling's cage home =="
# Two cages built the way launch builds them, under one cage root: each child reads its own home, never the other's.
mk codex "$PD" || bad "sibling: cage_build failed (first)"
CT1=$CT; printf 'zt-sibling-secret\n' >"$CT1/history.txt"; mkdir -p "$CT1/home/sub"; printf 'x\n' >"$CT1/home/sub/f"
mk claude "$PD" || bad "sibling: cage_build failed (second)"
CT2=$CT; printf 'own\n' >"$CT2/own.txt"
chk "sibling: two cage homes under one root" "${CT1%/*}" "${CT2%/*}"
want r READ "$CT2/own.txt" "$CT2"
want r DENY "$CT1/history.txt" "$CT1/home/sub/f" "$CT1" "$CT1/home" "${CT1%/*}"
chk "sibling: the first child can't list the root to find the second" DENY "$(cg -c "ls $(q "${CT1%/*}") >/dev/null 2>&1 && echo ALLOW || echo DENY")"
want w DENY "$CT1/planted"
mk codex "$PD" || bad "sibling: cage_build failed (third)"
want r DENY "$CT1/history.txt" "$CT2/own.txt"

echo "== DIR auto-run plant locks =="
LOCKS=".git/hooks/post-commit .git/config .git/config.worktree .envrc .mcp.json .claude/x .codex/x .gemini/x .grok/x .cursor/x
  .zed/x .vscode/x .idea/x .husky/pre-commit .githooks/pre-commit sub/.envrc sub/.husky/x sub/.git/hooks/x
  .agents/skills/x/SKILL.md .agents/rules.md .agents sub/.agents/x"
PLAIN="src/app.py README.md .gitignore .github/workflows/ci.yml package.json sub/x.txt"
# locks_hold LABEL DIR: in the cage built for DIR, every lock is write-denied and every ordinary write allowed.
locks_hold() {
  local d="$2" l got a=() p=()
  mkdir -p "$d/.git/hooks"; : >"$d/.git/config"
  mk codex "$d" || { bad "$1: cage_build failed ($(tr '\n' ' ' <"$WORK/build.log"))"; return; }
  for l in $LOCKS; do a+=("$d/$l"); done
  for l in $PLAIN; do p+=("$d/$l"); done
  got=$(cg "$WORK/bin/w" "${a[@]}" | grep -v '^DENY ')
  if [ -z "$got" ]; then ok "$1: all ${#a[@]} locks hold"; else bad "$1: not denied: $(tr '\n' ' ' <<<"$got")"; fi
  chk "$1: ordinary writes allowed" "${#p[@]}" "$(cg "$WORK/bin/w" "${p[@]}" | grep -c '^ALLOW ')"
}
locks_hold "plain DIR" "$PD"
# shellcheck disable=SC1003 # The lone '\' is a literal backslash directory-name character.
for c in '(' ')' '[' ']' '{' '}' '+' '?' '*' '|' '^' '$' '\' '.' ' ' ':~/'; do
  md="$WORK/m/pay${c}x"; mkdir -p "$md"; locks_hold "DIR holding '$c'" "$(cd "$md" && pwd -P)"
done
# shellcheck disable=SC2016 # These bytes are literal directory-name characters.
adversarial="$WORK/"'proj d'"'"'q $(id) `id` [a]+(b) "c" x:~/y'
locks_hold "adversarial DIR" "$adversarial"

echo "== a repo's core.hooksPath inside DIR is locked =="
# hooks LABEL HOOKSPATH [SUBDIR]: a repo under the fixture home whose core.hooksPath is HOOKSPATH, caged in its top (or
# in SUBDIR below it); a hook planted where git will look for it must be denied.
hooks() {
  local top="$FH/hk-$1" dir hp
  mkdir -p "$top/${3:-}"; { git -C "$top" init -q && git -C "$top" config core.hooksPath "$2"; } || { bad "hooks $1: git failed"; return; }
  dir=$(cd "$top/${3:-}" && pwd -P)
  mk codex "$dir" || { bad "hooks $1: cage_build failed"; return; }
  hp=$(git -C "$top" config --type=path --get core.hooksPath); case "$hp" in /*) ;; *) hp="$top/$hp" ;; esac
  chk "hooks $1 ($2): plant $hp/pre-commit" DENY "$(cg "$WORK/bin/w" "$hp/pre-commit" | cut -d' ' -f1)"
}
if command -v git >/dev/null 2>&1; then
  mkdir -p "$FH/hk-existing/tools/hooks"
  hooks existing tools/hooks
  hooks missing tools/hooks
  hooks dot-missing .hooks
  hooks subdir-dir app/hooks app
  # shellcheck disable=SC2088  # the literal "~/" is the point: git expands it, not the shell
  hooks tilde "~/hk-tilde/tools/hooks"
  # bash 3.2's printf %q leaves a "~" after ":" bare, which the wrapper's assignment line would expand.
  mkdir -p "$FH/hk-colon-tilde/tools/x:~/hooks"
  hooks colon-tilde "tools/x:~/hooks"
  # shellcheck disable=SC2016
  hooks adversarial 'tools/hook'"'"'s $dir'
else test_skip 'core.hooksPath checks require git'; fi

echo "== a per-task clone can commit inside the cage =="
CS="$WORK/clone-source"; CD="$WORK/clone-task"
mkdir -p "$CS"
{ git -C "$CS" init -q && printf 'source\n' >"$CS/original.txt" &&
  git -C "$CS" add original.txt && git -C "$CS" -c core.hooksPath=/dev/null commit -qm source; } || bad "clone source fixture"
source_head=$(git -C "$CS" rev-parse HEAD)
clone_out=$(REX_ORCHESTRATOR_REX_BIN_DIR="$WORK/bin" REX_ORCHESTRATOR_STATE_DIR="$STATE_DIR" "$BASH" "$SCRIPT" clone "$CS" "$CD" -b cage-task 2>"$WORK/clone.log")
chk "clone prints DEST" "$CD" "$clone_out"
chk "clone keeps .git inside DEST" yes "$([ -d "$CD/.git" ] && echo yes || echo no)"
chk "clone creates requested branch" cage-task "$(git -C "$CD" symbolic-ref --short HEAD 2>/dev/null)"
if mk codex "$CD"; then
  chk "clone: git add and git commit succeed in cage" COMMITTED "$(cg -c 'printf "task\n" > task.txt && git add task.txt && git -c core.hooksPath=/dev/null commit -qm task && echo COMMITTED')"
else bad "clone: cage_build failed"; fi
chk "clone leaves source HEAD unchanged" "$source_head" "$(git -C "$CS" rev-parse HEAD)"
chk "clone leaves source files unchanged" clean "$(git -C "$CS" status --porcelain | { read -r line && echo changed || echo clean; })"
chk "clone commit stays in destination" 2 "$(git -C "$CD" rev-list --count HEAD 2>/dev/null)"

echo "== no signals, local services or app launches out of the cage =="
sleep 30 & SLEEPER=$!; disown
chk "kill -0 a process outside the cage" DENY "$(cg -c "kill -0 $SLEEPER 2>/dev/null && echo ALLOW || echo DENY")"
if ! command -v python3 >/dev/null 2>&1 || ! command -v nc >/dev/null 2>&1; then
  test_skip 'cage network checks require python3 and nc'
else
  # A loopback port and a unix socket that accept and close each connection, so nc returns at once.
  python3 -I -c 'import errno, select, socket, sys, time
try:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
    u = socket.socket(socket.AF_UNIX); u.bind(sys.argv[1]); u.listen(5)
except OSError as exc:
    if exc.errno not in (errno.EACCES, errno.EPERM, errno.EAFNOSUPPORT,
                         errno.EPROTONOSUPPORT):
        raise
    print(f"PRECONDITION: {exc}", file=sys.stderr)
    sys.exit(77)
print(s.getsockname()[1], flush=True)
end = time.time() + 60
while time.time() < end:
    for x in select.select([s, u], [], [], 1)[0]: x.accept()[0].close()' "$WORK/zt.sock" >"$WORK/port" 2>"$WORK/listener.err" & LISTENER=$!; disown
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$WORK/port" ] || ! kill -0 "$LISTENER" 2>/dev/null; then break; fi
    sleep 0.2
  done
  port=$(cat "$WORK/port")
  # Only a listener the same commands reach uncaged makes a denial mean something.
  if [ -n "$port" ] && nc -z -G 2 127.0.0.1 "$port" >/dev/null 2>&1 && nc -w 2 -U "$WORK/zt.sock" </dev/null >/dev/null 2>&1; then
    chk "connect to a loopback listener (127.0.0.1:$port)" DENY "$(cg -c "nc -z -G 2 127.0.0.1 $port >/dev/null 2>&1 && echo ALLOW || echo DENY")"
    chk "connect to a unix socket outside the cage" DENY "$(cg -c "nc -U $(q "$WORK/zt.sock") </dev/null >/dev/null 2>&1 && echo ALLOW || echo DENY")"
  elif grep -q '^PRECONDITION: ' "$WORK/listener.err" || { [ -n "$port" ] && kill -0 "$LISTENER" 2>/dev/null; }; then
    cat "$WORK/listener.err" >&2
    test_skip 'cage network checks cannot reach the uncaged loopback and Unix socket listeners'
  else
    cat "$WORK/listener.err" >&2
    bad 'cage network listener failed to start'
  fi
fi
chk "exec /usr/bin/open" DENY "$(cg -c '/usr/bin/open -h >/dev/null 2>&1; [ $? -eq 126 ] && echo DENY || echo ALLOW')"
chk "exec /bin/launchctl" DENY "$(cg -c '/bin/launchctl version >/dev/null 2>&1; [ $? -eq 126 ] && echo DENY || echo ALLOW')"

echo "== grok, claude, agy recipes =="
mk grok "$PD" || bad "grok: cage_build failed"
env_is grok "${BASEV[@]}" GROK_HOME GROK_AUTH_PATH GROK_DISABLE_AUTOUPDATER GROK_AUTH_EARLY_INVALIDATION_SECS
# shellcheck disable=SC2016  # the child's shell expands it
chk "grok: HOME is the cage's" "$CT/home" "$(cg -c 'printf %s "$HOME"')"
want r READ "$RH/.grok/auth.json"
want r DENY "$RH/.grok/other" "$RH/.codex/auth.json" "$RH/.ssh/id_x"
want w ALLOW "$CT/home/.grok/session.json" "$DIR/grok.txt"
want w DENY "$CT/bin/grok" "$RH/.grok/auth.json"
# claude with no --account: the alphabetically first account, one.
mk claude "$PD" || bad "claude (dummy cage credentials): cage_build failed"
env_is claude "${BASEV[@]}" ZDOTDIR CLAUDE_CONFIG_DIR CLAUDE_CODE_TMPDIR DISABLE_AUTOUPDATER ENABLE_CLAUDEAI_MCP_SERVERS \
  CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY CLAUDE_CODE_SUBPROCESS_ENV_SCRUB
# shellcheck disable=SC2016  # the child's shell expands it
chk "claude: the session survey is off" 1 "$(cg -c 'printf %s "$CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY"')"
# shellcheck disable=SC2016  # the child's shell expands it
chk "claude: subprocess env scrub is on (its tools do not inherit the OAuth token)" 1 "$(cg -c 'printf %s "$CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"')"
# shellcheck disable=SC2016  # the child's shell expands it
tok() { cg -c 'printf %s "$CLAUDE_CODE_OAUTH_TOKEN"'; }   # the token the caged child got
chk "claude, no --account: the token of the alphabetically first account" zt-dummy-one "$(tok)"
want w DENY "$CT/claude-config/settings.json" "$RH/.claude/x"
want w ALLOW "$CT/claude-config/.claude.json"
want r DENY "$RH/.claude.json" "$RH/$CS/claude.env" "$RH/$CS/claude-one.env" "$RH/$CS/claude-two.env"
# --account (launch's local, read by cage_build) picks the file: the child gets exactly that account's token.
for a in one two; do
  account=$a; mk claude "$PD" || bad "claude --account $a: cage_build failed"
  chk "claude --account $a: the child's token is claude-$a.env's" "zt-dummy-$a" "$(tok)"
done
account=""
# The wrapper loads the chosen claude-<acct>.env outside the cage, on the child's screen: a malformed line must stop it
# without showing that line (the token), and a file that sets no token must stop it too.
holds() { case "$1" in *"$2"*) echo "$3" ;; *) echo "$4" ;; esac; }   # holds TEXT PART IF-SO IF-NOT
for a in one two; do
  account=$a
  for bad_env in 'zt-raw-secret-4711' 'OTHER=zt-raw-secret-4711'; do
    printf '%s\n' "$bad_env" >"$CAGE_SECRETS/claude-$a.env"
    mk claude "$PD" || bad "claude-$a.env ($bad_env): cage_build failed"
    out=$(cg -c 'echo STARTED')
    chk "claude-$a.env [$bad_env]: the wrapper stops" stopped "$(holds "$out" STARTED started stopped)"
    chk "claude-$a.env [$bad_env]: its content never shows" hidden "$(holds "$out" 4711 shown hidden)"
  done
  printf 'export CLAUDE_CODE_OAUTH_TOKEN=zt-dummy-%s\n' "$a" >"$CAGE_SECRETS/claude-$a.env"
done
# The claude wrapper names a credential file that sets no token; a cage-secrets folder with terminal controls in its
# name must show escaped, not raw. cage-cleanup.sh's notes use the same shell escaping.
ESC=$(printf '\033') SAVED_SECRETS=$CAGE_SECRETS
CAGE_SECRETS="$WORK/sec${ESC}]0;owned$(printf '\007')"; mkdir -p "$CAGE_SECRETS"
printf 'OTHER=1\n' >"$CAGE_SECRETS/claude-one.env"
account=one
if mk claude "$PD"; then
  out=$(cg -c 'echo STARTED')
  chk "claude wrapper: a credential path with controls is shown escaped" yes \
    "$(printf '%s' "$out" | grep -qF 'sec\x1B]0;owned\x07/claude-one.env sets no' && echo yes || echo no)"
  chk "claude wrapper: no raw control printed" 0 "$(printf '%s' "$out" | tr -d '\n' | LC_ALL=C grep -c '[[:cntrl:]]')"
else bad "claude wrapper with a control in CAGE_SECRETS: cage_build failed ($(tr '\n' ' ' <"$WORK/build.log"))"; fi
CAGE_SECRETS=$SAVED_SECRETS
# shellcheck disable=SC2016 # The child shell expands its own arguments.
chk "cage-cleanup.sh escapes controls" 'x\x1B[31my\x09z\w' \
  "$(/bin/bash -c '. "$1"; rex_term_text "$2"' sh "$SDIR/cage-cleanup.sh" "x${ESC}[31my$(printf '\t')z\w")"
# shellcheck disable=SC2034  # read by cage_build, as launch's local
account=""
CAGE_AGY_HOME="$WORK/agy-home"   # the script's global (REX_ORCHESTRATOR_CAGE_AGY_HOME's value), read by cage_build
mk agy "$PD" || bad "agy (dummy agy home): cage_build failed"
env_is agy "${BASEV[@]}"
# shellcheck disable=SC2016  # the child's shell expands it
chk "agy: HOME is the cage's copy of its home" "$CT/home" "$(cg -c 'printf %s "$HOME"')"
want w ALLOW "$CT/home/.gemini/x"
# shellcheck disable=SC2034  # read by later cage_build calls
CAGE_AGY_HOME="$WORK/no-agy-home"

echo "== a standalone codex release under the agent home =="
# Runs only with a C compiler: the cage runs no script found on PATH under an agent's name but a Node one, so the
# stand-in for the release's codex is compiled (tests/cage/argprobe.c drops the recipe's flags and runs sh, like PROBE).
standalone_checks() {
# The layout codex's standalone installer makes: releases/<version>/ holding bin/codex and its helpers, a current link
# to the release in use, and ~/.local/bin/codex linking through it.
SA="$FH/.codex/packages/standalone"; REL="$SA/releases/9.9.9-zt"; OLD="$SA/releases/9.9.8-zt"
mkdir -p "$REL/bin" "$REL/codex-path" "$OLD/bin" "$FH/.local/bin" "$FH/.codex/sessions" "$FH/.codex/log" "$FH/.codex/bin"
cp "$ARGPROBE" "$REL/bin/codex"; cp "$ARGPROBE" "$OLD/bin/codex"; cp "$ARGPROBE" "$FH/.codex/bin/codex"
printf 'helper\n' >"$REL/codex-path/rg"
# A Mach-O in each release too: the kernel refuses to exec one the cage can't read, before any interpreter runs.
cp /usr/bin/true "$REL/bin/helper"; cp /usr/bin/true "$OLD/bin/helper"; cp /usr/bin/true "$FH/.codex/bin/helper"
for p in config.toml history.jsonl sessions/s.jsonl log/codex.log; do printf 'fixture\n' >"$FH/.codex/$p"; done
ln -s "$REL" "$SA/current"; ln -s "$SA/current/bin/codex" "$FH/.local/bin/codex"
# A user's shim: a Bash script first on PATH that would look for the real codex and exec it. It leaves a mark if run.
SHIM_MARK="$WORK/shim-ran"; mkdir -p "$WORK/shims" "$WORK/tools"
printf '%s\n' '#!/bin/bash' "# a user's codex shim" ": >$(q "$SHIM_MARK")" \
  "echo \"codex: the real codex isn't on PATH\" >&2; exit 127" >"$WORK/shims/codex"
chmod 755 "$WORK/shims/codex"; ln -s "$(command -v luajit)" "$WORK/tools/luajit"
# Shims in every other form the cage must not take for codex: no #! line (execvp hands it to sh), env with options
# taking a value, -S separate, quoted or joined, assignments, and fish, Python, Perl and Ruby scripts. Each would
# leave the same mark. A Node script is what an npm install runs, so it is taken.
SHIMS=""
for form in 'none' '#!/usr/bin/env -u NAME sh' '#!/usr/bin/env -P /usr/bin bash' "#!/usr/bin/env -S 'bash -e'" \
  '#!/usr/bin/env -Ssh' '#!/usr/bin/env A=1 B=2 bash' '#!/usr/bin/env fish' '#!/usr/bin/python3' '#!/usr/bin/perl' \
  '#!/usr/bin/env ruby'; do
  d=$WORK/shims-$(printf '%s' "$form" | tr -c 'A-Za-z0-9' _); mkdir -p "$d"
  if [ "$form" = none ]; then printf ': >%s\n' "$(q "$SHIM_MARK")" >"$d/codex"
  else printf '%s\n%s\n' "$form" "# would mark $SHIM_MARK" >"$d/codex"; fi
  chmod 755 "$d/codex"; SHIMS="$SHIMS$d:"
done
mkdir -p "$WORK/nodebin"; printf '#!/usr/bin/env node\n' >"$WORK/nodebin/codex"; chmod 755 "$WORK/nodebin/codex"
# sa_build PATH [VAR=VALUE...]: build a codex cage for PD as launch does for a bare --agent codex, with only PATH (and
# the variables) changed; sets W, CT and CWD on success and SA_RC to the build's exit code, its notes in build.log.
sa_build() {
  local path=$1; shift
  SA_RC=0
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  env PATH="$path" "$@" cage_agent=codex "$BASH" -p -c '. "$1"; shift; cage_build "$@" && printf "%s\n" "$cage_tmp"' sa \
    "$HERE/build.inc.sh" codex codex "$PD" >"$WORK/sa.out" 2>"$WORK/build.log" || SA_RC=$?
  [ "$SA_RC" -eq 0 ] || return "$SA_RC"
  CT=$(cat "$WORK/sa.out") W="$CT/bin/codex" CWD=$PD
}
# shellcheck disable=SC2034 # Read by cage_build in sa_build's child shell.
export CAGE_PROFILE CAGE_TPL CAGE_SECRETS CAGE_AGY_HOME ASSETS SCRIPT_DIR STATE_DIR account
LINKED="$FH/.local/bin:$WORK/tools:/usr/bin:/bin"
if sa_build "$WORK/shims:$LINKED"; then
  chk "standalone: the cage runs the release's physical path" "REAL='$REL/bin/codex'" "$(grep -m1 -o "^REAL='[^']*'" "$W")"
  chk "standalone: AGENT_BIN_DIR is that release folder" "BINDIR='$REL'" "$(grep -m1 -o "BINDIR='[^']*'" "$W")"
  chk "standalone: launch says it skipped the shim" yes \
    "$(grep -qF "skipped $WORK/shims/codex: a script" "$WORK/build.log" && echo yes || echo no)"
  chk "standalone: the release codex starts in the cage" RAN "$(cg -c 'echo RAN')"
  want r READ "$REL/bin/codex" "$REL/codex-path/rg" "$REL"
  want r DENY "$FH/.codex/config.toml" "$FH/.codex/history.jsonl" "$FH/.codex/sessions/s.jsonl" \
    "$FH/.codex/log/codex.log" "$OLD/bin/codex" "$OLD" "$SA/releases" "$SA" "$FH/.codex/bin/codex"
  want w DENY "$REL/bin/codex" "$REL/planted" "$OLD/planted" "$FH/.codex/planted"
  chk "standalone: a Mach-O in the release runs" RAN "$(cg -c "$(q "$REL/bin/helper") && echo RAN || echo DENY")"
  chk "standalone: a Mach-O in a sibling release does not" DENY "$(cg -c "$(q "$OLD/bin/helper") 2>/dev/null && echo RAN || echo DENY")"
  chk "standalone: a Mach-O elsewhere in HOME/.codex does not" DENY \
    "$(cg -c "$(q "$FH/.codex/bin/helper") 2>/dev/null && echo RAN || echo DENY")"
  chk "standalone: a sibling release does not run" DENY "$(cg -c "$(q "$OLD/bin/codex") -c 'echo RAN' 2>/dev/null || echo DENY")"
  chk "standalone: the link through current does not run" DENY \
    "$(cg -c "$(q "$FH/.local/bin/codex") -c 'echo RAN' 2>/dev/null || echo DENY")"
else bad "standalone: cage_build failed with a shim first on PATH (rc $SA_RC: $(tr '\n' ' ' <"$WORK/build.log"))"; fi
if sa_build "$SHIMS$LINKED"; then
  chk "every script form is skipped for the release" "REAL='$REL/bin/codex'" "$(grep -m1 -o "^REAL='[^']*'" "$W")"
  chk "the note names all ten skipped scripts" 10 "$(grep -o "$WORK/shims-[^ ,:]*/codex" "$WORK/build.log" | sort -u | wc -l | tr -d ' ')"
else bad "script forms: cage_build failed (rc $SA_RC: $(tr '\n' ' ' <"$WORK/build.log"))"; fi
if sa_build "$WORK/shims:$WORK/nodebin:$LINKED"; then
  chk "a Node script on PATH is taken as the agent" "REAL='$WORK/nodebin/codex'" "$(grep -m1 -o "^REAL='[^']*'" "$W")"
else bad "Node script: cage_build failed (rc $SA_RC: $(tr '\n' ' ' <"$WORK/build.log"))"; fi
# With CODEX_HOME elsewhere AGENT_AUTH is that home's auth.json, so only the release folder could open
# HOME/.codex/auth.json: it must stay unreadable, and, made executable, must not run.
CXH="$WORK/codex-alt-home"; mkdir -p "$CXH"; printf 'fixture\n' >"$CXH/auth.json"
printf '#!/bin/sh\necho RAN\n' >"$FH/.codex/auth.json"; chmod 755 "$FH/.codex/auth.json"
if sa_build "$LINKED" CODEX_HOME="$CXH"; then
  chk "standalone, CODEX_HOME elsewhere: AGENT_AUTH is that home's" "AUTH='$CXH/auth.json'" "$(grep -m1 -o "AUTH='[^']*'" "$W")"
  want r DENY "$FH/.codex/auth.json"
  chk "standalone: HOME/.codex/auth.json does not run" DENY "$(cg -c "$(q "$FH/.codex/auth.json") 2>/dev/null || echo DENY")"
  chk "standalone, CODEX_HOME elsewhere: the release codex starts" RAN "$(cg -c 'echo RAN')"
else bad "standalone: cage_build failed with CODEX_HOME elsewhere (rc $SA_RC: $(tr '\n' ' ' <"$WORK/build.log"))"; fi
printf 'fixture\n' >"$FH/.codex/auth.json"; chmod 644 "$FH/.codex/auth.json"
sa_build "$WORK/shims:$WORK/tools:/usr/bin:/bin" || :
chk "shims only on PATH: launch refuses" 2 "$SA_RC"
chk "shims only on PATH: the refusal names the override" yes \
  "$(grep -qF 'set REX_ORCHESTRATOR_CAGE_CODEX_BIN to the real codex executable' "$WORK/build.log" && echo yes || echo no)"
if sa_build "$WORK/shims:$WORK/tools:/usr/bin:/bin" REX_ORCHESTRATOR_CAGE_CODEX_BIN="$FH/.local/bin/codex"; then
  chk "REX_ORCHESTRATOR_CAGE_CODEX_BIN picks the executable" "BINDIR='$REL'" "$(grep -m1 -o "BINDIR='[^']*'" "$W")"
  chk "REX_ORCHESTRATOR_CAGE_CODEX_BIN: codex starts" RAN "$(cg -c 'echo RAN')"
else bad "REX_ORCHESTRATOR_CAGE_CODEX_BIN: cage_build failed (rc $SA_RC: $(tr '\n' ' ' <"$WORK/build.log"))"; fi
sa_build "$LINKED" REX_ORCHESTRATOR_CAGE_CODEX_BIN=.local/bin/codex || :
chk "a relative REX_ORCHESTRATOR_CAGE_CODEX_BIN is refused" 2 "$SA_RC"
chk "the shim never ran" absent "$([ -e "$SHIM_MARK" ] && echo ran || echo absent)"
# Given as a path, --agent is used as given: the link works, an executable elsewhere under an agent home is refused.
if cage_build codex "$FH/.local/bin/codex" "$PD" >"$WORK/build.log" 2>&1; then
  W=$cage_wrapper CT=$cage_tmp CWD=$PD
  chk "--agent HOME/.local/bin/codex: the release starts" RAN "$(cg -c 'echo RAN')"
else bad "--agent HOME/.local/bin/codex: cage_build failed ($(tr '\n' ' ' <"$WORK/build.log"))"; fi
rc=0; cage_build codex "$FH/.codex/bin/codex" "$PD" >/dev/null 2>"$WORK/build.log" || rc=$?
chk "--agent HOME/.codex/bin/codex, outside a release: refused" 2 "$rc"
# An executable outside the agent homes reached through a link inside one (as a file, then as a folder): the cage
# can't follow that link, so it runs the physical path and says so.
mkdir -p "$WORK/opt"; cp "$REL/bin/codex" "$WORK/opt/codex"
ln -s "$WORK/opt/codex" "$FH/.codex/bin/codex-link"; ln -s "$FH/.codex/bin/codex-link" "$FH/.local/bin/codex-chain"
ln -s "$WORK/opt" "$FH/.codex/optlink"; ln -s "$FH/.codex/optlink/codex" "$FH/.local/bin/codex-dirchain"
for p in codex-chain codex-dirchain; do
  if cage_build codex "$FH/.local/bin/$p" "$PD" >/dev/null 2>"$WORK/build.log"; then
    W=$cage_wrapper CT=$cage_tmp CWD=$PD
    chk "$p through a link in HOME/.codex: the cage runs the physical path" "REAL='$WORK/opt/codex'" \
      "$(grep -m1 -o "^REAL='[^']*'" "$W")"
    chk "$p: nothing under HOME/.codex is opened" "BINDIR='$CT'" "$(grep -m1 -o "BINDIR='[^']*'" "$W")"
    chk "$p: launch says why" yes "$(grep -qF "which the cage can't follow; running $WORK/opt/codex" "$WORK/build.log" && echo yes || echo no)"
    chk "$p: it starts in the cage" RAN "$(cg -c 'echo RAN')"
  else bad "$p: cage_build failed ($(tr '\n' ' ' <"$WORK/build.log"))"; fi
done
# Agent homes are matched without regard to case, as the home volume and the cage do: a link spelled ~/.CODEX, a HOME
# spelled in another case than the disk, and an executable in a home whose on-disk name is ~/.Claude-zt.
ln -s "$FH/.CODEX/bin/codex-link" "$FH/.local/bin/codex-case"
if cage_build codex "$FH/.local/bin/codex-case" "$PD" >/dev/null 2>"$WORK/build.log"; then
  W=$cage_wrapper CT=$cage_tmp CWD=$PD
  chk "case: a link spelled ~/.CODEX is inside the agent home" "REAL='$WORK/opt/codex'" "$(grep -m1 -o "^REAL='[^']*'" "$W")"
  chk "case: it starts in the cage" RAN "$(cg -c 'echo RAN')"
else bad "case: cage_build failed for a link spelled ~/.CODEX ($(tr '\n' ' ' <"$WORK/build.log"))"; fi
if sa_build "$LINKED" HOME="${FH%/home}/HOME"; then
  chk "case: HOME spelled otherwise still finds the release" "BINDIR='$REL'" "$(grep -m1 -o "BINDIR='[^']*'" "$W")"
  chk "case: HOME spelled otherwise, the release starts" RAN "$(cg -c 'echo RAN')"
  # The profile's own rules ignore case on this volume: case-variant spellings of denied paths stay denied.
  want r DENY "$FH/.CODEX/config.toml" "$FH/.Codex/history.jsonl" "$FH/.GROK/config.toml" "$FH/.SSH/id_x" \
    "$FH/.CODEX/packages/standalone/releases/9.9.8-ZT/bin/codex"
  want w DENY "$FH/.CODEX/planted" "$FH/.Local/Bin/planted"
else bad "case: cage_build failed with HOME spelled otherwise (rc $SA_RC: $(tr '\n' ' ' <"$WORK/build.log"))"; fi
mkdir -p "$FH/.Claude-zt"; cp "$ARGPROBE" "$FH/.Claude-zt/codex"
rc=0; cage_build codex "$FH/.Claude-zt/codex" "$PD" >/dev/null 2>"$WORK/build.log" || rc=$?
chk "case: an executable under ~/.Claude-zt is refused" 2 "$rc"
# Paths in launch's notes and refusals are escaped: a shim folder, a link and an executable with terminal controls in
# their names show as \x1B and \x09, never as raw bytes.
ESC=$(printf '\033') TAB=$(printf '\t')
mkdir -p "$WORK/shim${ESC}[31mred"; cp "$WORK/shims/codex" "$WORK/shim${ESC}[31mred/codex"
no_raw() { if LC_ALL=C grep -q "[$ESC$TAB]" "$WORK/build.log"; then echo raw; else echo escaped; fi; }
if sa_build "$WORK/shim${ESC}[31mred:$LINKED"; then
  chk "escape: the skipped shim's path is escaped" yes "$(grep -qF 'shim\x1B[31mred/codex' "$WORK/build.log" && echo yes || echo no)"
  chk "escape: no raw control in the skip note" escaped "$(no_raw)"
else bad "escape: cage_build failed with an escaped shim path (rc $SA_RC)"; fi
ln -s "$WORK/opt/codex" "$FH/.codex/bin/tab${TAB}link"; ln -s "$FH/.codex/bin/tab${TAB}link" "$FH/.local/bin/codex-tab"
if cage_build codex "$FH/.local/bin/codex-tab" "$PD" >/dev/null 2>"$WORK/build.log"; then
  chk "escape: the link in the note is escaped" yes "$(grep -qF 'tab\x09link' "$WORK/build.log" && echo yes || echo no)"
  chk "escape: no raw control in the link note" escaped "$(no_raw)"
else bad "escape: cage_build failed for a link with a tab"; fi
mkdir -p "$FH/.Claude-zt/x${ESC}]0;title${ESC}\\"; cp "$ARGPROBE" "$FH/.Claude-zt/x${ESC}]0;title${ESC}\\/codex"
rc=0; cage_build codex "$FH/.Claude-zt/x${ESC}]0;title${ESC}\\/codex" "$PD" >/dev/null 2>"$WORK/build.log" || rc=$?
chk "escape: an agent-home executable with controls is refused" 2 "$rc"
chk "escape: the refusal shows its path escaped" yes "$(grep -qF 'x\x1B]0;title\x1B\\/codex' "$WORK/build.log" && echo yes || echo no)"
chk "escape: no raw control in the refusal" escaped "$(no_raw)"
cp "$REL/bin/codex" "$FH/.grok/grok"; chmod 755 "$FH/.grok/grok"
rc=0; cage_build grok "$FH/.grok/grok" "$PD" >/dev/null 2>"$WORK/build.log" || rc=$?
chk "a grok executable under ~/.grok: refused" 2 "$rc"
chk "the refusal says the cage can't read it" yes \
  "$(grep -qF "under $FH/.grok, which the cage can't read" "$WORK/build.log" && echo yes || echo no)"

echo "== a grok download under the agent home =="
# grok's installer keeps each version as one file in ~/.grok/downloads and links ~/.grok/bin/grok to the one in use,
# with ~/.local/bin/grok linking there. Only that file may open in the cage: not its siblings, the folder, or the rest.
GD="$FH/.grok/downloads"; GREL="$GD/grok-9.9.9-zt-macos-aarch64"
mkdir -p "$GD" "$FH/.grok/bin" "$FH/.grok/sessions" "$FH/.grok/logs"
cp "$ARGPROBE" "$GREL"; cp "$ARGPROBE" "$GD/grok-9.9.8-zt-macos-aarch64"; cp "$ARGPROBE" "$GD/grok-macos-aarch64"
for p in config.toml sessions/s.json logs/grok.log; do printf 'fixture\n' >"$FH/.grok/$p"; done
ln -s ../downloads/grok-9.9.9-zt-macos-aarch64 "$FH/.grok/bin/grok"; ln -s "$FH/.grok/bin/grok" "$FH/.local/bin/grok"
grok_cage() {
  chk "grok: the cage runs the download's physical path" "REAL='$GREL'" "$(grep -m1 -o "^REAL='[^']*'" "$W")"
  chk "grok: AGENT_BIN_FILE is that one file" "BINFILE='$GREL'" "$(grep -m1 -o "BINFILE='[^']*'" "$W")"
  chk "grok: the download starts in the cage" RAN "$(cg -c 'echo RAN')"
}
if cage_build grok "$FH/.local/bin/grok" "$PD" >/dev/null 2>"$WORK/build.log"; then
  W=$cage_wrapper CT=$cage_tmp CWD=$PD
  grok_cage
  want r READ "$GREL"
  want r DENY "$GD/grok-9.9.8-zt-macos-aarch64" "$GD/grok-macos-aarch64" "$GD" "$FH/.grok/bin/grok" "$FH/.grok/bin" \
    "$FH/.grok/config.toml" "$FH/.grok/sessions/s.json" "$FH/.grok/logs/grok.log"
  want w DENY "$GREL" "$GD/planted" "$FH/.grok/planted"
  for p in grok-9.9.8-zt-macos-aarch64 grok-macos-aarch64; do
    chk "grok: the sibling download $p does not run" DENY "$(cg -c "$(q "$GD/$p") -c 'echo RAN' 2>/dev/null || echo DENY")"
  done
  chk "grok: the link in ~/.grok/bin does not run" DENY "$(cg -c "$(q "$FH/.local/bin/grok") -c 'echo RAN' 2>/dev/null || echo DENY")"
  # The grok recipe re-opens ~/.grok/auth.json as AGENT_AUTH by design. With AGENT_AUTH elsewhere, the wrapper's
  # own profile parameters must leave it closed: the download file opens nothing else.
  eval "$(grep -m1 '^REAL=' "$W")"
  chk "grok: ~/.grok/auth.json stays closed apart from AGENT_AUTH" DENY "$(cd "$PD" && /usr/bin/sandbox-exec \
    -D DIR="$DIR" -D DIR_RE="$DRE" -D CAGE_TMP="$CT" -D HOME="$RH" -D AGENT_AUTH="$CT" -D AGENT_CFG_RO="$CFGRO" \
    -D LOCK_RE="$LRE" -D CAGE_ROOT="${CT%/*}" -D TTY="$CT/.notty" -D CAGE_SECRETS="$SEC" -D AGENT_BIN_FILE="$BINFILE" \
    -f "$PROFILE" /bin/dd if="$FH/.grok/auth.json" bs=1 count=1 >/dev/null 2>&1 && echo READ || echo DENY)"
else bad "grok download: cage_build failed ($(tr '\n' ' ' <"$WORK/build.log"))"; fi
# Launched by name, through PATH.
# shellcheck disable=SC2016 # The child shell expands its own arguments.
if env PATH="$LINKED" cage_agent=grok "$BASH" -p -c '. "$1"; shift; cage_build "$@" && printf "%s\n" "$cage_tmp"' sa \
  "$HERE/build.inc.sh" grok grok "$PD" >"$WORK/sa.out" 2>"$WORK/build.log"; then
  CT=$(cat "$WORK/sa.out") W="$CT/bin/grok" CWD=$PD
  grok_cage
else bad "grok by name: cage_build failed ($(tr '\n' ' ' <"$WORK/build.log"))"; fi
mkdir -p "$GD/nested"; cp "$ARGPROBE" "$GD/nested/grok"
rc=0; cage_build grok "$GD/nested/grok" "$PD" >/dev/null 2>"$WORK/build.log" || rc=$?
chk "grok: a file deeper under downloads is refused" 2 "$rc"

}
if command -v cc >/dev/null 2>&1 && cc -o "$WORK/argprobe" "$HERE/argprobe.c" 2>"$WORK/cc.log"; then
  ARGPROBE=$WORK/argprobe
  standalone_checks
else
  test_skip "standalone codex and grok download checks require a C compiler ($(tr '\n' ' ' <"$WORK/cc.log" 2>/dev/null))"
fi

echo "== what runs or is sourced outside the cage stays write-locked, even in a DIR that holds it =="
# The claude wrapper sources claude-<name>.env outside the cage, and the skill folder holds the launcher, its profile,
# templates and SKILL.md. Here the cage secrets are reached through a link, as REX_ORCHESTRATOR_CAGE_SECRETS may be: neither
# the target nor the link itself may change. (~/.config is read-denied, so sh can't read its cwd there and says so
# first: only the last line counts.)
CL="$FH/.config/rex-orchestrator" REAL_SEC="$FH/vault/cage-secrets"
mkdir -p "$FH/vault"; mv "$CAGE_SECRETS" "$REAL_SEC"; ln -s "$REAL_SEC" "$CAGE_SECRETS"
mk codex "$CL" || bad "the rex-orchestrator config folder as DIR: cage_build failed"
want w DENY "$CL/cage-secrets/claude-one.env" "$CL/cage-secrets/claude-z.env" "$REAL_SEC/claude-two.env"
chk "the config folder as DIR: swap the cage-secrets link for a folder" DENY "$(cg -c "{ rm $(q "$CL/cage-secrets") &&
  mkdir $(q "$CL/cage-secrets") && echo x > $(q "$CL/cage-secrets/claude-one.env"); } 2>/dev/null && echo ALLOW || echo DENY" | tail -n 1)"
want w ALLOW "$CL/README.md"
mk codex "$FH/vault" || bad "the link target's folder as DIR: cage_build failed"
want w DENY "$REAL_SEC/claude-one.env" "$REAL_SEC/new.env"
chk "the link target's folder as DIR: move the target away" DENY \
  "$(cg -c "mv $(q "$REAL_SEC") $(q "$REAL_SEC.old") 2>/dev/null && echo ALLOW || echo DENY")"
chk "the link target's folder as DIR: hard-link a cage credential elsewhere in DIR" DENY \
  "$(cg -c "ln $(q "$REAL_SEC/claude-two.env") $(q "$FH/vault/hl") 2>/dev/null && echo ALLOW || echo DENY")"
mk codex "${SCRIPT_DIR%/*/*}" || bad "the skill folder's parent as DIR: cage_build failed"
want w DENY "$SCRIPT_DIR/rex-orchestrator.sh" "$SCRIPT_DIR/cage.sb" "$SCRIPT_DIR/cage/claude.json" "${SCRIPT_DIR%/*}/SKILL.md"
chk "the skill folder's parent as DIR: hard-link the launcher elsewhere in DIR" DENY \
  "$(cg -c "ln $(q "$SCRIPT_DIR/rex-orchestrator.sh") $(q "${SCRIPT_DIR%/*/*}/hl") 2>/dev/null && echo ALLOW || echo DENY")"
want w ALLOW "${SCRIPT_DIR%/*/*}/README.md"
# Put back what an unlocked profile let a check change, and the cage secrets as a plain folder, for the checks after.
[ ! -d "$REAL_SEC.old" ] || mv "$REAL_SEC.old" "$REAL_SEC"
rm -rf "$CAGE_SECRETS"; mv "$REAL_SEC" "$CAGE_SECRETS"
rm -f "$CAGE_SECRETS/claude-z.env" "$FH/vault/hl" "${SCRIPT_DIR%/*/*}/hl"
printf 'export CLAUDE_CODE_OAUTH_TOKEN=zt-dummy-one\n' >"$CAGE_SECRETS/claude-one.env"

echo "== what runs or is read uncaged stays write-denied in a DIR inside or holding it (U10) =="
# launch refuses such a DIR; the profile denies the writes anyway. Each entry: a DIR inside it, then a write there.
for p in $CS .ssh .local/bin .agents/skills Library/LaunchAgents .claude .claude-work .codex .codex-alt .grok .gemini; do
  mkdir -p "$FH/$p/proj"
  if mk codex "$FH/$p/proj"; then want w DENY "$FH/$p/proj/out.txt"; else bad "U10: cage_build failed for a DIR in ~/$p"; fi
done
mk codex "$FH/.config" || bad "U10: cage_build failed for ~/.config as DIR"
want w DENY "$FH/$CS/x" "$FH/$CS/claude-one.env"
want w ALLOW "$FH/.config/y.txt" "$CT/still-writable"
mk codex "$FH" || bad "U10: cage_build failed for the home as DIR"
want w DENY "$FH/.local/bin/claude" "$FH/Library/LaunchAgents/x.plist" "$FH/.agents/skills/x" "$FH/.claude-x/y"
want w ALLOW "$FH/notes2.txt"

echo "== mach-lookup: 7 allowed, dangerous denied; no iokit-open (needs clang) =="
mk codex "$PD" || bad "mach: cage_build failed"
if command -v clang >/dev/null 2>&1; then
  cp "$HERE/machprobe.c" "$CT/machprobe.c"
  # clang writes temp objects to TMPDIR, the cage temp's tmpdir here, as for a caged codex.
  if cg -c "clang -o $(q "$CT/machprobe") $(q "$CT/machprobe.c") >/dev/null 2>&1 && echo built" | grep -q built; then
    allow=(com.apple.system.opendirectoryd.libinfo com.apple.system.opendirectoryd.membership com.apple.SystemConfiguration.configd
      com.apple.SystemConfiguration.DNSConfiguration com.apple.SystemConfiguration.NetworkInformation com.apple.trustd.agent
      com.apple.SecurityServer)
    deny=(com.apple.coreservices.launchservicesd com.apple.CoreServices.coreservicesd com.apple.coreservices.appleevents
      com.apple.lsd.mapdb com.apple.pasteboard.1 com.apple.windowserver.active com.apple.tccd com.apple.authd)
    names=("${allow[@]}" "${deny[@]}")
    out=$(cg -c "$(q "$CT/machprobe") ${names[*]}")
    for n in "${allow[@]}"; do chk "mach allow $n" REACHABLE "$(printf '%s\n' "$out" | awk -v s="$n" '$NF==s{print ($1=="REACHABLE")?"REACHABLE":"DENIED"}')"; done
    for n in "${deny[@]}";  do chk "mach deny $n"  DENIED    "$(printf '%s\n' "$out" | awk -v s="$n" '$NF==s{print ($1=="REACHABLE")?"REACHABLE":"DENIED"}')"; done
  else
    bad "mach: in-cage clang compile failed"
  fi
  # iokit-open (synthetic key and mouse events go through an IOKit user client, not a mach lookup): the probe opens
  # one on IOPMrootDomain, which any user process may, and closes it at once.
  cp "$HERE/iokitprobe.c" "$CT/iokitprobe.c"
  if cg -c "clang -o $(q "$CT/iokitprobe") $(q "$CT/iokitprobe.c") -framework IOKit >/dev/null 2>&1 && echo built" | grep -q built; then
    if [ "$("$CT/iokitprobe")" = OPEN ]; then
      chk "iokit-open of a user client" DENIED "$(cg -c "$(q "$CT/iokitprobe")" | cut -d' ' -f1)"
    else bad "iokit: the probe can't open IOPMrootDomain even uncaged"; fi
  else
    bad "iokit: in-cage clang compile failed"
  fi
else
  test_skip 'Mach and IOKit checks require clang'
fi

echo "== close's rmcage on a cage home the child sealed =="
printf 'keep\n' >"$OUT/keep"; chmod 400 "$OUT/keep"; chflags uchg "$OUT/keep"
sealed=$(cg -c "cd $(q "$CT") && mkdir seal && cd seal && ln -s $(q "$OUT/keep") link &&
  mkdir d000 && echo x > d000/f && chmod 000 d000 && mkdir d300 && echo x > d300/f && chmod 300 d300 &&
  echo x > imm && chflags uchg imm && echo x > app && chflags uappnd app &&
  mkdir acl && echo x > acl/f && chmod +a 'everyone deny delete' acl/f && chmod +a 'everyone deny list,search,delete_child' acl &&
  mkdir -p n1/n2/n3/n4 && echo q > n1/n2/n3/n4/f && chflags uchg n1/n2/n3/n4/f &&
  for d in n1/n2/n3/n4 n1/n2/n3 n1/n2 n1; do chmod 000 \$d && chflags uchg \$d || exit 1; done && echo SEALED")
chk "the child sealed its cage home" SEALED "$(printf '%s' "$sealed" | tail -n 1)"
/bin/bash "$SDIR/cage-cleanup.sh" "$STATE_DIR" "$CT" >/dev/null 2>&1; rc=$?
chk "rmcage removes it" "rc 0, gone" "rc $rc, $([ -e "$CT" ] && echo left || echo gone)"
chk "rmcage leaves a file a link in it points to alone" "-r-------- uchg" "$(stat -f '%Sp %Sf' "$OUT/keep")"

echo "== the wrapper stops at a failed seeding step (set -e) =="
mk codex "$PD" || bad "set -e: cage_build failed"
rm -rf "$CT/tmpdir"; : >"$CT/tmpdir"   # a file where the wrapper makes a folder
chk "a failed seeding step stops the agent" STOPPED "$(cg -c 'echo RAN' | grep -qx RAN && echo RAN || echo STOPPED)"

echo "RESULT PASS=$P FAIL=$F"
[ "$F" -eq 0 ]
