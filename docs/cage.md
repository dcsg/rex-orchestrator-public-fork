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

For agy with a login held in a secret store, keep only non-secret settings in the provisioned cage home and set
`REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD` to a shell command that returns the complete token JSON on stdout. For example:

```sh
export REX_ORCHESTRATOR_CAGE_AGY_TOKEN_CMD='fnox get AGY_CAGE_OAUTH_TOKEN'
```

The command is generic: any secret-store CLI can supply the JSON. It runs with Bash outside the sandbox,
after the cage home is copied and before agy starts, from the fixed working directory `/`. The wrapper refuses
a symlink at the provisioned home itself or anywhere inside it. `launch` refuses a provisioned home that overlaps
the task's `DIR` with exit **2**. The wrapper rechecks the overlap, verifies the physical source directory, copies
without following links, and checks the private copy for symlinks before starting the provider. The helper gets only
the real `HOME`, a fixed `PATH` (`/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`), `SHELL=/bin/bash` and
`LANG=en_US.UTF-8`, plus Bash's own `PWD`/`SHLVL`. Project variables, `BASH_ENV`, `ENV`, shell functions and project
PATH entries are discarded. The wrapper also uses Bash's privileged startup mode to ignore environment startup
hooks before doing any uncaged work. A planted `DIR/fnox.toml`, `.mise.toml` or `.envrc` is never implicitly used.
Use absolute executable/config paths in the lookup when needed; do not source files from agent-writable DIR.

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
- **Reads** of secret stores and agent homes: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config` (except `git`),
  `~/Library/Keychains`, shell histories, Messages, Mail, every `~/.claude*`, `~/.codex*`, `~/.grok*`, `~/.gemini*`, other
  agents' folders in `~/Library/Application Support`, other cage homes, other Claude sessions' temp files, and every repo
  under `~/Repos` except DIR's.
- **Network** on any port but 443, 80 and 53, loopback included; every unix socket but DNS's (so no Rex, no ssh-agent).
- **Mach services** outside a 7-name allowlist (TLS, DNS, user lookup): no LaunchServices, AppleEvents, clipboard,
  WindowServer, TCC; no `iokit-open`; no signals outside the cage; no `sudo`, `launchctl`, `osascript`, `open`, `ssh`,
  `scp`, `sftp`, `crontab`, `at`, `batch`.

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
