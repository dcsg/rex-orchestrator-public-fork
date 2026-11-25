# How it works

`rex-orchestrator` has a Bash entry point that resolves install symlinks and runs `status`, `ls`, `screen` and `wait`
through `rex do` and the Lua API. The other commands and the cage runtime remain in `rex-orchestrator-bash.sh` during
the phased migration. Both implementations use the same state files and guards.

## The pieces

```text
 orchestrator pane                             child pane
 ┌────────────────────────────┐   rex split    ┌──────────────────────┐
 │ any agent + shell          │ ─────────────▶ │ claude / codex / …   │
 │ rex-orchestrator launch …  │   rex send     │                      │
 │ rex-orchestrator send …    │ ─────────────▶ │  input box           │
 │ rex-orchestrator wait …    │                │                      │
 └─────────────┬──────────────┘                └──────────┬───────────┘
               │ rex block call program_status            │ OSC 7501 status reports
               └──────────────────▶ Rex server ◀──────────┘
```

1. **launch** runs `rex split` (or opens a tab, with `--tab`) with the agent command, records the new block ID, its label,
   its parent (your `REX_BLOCK`) and the agent kind in the state directory, then polls until the child is ready.
2. **Readiness** is decided from the child's *own* status record plus its screen: the screen is read only to find dialogs
   (trust, hooks review, login) and the input footer, never to infer that a turn finished.
3. **send** reads status and screen again, types with `rex send`, checks that the input box shows the text, then presses
   Return with `rex send-key`.
4. **wait** subscribes to program-status, process, block-close and session-destruction events for its target, then
   reads the initial snapshot. It takes the newest *root* record (records with an `id` belong to sub-agents and
   background tasks). Only records newer than the last `send`/`keys` count. Timers implement the timeout, idle grace
   and stale-dialog deadlines. A second startup snapshot and a five-second recheck catch missed events and detect
   lost connections. Screen-derived background counts and permission-mode guards still need screen reads
   every half second while active because Rex exposes no screen-damage event.
5. **close** runs `rex block close`, harvests a caged child's transcripts, and removes state and claims.

## Program status (OSC 7501)

Agents emit `OSC 7501` sequences with a state (`idle`, `working`, `done`, `blocked`, `error`), an optional `kind`
(`permission`, `question`, `auth`) and a message. Rex keeps the latest record per program, and its CLI exposes them with
`rex block call … program_status`. Both Rex's UI and this tool rely on agents reporting it; Rex no longer guesses status from
screen output. An agent sitting on a dialog it shows *before* it starts reporting (Claude's folder-trust prompt, for example)
has no status yet — `launch` handles those dialogs from the screen.

See Rex's [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status).

## State

`STATE_DIR` (default `${XDG_STATE_HOME:-~/.local/state}/rex-orchestrator`, created mode 700; a link or a folder you don't own is
refused) holds:

| Path | Content |
|---|---|
| `<block>` | One small record per launched pane: parent, label, kind, launch time, cage home… |
| `registry/` | Write claims, one per launch, guarded by a lock |
| `cage/` | Throwaway homes of caged children |
| `runs/<label>-<UTC>/` | Harvested transcripts and logs of caged children, with a `manifest.json` |
| `disabled`, `disabled.<agent>` | Kill switches |

## Ownership

Every launched pane records the `REX_BLOCK` it was launched from. `send`, `keys`, `close` and `wait --approve-in` refuse a
pane whose recorded parent isn't the caller (exit 2) unless `--force` is given, and no command targets the caller's own pane
in any form of its ID. This is what lets several orchestrators share one Rex session safely.

## Without the tool

The underlying `rex` calls are:
`REX_SESSION` below is the real session ID; when it is empty, the tool obtains it once from `rex whoami --json`
using `REX_BLOCK`, which Rex sets in each pane.

```sh
rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right -c "$DIR" --label task --keep-open --focus=false --json -- claude
rex capture -s "$REX_SESSION" -b "$B" --trim --unwrap        # screen
rex block call -s "$REX_SESSION" -b "$B" program_status      # status records
printf '%s' "$PROMPT" | rex send -s "$REX_SESSION" -b "$B" && rex send-key -s "$REX_SESSION" -b "$B" enter
rex block close -s "$REX_SESSION" "$B"
```

They skip every guard described in [safety.md](safety.md). Never use them to answer a prompt the tool refused.
