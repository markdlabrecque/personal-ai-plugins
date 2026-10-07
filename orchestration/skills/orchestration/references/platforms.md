# Platforms, adapters and selftest

What matters most, in order: **(a) self-verification with teardown, (b) visibility of each ticket's worktree and agent, (c) durable sessions.** This file specifies platform resolution, the per-platform adapters and `orch selftest`. It extends [orch-cli.md](orch-cli.md).

## Platform resolution

There is no saved platform or harness: each `orch` call reads them from where it runs, so a ticket session always lands where the main orchestrator is. First match wins:

1. `ORCH_PLATFORM` (env override; tests use it).
2. The platform the environment shows: `HERDR_ENV=1` → herdr, `ORCA_TERMINAL_HANDLE`/`ORCA_WORKTREE_ID` → orca, `CLAUDE_CODE_ENTRYPOINT=claude-desktop` → desktop.
3. Otherwise `headless`.

The harness resolves the same way; see [orch-cli.md](orch-cli.md) "Harnesses". `orch` ignores `platform` and `harness` keys in `${XDG_CONFIG_HOME:-~/.config}/orchestration/config.json` (an older `orch setup` wrote them; a saved Herdr choice once sent a plain-terminal session's ticket into Herdr). That file's `"pi_models"` (the Pi models for the stage agents' tiers) is still read by the Pi extension.

Project settings stay in `<project root>/.agents/orchestration/config.json`.

## Adapters

All platform branching lives in one adapter per platform. The core (state, phases, hooks, health, gates) never branches on platform, except to pick the adapter. Every adapter implements:

| Method | Does |
|---|---|
| `create_worktree(ticket)` | Make and provision the ticket's worktree from `BASE_BRANCH`, named with the ticket id. Returns its absolute path and any platform ref (Orca worktree id, Herdr workspace). |
| `launch(ticket, mode)` | Start (`mode=start`) or continue (`mode=resume`) the ticket's session. Returns `launch_ref`, or an action for the main orchestrator (desktop). |
| `visible(ticket)` | Ask the platform whether the ticket's worktree and session show up natively. Returns `{"worktree": bool, "session": bool, "detail": ...}`. |
| `close(ticket)` | Close what `launch` opened (process, terminal, workspace or Desktop session). Best effort; returns errors rather than raising. |
| `remove_worktree(ticket, force)` | Delete the ticket's DDEV project, worktree checkout and branch. Refuses uncommitted or unpushed work unless `force`. |

| | headless | orca | herdr | desktop |
|---|---|---|---|---|
| `create_worktree` | bundled `create-worktree` engine: `setup-worktree.sh <name>` | `orca worktree create --repo path:<main> --name <name> --no-parent --base-branch <BASE_BRANCH> --setup skip --json` (no agent), then the engine's `--provision` with cwd = the new worktree | engine | engine |
| `launch` | `claude -p` detached (as today) | mark the worktree trusted (Folder trust, below), then `orca terminal create --worktree path:<wt> --title t<ticket> --command '<cmd>' --json`, then the folder-trust check (below) | `herdr worktree open --cwd <main> --path <wt> --label t<ticket> --no-focus` (workspace and root pane recorded), then mark the worktree trusted (Folder trust, below), then `herdr agent start <agent> --kind claude --pane <root pane> -- --session-id <sid> <claude_args>`, then `herdr agent prompt <agent> <prompt>`; resume uses `--resume <sid>` | action `desktop_start` / `desktop_resume` |
| `visible` | worktree directory exists; session process alive | `orca terminal list --worktree path:<wt> --json` lists the handle; `orca worktree list --json` lists the path | `herdr agent get <agent>` succeeds; `herdr worktree list` shows the path with an `open_workspace_id` | action `desktop_check`: the main orchestrator answers with `orch selftest --continue` (below) |
| `close` | signal the identity-checked process group | `orca terminal close --worktree path:<wt> --all --json` (closes Orca's fallback shell too) | `herdr workspace close <ws>` (keeps the checkout) | action `desktop_archive` |
| `remove_worktree` | bundled `retire-worktree` engine: `retire-worktree.sh <name> [--force]` (DDEV delete, `git worktree remove`, branch delete) | `retire-worktree.sh <name> --ddev-only [--force]` (uncommitted-work check and DDEV delete only), then `orca worktree rm --worktree id:<orca worktree id> --force --json` for checkout and branch (`path:<wt>` when no id was recorded) | engine | engine |

Details the live binaries showed (Orca 1.4.219, Herdr 0.9.1):

- `<name>` is the ticket id in the engines' alphabet: lowercased, runs of anything outside `a-z0-9-` turned into `-`. The engines run with cwd = the main checkout and `BASE_BRANCH` from `.orch` in their environment; they resolve the project root and `WORKTREE_ROOT` themselves (`WORKTREE_ROOT` in the environment still wins). After the create engine succeeds, `orch` takes the new linked worktree named `<name>` from `git worktree list`. A failed create removes the half-made worktree it left (its branch only when the branch is new), and leaves the ticket `ready`. It removes only the one new worktree named `<name>` that was not there before the call; `spawn` claims the ticket (the in-flight marker, [orch-cli.md](orch-cli.md) "Launching sessions") before it creates, and refuses with exit 3 (`launch in progress`) while another ticket whose worktree name is the same `<name>` holds a live marker, so two spawns never create the same name at once.
- `<agent>` (Herdr) is `t` + the lowercased ticket id with characters outside `[a-z0-9_-]` turned into `-`, cut to 32 characters (Herdr's `[a-z][a-z0-9_-]{0,31}`). It is stored in `launch_ref`.
- **Orca.** Orca hides worktrees it did not make, and an interactive `claude` does not start in one (`terminal create` times out). So the orca adapter makes its worktrees with Orca; `orch spawn --worktree P` on orca needs an Orca-managed `P`. Every `path:` selector uses the realpath. When the repo is not registered (`repo_not_found`, or `selector_not_found`), `orch` runs `orca repo add --path <main> --json` and retries once. Orca's reply gives `result.worktree.path` and `result.worktree.id` (`<repoId>::<path>`); the id is kept in the ticket's `worktree_ref`. Without `--agent`, Orca opens one fallback shell terminal; `close` closes it with the session's. Orca errors exit 1 with `"ok": false` and `error.code`.
- **Herdr.** Herdr exits 0 even on errors; any reply with a top-level `"error"` is a failure. `worktree open` needs `--cwd`; it also opens a workspace for the main checkout (the source workspace) when none is open. That workspace is where the main orchestrator lives: `orch` never closes it on a ticket's launch, resume or retire; only `selftest` closes it, and only when it opened it (below). Opening the workspace belongs to `launch` (not `create_worktree`), so `spawn --worktree` and `resume` open one too. A workspace `worktree open` reports `already_open` is never closed on a failed launch; when the agent was already started in it (a failed `agent prompt`, or an `agent start` that answered `agent_not_ready` for something other than folder trust), `orch` stops that agent with `herdr pane close <root pane>`, since Herdr has no `agent stop`.
- **Desktop / headless.** `claude -p --session-id` / `--resume` work as before; every stream-json line carries `session_id`.

### Folder trust

An interactive `claude` started in a folder Claude has not trusted stops at the "trust this folder" dialog; headless `-p` does not. Trust is per exact path: trusting a parent such as `~/Projects` does not cover a new worktree under it, so every ticket worktree would stop there.

**Marking.** On orca and herdr, `launch` (start and resume) marks the worktree trusted in Claude's user config after the worktree exists and before the terminal or agent starts. Headless and desktop never mark. The config is `$ORCH_CLAUDE_JSON` if set (tests always set it), else `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`. `orch` sets `projects[<worktree realpath>].hasTrustDialogAccepted = true`, creating the entry `{}` when missing and keeping every other key in the file and in the entry. When the config path is a symlink, `orch` writes the file it points to (realpath), so the link stays a link. Claude processes rewrite this file all the time, so each change is read (recording the file's inode, mtime and size), modified, and written to a temp file in the target's directory with the original's mode. Just before `os.replace` moves it over the target, `orch` re-stats the target; when it changed since the read, the temp file is discarded and the read-modify-write starts again. After a write `orch` re-reads the file and, when a concurrent writer dropped the change, retries. Both retries count toward one cap (3 attempts, short backoff). The temp file is removed whenever the replace did not happen, interrupts included. A missing file or one that is not valid JSON is never created or overwritten: `orch` prints a warning (never the file's contents), skips marking and launches anyway, so detection below reports the prompt if it appears.

The ticket row's `trust_marked` says what `orch` added: `0` nothing (already trusted, or marking skipped), `1` the key in an existing entry, `2` the whole entry. Each addition logs a `trust_mark` event whose detail is the path. A launch that then fails removes the trust it just added. `retire` removes it before `remove_worktree`: the key alone for `1`; for `2` the whole entry only while it is still exactly `{"hasTrustDialogAccepted": true}`, else just the key (Claude may have added keys since); trust that was there before `orch` stays. Two tickets can name one worktree (a `done` ticket's worktree handed to a new one). Before marking, `orch` skips the mark (recording `0`) when another non-retired ticket with the same worktree realpath already has `trust_marked` above `0`. On retire, when another non-retired ticket names the same worktree, the trust is not removed: that ticket's `trust_marked` takes this one's value (the larger of the two) and this one's becomes `0`. `retire --keep-worktree` keeps it, since the worktree stays. Removal uses the same safe write and verify; a failure is a warning and never blocks the retire.

**Detection** stays as the fallback. `launch` detects the block:

- Orca: after `terminal create`, `orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 20000 --json`; a `blockedReason` of `agent-trust-workspace` means blocked. A wait that times out or fails counts as not blocked. This wait can add up to 20 s to every orca launch (`spawn`, `resume`, selftest), since a claude that never goes idle runs the timeout out. When `terminal create` succeeds but its reply names no handle, `orch` closes the worktree's terminals (`orca terminal close --worktree path:<wt> --all --json`) and the launch fails.
- Herdr: `agent start` replies `{"error": {"code": "agent_not_ready", "message": "... blocked during startup ..."}}`, or a later `agent prompt` replies `agent_blocked`. Either only says the agent is blocked, not by what, so `orch` reads the agent's screen (`herdr agent read <agent> --source visible`): it is the folder-trust dialog only when the error or the screen mentions "trust". Any other block is a plain launch failure.

Then `spawn`/`resume` record the launch (`launch_ref`, a `trust_prompt` event), leave the terminal or workspace open and exit 3 with `claude is waiting at the folder-trust prompt in <wt>; open that terminal and accept it once (orch could not mark the folder trusted)`. On Herdr the message also gives the `herdr agent prompt` command that sends the prompt after acceptance. `selftest` reports the block as the `report-in` failure, at once, instead of waiting out its timeout.

Exact Orca and Herdr flags come from each binary's own `--help` and guide (`orca skills get orca-cli`, `herdr --skill`). Where the help is ambiguous, pick the documented route and let `selftest` prove it.

### Bundled worktree engines

The plugin carries the `create-worktree` and `retire-worktree` skills (scripts and tests) under `skills/`, so it works on a machine without them.

`orch` calls the project's own shim when the main checkout has one (`scripts/setup-worktree.sh`, `scripts/retire-worktree.sh`). It sets `WORKTREE_ENGINE` / `RETIRE_ENGINE` to the bundled engines, so the shim's project config (like `DB_DUMP`) still applies and it delegates to the plugin's engine. Without a shim, `orch` calls the bundled engine directly. `ORCH_CREATE_ENGINE` / `ORCH_RETIRE_ENGINE` override the bundled paths (tests). Both still work on their own for worktrees outside tickets. For tickets, platform steps (Herdr workspace close, Orca terminals) belong to the adapters, which run them before calling the engine. The retire engine still closes a worktree's Herdr workspace itself (best-effort, before the DDEV step), so a manual retire leaves no Herdr tab on a deleted folder; under `orch` the adapter has already closed it, so the engine finds none. Otherwise the engines keep only git, DDEV, composer, DB import and project hooks. `retire-worktree.sh` takes `--ddev-only` (with or without `--force`): it skips the Herdr close, runs the uncommitted-work check and the DDEV delete (or the project's retire hook), and leaves the checkout and branch for the platform to remove (Orca). Both engines run under macOS `/bin/bash` 3.2; their own test suites (`skills/create-worktree/tests/run-all.sh`) need bash 4 or later.

## Commands this round adds or changes

| Command | Effect |
|---|---|
| `orch spawn <ticket> --brief-file F [--worktree P]` | Without `--worktree`, the adapter's `create_worktree` makes it first. With `--worktree`, it uses the existing one, as today. |
| `orch retire <ticket> [--force] [--keep-worktree]` | `close`, then signal any session still alive by the identity check, then remove the folder trust `orch` added and `remove_worktree` (both unless `--keep-worktree`), then mark retired. `remove_worktree` refusing (uncommitted work) leaves the ticket un-retired, exits 3 and says why. |
| `orch watch [--interval S]` | Redraw a table of every non-retired ticket (id, platform, phase, health, last activity, review rounds) every `S` seconds (default 5) until interrupted. `--once` prints one frame (tests); `--once --json` prints `{"tickets": [{"id", "platform", "phase", "health", "last_seen_at", "review_rounds"}]}`. |
| `orch selftest [--keep] [--timeout S] [--harness H]` | Below. |
| `orch selftest --continue <run-id> --answer <json>` | Desktop only: the main orchestrator reports the result of an action. |

## `orch selftest`

Proves, on the resolved platform in the current repo, that the whole lifecycle works and leaves nothing behind. It uses a throwaway ticket `selftest-<8 hex>` and a real session on the resolved harness (`claude`, `pi` or `codex`; `--harness` overrides) with a tiny brief:

> You are a selftest session. Run `orch phase <ticket> spec`, then stop. Do nothing else.

Steps. Each one records `pass`, `fail` or `skip` with a detail. A failure stops the run and jumps to teardown.

1. **preflight**: platform resolves, platform binary present, `BASE_BRANCH` set.
2. **create**: `create_worktree`; the directory exists and is a git worktree on a new branch.
3. **launch**: `launch(start)`.
4. **report-in**: within `--timeout` (default 180 s), a `SessionStart` hook attached the session (pid recorded, health not `none`).
5. **state**: the session ran `orch phase <ticket> spec` (proves it can call `orch`, so permissions are enough).
6. **visible**: `visible()` says the worktree and the session both show up natively.
7. **kill**: kill the session's process; health becomes `dead` and `stale` lists the ticket.
8. **resume**: `launch(resume)`; a `SessionStart` with the same session id arrives and health is alive again.
9. **teardown**: `retire --force` (unless `--keep`), which removes the folder trust `orch` added. On Herdr it then closes the main checkout's workspace (`herdr workspace close <id>`) when selftest opened it: before `create`, the run state records whether `herdr workspace list` showed a workspace whose `worktree.checkout_path` is the main checkout (realpath); when none was, right after the launch it records the id of the main checkout workspace the launch opened (`main_ws_opened_id`). Teardown closes only that id, and only while it is still the main checkout's workspace; a main checkout workspace under another id (closed and reopened meanwhile) is not selftest's and stays. With no recorded id nothing is closed. A workspace open before is never closed. When that check errors, it counts as open (never close what selftest cannot prove it opened) and the teardown detail says so. A failed close fails teardown.
10. **clean**: nothing is left: no live process for the session id, `visible()` reports nothing, the worktree directory and branch are gone, no DDEV project named for it remains, and the platform lists no terminal, workspace or agent for it, and no folder-trust entry `orch` added (a `trust_mark` event) is left in Claude's user config. On Herdr, the main checkout workspace selftest opened (the recorded id) is gone (a `workspace list` error is `main checkout workspace state unknown`, a failure); one open before selftest is only noted if it is no longer open, never a failure. Then the selftest ticket's rows and files (`briefs/`, `logs/`) are deleted.

Teardown and the clean check run even after a failure (unless `--keep`). Steps after a failure, before teardown, are recorded `skip`. With `--keep`, teardown and clean are `skip` and do not count against `ok`; without anything created (preflight failed), they are `skip` too. Output is a checklist; `--json` gives `{"run": id, "platform": ..., "steps": [{"name", "status", "detail"}], "ok": bool}`. Exit 0 only when `ok`, else 3. `report-in` requires the hook (`session_seen`), not just a recorded pid. The DDEV check runs only when `ddev` is on `PATH` (`ddev list --json-output`, by approot).

Teardown never relies on the ticket row alone. Before `create` runs, the run state records the worktree name; after it, the path and any Orca ref. A failed launch puts the row's `worktree` back to null, so when the row names no worktree, teardown closes whatever the row's `launch_ref` names and removes the recorded worktree itself (first the folder trust `orch` added for it, then `remove_worktree` with force; found by name in `git worktree list` when an interrupted create recorded no path), plus a new branch of that name left without a worktree; then it retires the ticket.

`clean` fails when it cannot tell: a platform command that errors makes `visible()` answer `unknown` for that half (except Herdr's `agent_not_found` and Orca's `selector_not_found` on `terminal list`, which mean gone), and `unknown` fails the check. `ddev` not on `PATH` is fine; `ddev list` exiting non-zero or printing no JSON is `DDEV state unknown`, a failure. The session-process check uses the run's session id, else the ticket row's (read before the rows are purged), so it also runs after a folder-trust block. Claude's user config that cannot be read while a `trust_mark` path is to be checked is `folder-trust entry state unknown`, a failure. The rows and files are purged even when a check raises.

**Interrupts.** Ctrl-C (SIGINT) or SIGTERM during a selftest fails the step in progress (`interrupted (SIGINT)` / `interrupted (SIGTERM)`), skips the rest, then runs teardown and clean, each guarded so an error in one never skips the other (on Desktop they do what they can without waiting for an action). The run is kept in `selftest_runs`, the report is printed (with `"interrupted"` in `--json`, `ok` false), and `orch` exits 130 (SIGINT) or 143 (SIGTERM). An error (not an interrupt) in any step fails that step and the run carries on to teardown and clean as before.

**Desktop.** `orch` can't open or inspect Desktop sessions, so selftest runs in turns. Whenever a step needs the main orchestrator, it saves its progress (table `selftest_runs` in the state DB, under the run id) and exits 0 with `{"run": id, "action": ..., "ticket": ..., ...}`. The orchestrator carries out the action and calls `orch selftest --continue <run-id> --answer '<json>'` (an unknown run exits 4). The run ends when the output has `ok` instead of `action`. Actions, in order, and the answers read:

| Action | Orchestrator does | Answer |
|---|---|---|
| `desktop_start` (`cwd`, `prompt_file`, `title`) | start a session there with that prompt | `{"ok": true, "ref": <desktop session id>}` |
| `desktop_check` (`cwd`, `title`, `ref`) | list sessions; does the worktree's session show? | `{"worktree": bool, "session": bool}` |
| `desktop_stop` (`ref`) | stop the session | `{"ok": true}` |
| `desktop_resume` (`cwd`, `prompt_file`, `ref`) | resume the session with that prompt | `{"ok": true}` |
| `desktop_archive` (`ref`) | archive the session | `{"ok": true}` |
| `desktop_check` again (clean) | as above; both should now be false | `{"worktree": bool, "session": bool}` |

`"ok": false` (with an optional `"detail"`) fails the step.

**Cost.** One short real session plus one resume. Run it at setup, after changing platform or permissions, and when something seems off.
