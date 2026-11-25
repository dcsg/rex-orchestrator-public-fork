# How it works

`rex-orchestrator` has a Bash entry point that resolves install symlinks and runs `status`, `ls`, `screen`, `wait`,
`send`, `keys`, `close`, `claims` and `launch` through `rex do`. Standalone LuaJIT runs `clone`, prunes dead claims
when Rex is offline, validates agy's token JSON, and harvests transcripts. Lua generates cage wrappers from shell
fragments. The wrappers run the cage, and a shared shell helper restores permissions and removes cage files.

## The pieces

```text
 orchestrator pane                             child pane
 ┌────────────────────────────┐ Rex layout API ┌──────────────────────┐
 │ any agent + shell          │ ─────────────▶ │ claude / codex / …   │
 │ rex-orchestrator launch …  │ terminal write │                      │
 │ rex-orchestrator send …    │ ─────────────▶ │  input box           │
 │ rex-orchestrator wait …    │                │                      │
 └─────────────┬──────────────┘                └──────────┬───────────┘
               │ rex block call program_status            │ OSC 7501 status reports
               └──────────────────▶ Rex server ◀──────────┘
```

1. **launch** calls Rex's layout API to split a pane or open a tab with `--tab`. It records the new block ID, its label,
   its parent (your `REX_BLOCK`) and the agent kind in the state directory, then polls until the child is ready.
   The claim lock spans placement and claim creation. Launch keeps a temporary recovery record until it returns the
   block ID so it can close an interrupted launch and release the claim. A pane Rex cannot close keeps its claim, ownership,
   and cage so the caller can retry with `close`.
2. **Readiness** is decided from the child's *own* status record plus its screen: the screen is read only to find dialogs
   (trust, hooks review, login) and the input footer, never to infer that a turn finished.
3. **send** reads status and screen, writes the text through Rex's terminal API, checks the composer, then sends
   Return through the keyboard API. **keys** checks the selected option before sending a dialog answer. Rex's CLI
   parses key chords and physical-key spellings outside the common Lua key set.
4. **wait** subscribes to program-status, process, block-close and session-destruction events for its target, then
   reads the initial snapshot. It takes the newest *root* record (records with an `id` belong to sub-agents and
   background tasks). Only records newer than the last `send`/`keys` count. Timers implement the timeout, idle grace
   and stale-dialog deadlines. A second startup snapshot and a five-second recheck catch missed events and detect
   lost connections. Screen-derived background counts and permission-mode guards still need screen reads
   every half second while active because Rex exposes no screen-damage event.
5. **close** closes the pane through Rex's block API, removes its registry record under the shared flock,
   harvests a caged child's transcripts, and removes the pane state. **claims** uses the same flock to prune and list
   live claims across sessions.
6. **Orphans.** Launch also starts one detached watcher per orchestrator (`rex do watch.lua`, in its own process
   session, holding `watch/<orchestrator>.lock` for its life, so it never multiplies). It wakes on block-close events
   and every five seconds. When the orchestrator's block is absent from the session's block list on two checks a
   second apart, its children become orphans: after the grace period, the done, idle, errored or exited ones are
   closed as **close** does; a working or blocked one is closed when its turn ends, or left open after the maximum
   wait. The watcher exits when no child is left, when the session is destroyed, or when its connection to Rex ends.
   Every other command sweeps its session the same way first, so orphans whose watcher a Rex restart ended are
   still caught, and starts a watcher again when its heartbeat is stale. Only a gone pane counts: an agent that
   quits in the orchestrator's pane, or is resumed there, keeps its children.

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
| `<block>` | Last send or keypress baseline and background count |
| `<block>.own`, `<block>.cage` | Parent pane, process identity, agent kind, pinned mode, session and orphan policy, and cage metadata |
| `<block>.orphan` | `expired`: an orphan left open after the maximum wait |
| `watch/` | One watcher lock, log and heartbeat per orchestrator, and when its pane was first and last seen gone |
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
`REX_SESSION` below is the real session ID. The tool can resolve it from `REX_BLOCK`, which Rex sets in each pane.

```sh
rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right -c "$DIR" --label task --keep-open --focus=false --json -- claude
rex capture -s "$REX_SESSION" -b "$B" --trim --unwrap        # screen
rex block call -s "$REX_SESSION" -b "$B" program_status      # status records
printf '%s' "$PROMPT" | rex send -s "$REX_SESSION" -b "$B" && rex send-key -s "$REX_SESSION" -b "$B" enter
rex block close -s "$REX_SESSION" "$B"
```

They skip every guard described in [safety.md](safety.md). Never use them to answer a prompt the tool refused.
