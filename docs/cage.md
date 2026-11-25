# The cage (macOS sandbox)

On macOS, `launch` can run a child under `sandbox-exec` with the profile [`cage.sb`](../skills/rex-orchestrator/scripts/cage.sb).
It is a filesystem, network-port and privilege boundary for agents you don't fully trust with your machine.

## When a child is caged

`REX_ORCHESTRATOR_CAGE=auto` (the default) cages every agent that has a **cage recipe**:

| Agent | Recipe | Needs |
|---|---|---|
| `codex` | always | its normal login (`auth.json` in `CODEX_HOME` or `~/.codex`, re-opened read-only) |
| `grok` | always | its normal login (`~/.grok/auth.json`, read-only) |
| `claude` | when a credential exists | `$CAGE_SECRETS/claude-NAME.env` containing `export CLAUDE_CODE_OAUTH_TOKEN=…` |
| `agy` (Gemini) | when a cage home exists | `$CAGE_SECRETS/agy-home` with settings; login from a command or that home |
| others | none | run uncaged with a note |

`CAGE_SECRETS` defaults to `${XDG_CONFIG_HOME:-~/.config}/rex-orchestrator/cage-secrets`. `--no-cage` (or
`REX_ORCHESTRATOR_CAGE=off`) runs uncaged; `--cage` (or `REX_ORCHESTRATOR_CAGE=on`) fails for an agent without a recipe.

**Fail closed:** when an agent that should be caged can't be (missing profile, template or login, a DIR path the profile
can't express), `launch` exits 2 and never runs it uncaged instead.

### Which executable a caged agent runs

The cage starts the agent's own executable directly, with a clean environment and a fixed `PATH`. For codex, claude and
grok launched by name (`--agent codex`):

- `REX_ORCHESTRATOR_CAGE_<AGENT>_BIN` (`REX_ORCHESTRATOR_CAGE_CODEX_BIN`, `…_CLAUDE_BIN`, `…_GROK_BIN`), when set, is
  the executable. It must be an absolute path to an executable file. It applies to caged launches only: when nothing
  on `PATH` matches and the cage doesn't apply after all (claude with no cage credential under `auto`), `launch` exits
  2 instead of running the variable's file uncaged.
- Otherwise `launch` takes the first one on your `PATH` that is a compiled executable (Mach-O) or a Node script whose
  `node` is compiled too: the `#!` path, or the one `env` finds through `-P`, a `PATH=` it sets (or execvp's default
  after `-i` or `-u PATH`), or else the cage's fixed `PATH` (`/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`). macOS won't start a script as an interpreter, and
  `sandbox-exec` would then run the agent file with `/bin/sh`. Those
  are what the agents install: codex's and claude's native binaries and grok's download are Mach-O, an npm install of
  codex runs `bin/codex.js` through `#!/usr/bin/env node`, and npm's claude package puts its native binary in place
  at install time. Every other match is a script: a shell script in any `#!` form (directly, or through `env` with any
  options, `NAME=VALUE` assignments or a `-S` string, joined or not), a text file with no `#!` line (which `execvp`
  hands to `/bin/sh`), or a fish, Python, Perl or Ruby script, or any other interpreter. Such a file is a wrapper or
  shim, such as one that fetches MCP tokens and then runs the real agent. Inside the cage its environment is gone,
  its `PATH` lookup usually finds nothing, and the cage config has no MCP servers to give tokens to, so `launch`
  skips it and says which file it skipped and which one it runs. It never runs the shim. An unreadable file is skipped
  too, since it can't be told apart. When nothing on `PATH` qualifies, `launch` exits 2 and names the variable to set.
  If such a script is the agent's own launcher (a pnpm or asdf wrapper, say), set the variable to it. Uncaged launches
  still run the first match, shim included. agy is not affected: its Homebrew launcher is itself a Bash script, and
  `launch` runs it as before.
- `--agent` given as a path is used as given.

The cage denies reads and execution under every agent home (`~/.claude*`, `~/.codex*`, `~/.grok*`, `~/.gemini*`), so an
agent installed there can't start. The one exception is codex's standalone install, which keeps each version in
`CODEX_HOME/packages/standalone/releases/<version>/` (or `~/.codex/…`) and links `~/.local/bin/codex` to it through
`packages/standalone/current`. `launch` resolves the executable's physical path and, when it lies inside such a release
folder, runs it by that path and re-opens exactly that one folder, read and execute only, for this launch
(`-D AGENT_BIN_DIR`). Nothing else under the codex home opens: `auth.json` (unless it is the login the codex recipe
re-opens anyway), `config.toml`, sessions, history, logs and other releases stay unreadable and unexecutable, and the
release folder itself stays unwritable. grok's installer works the same way with single files: each version is one
executable in `~/.grok/downloads/` (or `GROK_HOME/downloads/`), `~/.grok/bin/grok` links to the one in use, and
`~/.local/bin/grok` links there. When the physical path is a file directly in such a downloads folder, `launch` runs
it by that path and re-opens exactly that one file, read and execute only, for this launch (`-D AGENT_BIN_FILE`). The
folder, the other downloads, the links in `~/.grok/bin`, config, sessions and logs stay closed; `auth.json` opens only
as the login the grok recipe re-opens anyway. Any other executable under an agent home makes `launch` exit 2 with a
message: install the agent elsewhere or point the variable above at a copy outside the agent home. An executable outside the agent homes that is reached through a link inside one (a
`~/.codex/bin/codex` link on the way to `/opt/x/codex`, say) also can't be followed in the cage, so `launch` runs it by
its physical path and says so.

This protects only the codex homes the profile denies, `~/.codex*`. With `CODEX_HOME` outside them (say
`~/codex-home`), the profile has no deny for it in the first place: the child can read (not write) that home's
`config.toml`, sessions, history and logs, as it could before this release folder rule existed. Keep `CODEX_HOME`
under `~/.codex*` if that matters.

A shim written in Node is the one kind the check can't tell from an npm-installed agent: it runs in the cage, as
it did before this check existed, still with no access to anything the cage denies. Set
`REX_ORCHESTRATOR_CAGE_<AGENT>_BIN` to skip it.

### Setting up claude and Gemini (agy)

```sh
mkdir -p ~/.config/rex-orchestrator/cage-secrets && chmod 700 ~/.config/rex-orchestrator/cage-secrets
# claude: a token that can only make model requests
claude setup-token        # then:
printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "<token>" > ~/.config/rex-orchestrator/cage-secrets/claude-work.env
chmod 600 ~/.config/rex-orchestrator/cage-secrets/claude-work.env
# Gemini (agy): log in into a dedicated home (answer Cancel to the keychain dialog so the token lands in a file)
HOME=~/.config/rex-orchestrator/cage-secrets/agy-home agy
```

With several `claude-*.env` files, `--account NAME` picks one; without it the only file is used, otherwise the
alphabetically first, and `launch` says which. `status` shows it as `account`.

Set `REX_ORCHESTRATOR_CAGE_AGY_HOME` to override the provisioned agy home. A relative path resolves against the
launcher's working directory.

For agy with a login held in a secret store, keep only non-secret settings in the provisioned cage home and set
`REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD` to a shell command that returns the complete token JSON on stdout. For example:

```sh
export REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD='fnox get AGY_CAGE_OAUTH_TOKEN'
```

The command is generic: any secret-store CLI can supply the JSON. It runs with Bash outside the sandbox,
after the cage home is copied and before agy starts, from the fixed working directory `/`. The wrapper refuses
a symlink at the provisioned home itself or anywhere inside it. `launch` refuses a provisioned home that overlaps
the task's `DIR` with exit **2**. The overlap check compares directory identities (device and inode) up both paths, so a
different-case spelling or a `/System/Volumes/Data` firmlink spelling of the same folder is refused too. The wrapper
rechecks the overlap, verifies the physical source directory, copies without following links, and checks the private
copy for symlinks before starting the provider. After each change of directory it checks the real working directory
from `getcwd`, not Bash's `PWD`, so a rename that swaps in a symlink mid-`cd` stops startup instead of copying another
folder. The helper gets only the real `HOME`, a fixed `PATH` (`/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`),
`SHELL=/bin/bash` and `LANG=en_US.UTF-8`, plus Bash's own `PWD`/`SHLVL`. Project variables, `BASH_ENV`, `ENV`,
shell functions and project PATH entries are discarded. The wrapper also uses Bash's privileged startup mode to ignore
environment startup hooks before doing any uncaged work. A planted `DIR/fnox.toml`, `.mise.toml` or `.envrc` is never
implicitly used. Use absolute executable/config paths in the lookup when needed; do not source files from agent-writable DIR.

What the home checks guarantee, and what they don't. The wrapper resolves the provisioned home's parent once, to a
physical path, and every later step (the overlap recheck, the symlink check, the copy) uses that path. After that
point, a swap that changes where that path physically leads (a symlink put in place of the home or a folder above it)
is caught: the copy's `cd` lands somewhere else and startup stops. A swap that keeps the physical path is not: if a
real folder of the same name is moved into the home's place after the checks, the copy's `cd` compares the path as a
string and passes, the wrapper copies that folder, and the only check that applies to it is the symlink check on the
private copy. The overlap and source symlink checks were made on the folder that was there before. A folder above the
home that is
renamed and replaced (for example by a symlink) *before* that point is followed: the wrapper checks and copies the
folder it now leads to, consistently, the same as if `REX_ORCHESTRATOR_CAGE_AGY_HOME` named that folder. Every check
still applies to it, so it can't overlap DIR or contain a symlink. What is not guaranteed is that it is the folder you
provisioned. Renaming a folder needs write access to the folder that holds it, which is also above the home. If that
were inside DIR, the home would be inside DIR too, and `launch` and the wrapper refuse that as an overlap. So only a
process that can rename folders outside DIR can redirect the home: one of your own, or another caged agent whose DIR
holds the home. This launch's agy has not started yet at that point. The default home is in `CAGE_SECRETS`, which every
cage write-denies and `launch` refuses as a DIR. If you set `REX_ORCHESTRATOR_CAGE_AGY_HOME`, keep it in a folder no
agent writes.

The command text waits in a mode-600 file under `STATE_DIR/cage-commands/`, outside `CAGE_ROOT`. The profile denies
every caged child reads and writes there. The generated wrapper contains only the file's path. The command file is
removed after lookup, on wrapper exit, or by `close` if the wrapper never started. Use a store lookup rather than a
literal credential in the command. After removing any existing file, the wrapper opens a mode-600 file from the
verified physical `home/.gemini/antigravity-cli` directory inside the private cage. It sends the provider's stdout
to that open file.
Output must be exactly one JSON object with a non-empty string `.token.refresh_token`, as in agy's normal
token file. A top-level `.refresh_token` is also accepted for compatibility. The validator opens the file with
`O_NOFOLLOW_ANY`. A symlink anywhere in the path, including `.gemini` or `antigravity-cli`, stops startup.
Validation prints no token contents.
Unsafe home paths, provider failure, invalid JSON, a missing or empty refresh token, and empty stdout stop the
wrapper with **71** before agy starts. A failed lookup removes its partial output and reports the variable
without printing credential contents.
If observed during startup, `launch` reports its usual **12** for an exited child.

Lookup is noninteractive: stdin is closed and stderr is suppressed because a failing command can echo credentials.
Unlock the store before launch; passphrase/Touch ID prompts and their diagnostics are not forwarded to the terminal.
The lookup runs in its own process group so cancellation also stops provider subprocesses; any subprocesses left
after lookup returns are stopped before agy starts. Job control is disabled again for agy's terminal session.
Cancellation received during that provider shutdown is queued and handled before agy can start.

The wrapper keeps agy in the terminal's foreground process group and forwards its exit status. On normal exit,
a non-zero exit, or HUP/INT/TERM/QUIT/PIPE/USR1/USR2/ALRM, it removes the token if the token directory is still
the one it prepared. A moved or replaced directory stays in the cage until `close`. Signals go to the active lookup
or agy child; INT and QUIT map to TERM because asynchronous children can inherit those two signals ignored. The
wrapper waits up to five seconds, sends KILL if the child is still alive, and reaps it before deleting the token.
A token rewritten in the original directory by agy's shutdown handler is removed too. Signals in the fork-to-PID-assignment window
use the shell's job table to find and stop the child. The wrapper exits with `128 +` the original signal number
(HUP/INT/TERM: 129/130/143). The command and token are absent from agy's environment (`env -i`). The token is still
readable by agy during the session. agy can copy it into `DIR` while running, and cage cleanup leaves copies in
`DIR` alone. The wrapper never writes the token back to the store.

SIGKILL to the wrapper and a machine crash cannot run cleanup traps. They can leave a token in
`STATE_DIR/cage/agy.*/home/.gemini/antigravity-cli/antigravity-oauth-token` (or the corresponding `agy-*` cage).
`close` removes that cage home and any remaining private command file.
When the variable is unset, the wrapper keeps the copied login until `close`. The home checks still apply, and an unsafe
home stops the wrapper with exit **70**.

## What a caged child gets

- A clean environment (`env -i`): no `REX_*`, no `SSH_AUTH_SOCK`, no tokens — only terminal and locale variables.
- A throwaway config home under `STATE_DIR/cage/` built from the templates in `scripts/cage/`, **not your settings**: pass a
  model and other options after `--`. It has none of your MCP servers, connectors, skills, plugins, hooks or memory.
- codex runs in bypass mode and grok in always-approve, with their own sandboxes off (seatbelt doesn't nest); a caged Gemini (agy)
  runs with `--dangerously-skip-permissions`. The cage is the boundary, so there are no approval dialogs.
- A caged claude gets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, so the shells, hooks and MCP servers it starts don't inherit its
  token; its tools are pre-allowed in the cage settings so it still runs without prompts.
- On `close`, transcripts and logs are harvested into `STATE_DIR/runs/<label>-<UTC>/` (mode 700) with a `manifest.json`
  (agent, account, paths, SHA-256 hashes). Credentials, env files, settings and links are never copied.

## What the cage denies

- **Writes** anywhere but DIR, the child's own cage home and terminal devices — also through symlinks, renames and hard
  links. Even inside DIR: the cage secrets, this tool's folder, `~/.ssh`, `~/.local/bin`, `~/.agents`,
  `~/Library/LaunchAgents`, `/opt/homebrew`, `/Applications` and every agent home.
- **Auto-run files inside DIR** that would execute unsandboxed later: `.git/hooks/`, `.git/config`, `.envrc`, `.mcp.json`,
  `.claude/`, `.codex/`, `.gemini/`, `.grok/`, `.cursor/`, `.zed/`, `.vscode/`, `.idea/`, `.husky/`, `.githooks/`,
  `.agents/`, and a repo's own `core.hooksPath`. (So `git init`/`git config` fail in the cage: create the repo first.)
- **Execution** under every agent home (`~/.claude*`, `~/.codex*`, `~/.grok*`, `~/.gemini*`), except the launched codex
  release folder or grok download and the child's own cage home.
- **Reads** of secret stores and agent homes: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config` (except `git`),
  `~/Library/Keychains`, shell histories, Messages, Mail, every `~/.claude*`, `~/.codex*`, `~/.grok*`, `~/.gemini*`, other
  agents' folders in `~/Library/Application Support`, other cage homes, other Claude sessions' temp files, and every repo
  under `~/Repos` except DIR's. The exceptions are the agent's one login file (codex, grok) and a launched codex
  release folder or grok download.
- **Network** on any port but 443, 80 and 53, loopback included; every unix socket but DNS's (so no Rex, no ssh-agent).
- **Mach services** outside a 7-name allowlist (TLS, DNS, user lookup): no LaunchServices, AppleEvents, clipboard,
  WindowServer, TCC; no `iokit-open`; no signals outside the cage; no `sudo`, `launchctl`, `osascript`, `open`, `ssh`,
  `scp`, `sftp`, `crontab`, `at`, `batch`.

Case: the home volume is case-insensitive by default, and on it the profile's path rules ignore case too, so
`~/.CODEX/auth.json` is as denied as `~/.codex/auth.json` (checked for literal, prefix, subpath and regex rules, and
for a non-ASCII folder typed in another case or Unicode form). `launch`'s own checks against these locations (the DIR
refusal below, the agent-home and release checks above, the link walk) first put HOME and each path in its on-disk
spelling with `/bin/realpath`, which settles non-ASCII case and Unicode normalization, and then compare ignoring ASCII
case, for a path that doesn't exist.

`launch` also refuses a caged DIR that *is, holds or sits in* any of the protected locations above, or is `/`, `/Users`,
your home, `~/Library` or `~/Repos`: give each task its own folder.

## What the cage does NOT cover

- **Egress.** HTTPS to any host stays open for the model API, so a caged agent can send out anything it can read, its
  re-opened login token included.
- **DIR is attacker-written.** Build steps that run code (`package.json` scripts, `.npmrc`, `pyproject.toml`, `Makefile`,
  `.devcontainer/`, `.gitattributes` filters) aren't locked, nor are symlink or gitdir-file reroutes. **Review DIR's diff
  before running anything against it uncaged** — git (hooks fire on checkout/merge), direnv, an editor, another agent,
  `npm install`, a build.
- **TLS services** (`com.apple.SecurityServer`, `trustd.agent`) are reachable; safe only while keychain files stay
  read-denied.
- **Rex.** A caged agent can't reach Rex, so it can't orchestrate children itself; such a parent needs `--no-cage`.
- **Terminals.** `/dev/tty*` stays writable so tools that open a sub-pty work: a caged child could print onto another pane's
  screen (not type into it). Never trust a screen on its own.

## Harmless messages

codex's `⚠ 1 warning` at start (its worktree tools can't reach their local server) and a `git` `xcrun` cache "Operation not
permitted" line are expected inside the cage.
