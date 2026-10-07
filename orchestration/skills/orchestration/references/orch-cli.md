# `orch` state CLI

`orch` is the plugin's state script: `scripts/orch` (`${CLAUDE_PLUGIN_ROOT}/scripts/orch` in Claude Code), Python 3.9+ standard library only. It is the only writer of ticket state. Agents read state through it before every decision and never edit the database by hand.

`orch` does not need to own a session's process to watch it. The plugin's hooks report every session's activity to `orch` (see "Hooks"), so a session started by `orch`, Orca, Herdr, Claude Desktop or a person typing `claude` is tracked the same way.

## Where state lives

State lives in the **project root** under `.agents/orchestration/`, outside any git repository. The project root is the folder directly under `ORCH_PROJECTS_DIR` (default `~/Projects`) that holds the cwd, so `orch` runs from the project root, the main checkout or any worktree. A worktree outside the project root is traced through its main checkout (`git rev-parse --git-common-dir`). `ORCH_HOME` overrides the directory (used by tests).

The project root also holds `.orch` (written by the `setup-project` skill). `orch` reads `BASE_BRANCH` and `MAIN_CHECKOUT` from it: environment first, then `.orch`. Without `MAIN_CHECKOUT`, the main checkout is the one folder in `WORKTREE_ROOT` (default `code`) whose `.git` is a directory.

| Path | Holds |
|---|---|
| `state.db` (+ `-wal`, `-shm`) | SQLite store: tickets and the append-only event log |
| `logs/<ticket>.log` | Output of headless ticket sessions (appended across attempts) |
| `briefs/<ticket>.md`, `briefs/<ticket>.resume.md` | Prompt given to the session by `spawn` / `resume` |
| `config.json` | Optional project settings (below) |

SQLite runs in WAL mode with a busy timeout. Every command is one transaction, so a killed process leaves either the old state or the new one, never half. Writes take `BEGIN IMMEDIATE`; read-only commands (`list`, `show`, `next`, `stale`, `events`, `platform`, `watch`) use a plain deferred read. `spawn`, `resume` and `retire` are the exception: they never hold the write lock while a platform command or worktree engine runs, and hold the ticket's in-flight marker instead (see "Launching sessions"). Older databases gain new columns automatically on first use.

### `config.json`

```json
{
  "max_workers": 3,
  "claude_args": ["--dangerously-skip-permissions"],
  "verify_harness": "docker compose -f .agents/orchestration/verify.yml up -d",
  "stall_minutes": 20
}
```

Ticket sessions run unattended, so by default they skip permission prompts: without that, every push, merge and worktree command stops and waits. A project can set a narrower `claude_args` here. All keys are optional. Defaults: `max_workers` 3, `claude_args` as shown, `verify_harness` unset, `stall_minutes` 20. A `config.json` that is not a valid JSON object makes any command that reads it exit 3 with the path and parse error.

## Platforms

A **platform** is what hosts the sessions: `headless`, `orca`, `herdr` or `desktop`. The platform running the main orchestrator runs every ticket session it starts. Stage agents always run inside their ticket session.

`orch platform` prints the platform, first match wins: `ORCH_PLATFORM` (must be one of the four, else exit 2); the platform the environment shows: `HERDR_ENV=1` → `herdr`, `ORCA_TERMINAL_HANDLE` or `ORCA_WORKTREE_ID` set → `orca`, `CLAUDE_CODE_ENTRYPOINT=claude-desktop` → `desktop`; otherwise `headless`. Nothing is saved between calls (see [platforms.md](platforms.md) "Platform resolution").

Each ticket records the platform it was launched on. It keeps it while its session is alive. A ticket whose session is dead may be resumed on a different platform with `resume --platform`.

Binaries: `ORCH_CLAUDE_BIN` (default `claude`), `ORCH_ORCA_BIN` (default `orca`), `ORCH_HERDR_BIN` (default `herdr`). Claude's user config (folder trust, below): `ORCH_CLAUDE_JSON`, else `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`; tests always set `ORCH_CLAUDE_JSON` to a temp file.

## Harnesses

A **harness** is the agent CLI a session runs: `claude` (Claude Code), `pi` or `codex`. Ticket sessions run on the main orchestrator's harness. It is independent of the platform: any harness runs on `headless`, `orca` and `herdr`; `desktop` hosts `claude` only (anything else exits 3).

The harness is, first match wins: `--harness` on `spawn`, `resume` and `selftest`; `ORCH_HARNESS` (one of the three, else exit 2); detection from the environment the main orchestrator's shell inherits: `PI_CODING_AGENT=true` → `pi`, `CODEX_THREAD_ID` set → `codex`, `CLAUDECODE=1` → `claude` (when several are set, one harness started inside another, the nearest harness process above `orch` decides); the machine config's `harness` (`orch setup --harness`). With none, `claude` (source `default`). `orch platform` and `preflight` print `harness` and `harness_source`; `preflight` also checks the harness binary for `pi` and `codex`.

Each ticket records its harness (`harness`, null meaning `claude`). `resume` keeps it, or moves a dead ticket with `--harness`, which always starts a fresh session from the brief.

| | `claude` | `pi` | `codex` |
|---|---|---|---|
| Binary | `ORCH_CLAUDE_BIN` | `ORCH_PI_BIN` (default `pi`) | `ORCH_CODEX_BIN` (default `codex`) |
| Args from `config.json` | `claude_args` | `pi_args` (default `["--approve"]`) | `codex_args` (default `["--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--enable", "hooks"]`) |
| Prompt prefix | `/orchestration:orchestration ` | `/skill:orchestration ` | `$orchestration:orchestration ` |
| Session id | chosen by `orch` | chosen by `orch` (`--session-id`, which also resumes) | chosen by Codex: null until the `SessionStart` hook names the thread |
| Headless start | `claude -p --session-id <sid> --output-format stream-json --verbose <args>` | `pi -p --mode json --session-id <sid> <args>` | `codex exec --json <args> -` |
| Headless resume | `claude -p --resume <sid> ...` | same as start | `codex exec resume --json <args> <thread> -` |
| Interactive (orca, herdr) | `claude --session-id\|--resume <sid> <args>` | `pi --session-id <sid> <args>` | `codex <args>`; resume: `codex resume <args> <thread>` |
| Hooks | `hooks/hooks.json` | `pi/extension.ts` (Pi package) | `hooks/hooks.json` (Codex plugin) |
| Folder trust (orca, herdr) | `~/.claude.json` | none needed | `$CODEX_HOME/config.toml` |

The skill is user-invoked only on every harness, so the prompt prefix loads it. The resume prompt carries it too on Pi and Codex (a session killed before its first turn was saved has no skill loaded); on Claude it is plain text, as before.

- **Pi** sets its process title to `pi`, so the session id is not on its command line: a headless launch records the start time (`pid_start`) with the pid. The Pi extension runs `orch hook` with `ORCH_HOOK_AGENT_PID` set to the Pi process. Subagent children (`PI_SUBAGENT_CHILD=1`) report `PostToolUse` under the parent session's id, as Claude's subagents do. A launch drops the `PI_SUBAGENT_*` and `ORCH_PI_PARENT_SESSION` variables from the child's environment. Stage agents get the Pi model their tier names: `opus` → `openai-codex/gpt-6-astra`, `sonnet` → `openai-codex/gpt-6.1-sol`, `haiku` → `openai-codex/gpt-6-luna`, plus the matching thinking level (`high`, `medium`, `low`). The reviewer and verifier take the `sonnet` model with `high` thinking. The reporter takes the `haiku` tier: `gpt-6-luna`, `low`. The machine config's `pi_models` (`{"opus": "<provider>/<model>", ...}`) overrides the map. A model the session's model registry does not know is left out, so that agent runs on the session's model. The implementor gets no model: its dispatcher passes one. A `model` in the `subagent` call still wins.
- **Codex** picks its thread id. `spawn` records `session_id` null; the first `SessionStart` attaches the thread: on `headless` only from the process `orch` launched (the hook waits up to 3 s for step 3 to record its pid), on `orca`/`herdr` the first session to report in. A headless session killed before its hook ran is still found: `resume` reads the last `thread.started` line of the ticket's log. Resume continues the thread only when Codex saved it (`$CODEX_HOME/sessions/*/*/*/rollout-*-<thread>.jsonl`); otherwise it starts fresh from the brief. On `orca` and `herdr`, `orch` appends `[projects."<worktree realpath>"]` / `trust_level = "trusted"` to `$CODEX_HOME/config.toml` (default `~/.codex`) when the file has no table for that path, records it as `trust_codex` and a `trust_mark` event (detail `codex <path>`), and removes exactly that table on retire (Codex ignores `-c projects…` overrides for the trust dialog). The same signature-checked temp-file replace and retries as for Claude's config apply; a missing file is created.

## Phases

One `phase` per ticket. `status` is derived from it and never stored separately.

| Phase | Status | Set by |
|---|---|---|
| `ready` | ready | `orch add` |
| `dispatched` | in_progress | `orch spawn` |
| `spec`, `tests`, `implement`, `fix` | in_progress | ticket orchestrator via `orch phase` |
| `review` | in_review | ticket orchestrator |
| `verify`, `report`, `mr`, `ci` | verified | ticket orchestrator |
| `done` | done | `orch merged` only |
| `blocked` | blocked | `orch block` |

Allowed `orch phase` transitions (anything else exits 3):

```
dispatched -> spec
spec       -> tests | implement        (implement = skip lane: trivial or no-code)
tests      -> implement
implement  -> review
review     -> fix | verify | report    (report = no-code lane)
fix        -> review | ci
verify     -> fix | report
report     -> mr
mr         -> ci
ci         -> fix | mr
```

- Entering `review` adds 1 to `review_rounds`.
- `review -> fix` and `verify -> fix` are refused once `review_rounds` is 2 or more (the cap). The refusal says to file the remaining findings as follow-up tickets and move on to `verify`.
- `ci -> fix` is never capped; CI repairs are not review rounds. `fix -> ci` returns straight to CI after such a repair.
- `done` is reachable only through `orch merged`.

## Session health

Every ticket shows `health`, derived on read:

| Health | Meaning |
|---|---|
| `none` | No session yet (`ready`, or `dispatched` before any session reported in) |
| `working` | Alive, and the last activity is a tool call or session start within `stall_minutes` |
| `idle` | Alive, and the last activity is a `Stop` (turn finished, waiting) |
| `stalled` | Alive, `working`, but no activity for longer than `stall_minutes` |
| `dead` | Not alive |

**Alive** means all of:

- a process id is recorded, and that process exists;
- it is the same process: when a process start time was recorded, `ps -o lstart= -p <pid>` still matches it; otherwise its command line (`ps -ww -o command= -p <pid>`) contains the session id as an argument;
- the last activity is not `ended` (a `SessionEnd` hook).

Every `ps` call runs with `LC_ALL=C` and `TZ=UTC`, so a start time recorded by the hook compares equal from any process whatever its time zone or language.

A pid reused by an unrelated process is therefore not alive: `stale` lists the ticket, `resume` is allowed, and `retire` does not signal it.

## Hooks

The plugin ships `hooks/hooks.json`, which runs `orch hook` on `SessionStart`, `PostToolUse`, `Stop` and `SessionEnd` in **every** session where the plugin is enabled. `orch hook` reads the hook's JSON from stdin (`session_id`, `cwd`, `hook_event_name`, `source`, `reason`).

It must never disturb a session: it always exits 0, prints nothing except on `SessionStart` for a matched ticket, catches every error, and returns at once when there is no `<project root>/.agents/orchestration/state.db` for `cwd`. It matches under a plain read and takes the write lock (`BEGIN IMMEDIATE`) only when it is about to write, re-checking the ticket under the lock.

**Matching.** The hook belongs to the non-retired ticket whose worktree (realpath) equals `cwd` or contains it. No match → do nothing, so the main orchestrator (in the project root or the main checkout) is never matched. A row whose worktree is a main checkout (its `.git` is a directory) never matches either. Then:

- `SessionStart` on a `done` ticket writes and prints nothing.
- `SessionStart` from a session id other than the recorded one takes the ticket over (logged as an `attach` event) only when the recorded session is not alive, or the hook's Claude process is the recorded pid (`/clear` starts a new session id in the same process). Otherwise it is ignored entirely and prints nothing, so a second session opened in the worktree cannot hijack a live ticket session.
- **Hijack window.** Until the launched session has reported in (`session_seen` is 0), a `SessionStart` from another session id never takes over a `headless`, `orca` or `herdr` ticket, alive or not: that ticket's own session id is known and its `SessionStart` is on the way. A `desktop` ticket still allows it, since Desktop picks the session id. So does a `codex` ticket with no session id yet (see "Harnesses").
- Other events from a session id other than the recorded one are ignored.

**Process id.** The hook records the harness process it runs under (Claude's described here; `pi` and `codex` are recognised the same way by name). The Pi extension names its process in `ORCH_HOOK_AGENT_PID`, which replaces the walk. Otherwise: walk up from the hook's parent process (at most 8 levels) to the first process that is Claude, and record that pid and its `lstart`. A process is Claude when its executable (`ps -o comm=`, the path; it may contain spaces, as on Desktop) has basename `claude` or contains `/claude/versions/` (the native installer runs `~/.local/share/claude/versions/<version>`), or its command line's first word has basename `claude`, or that first word is a script runtime (`node`, `bun`, `deno`, `python…`) whose first non-option argument is a script file with basename `claude` (an npm install; a script with a shebang shows its interpreter on macOS). Shells (`sh`, `bash`, `zsh`), shell strings (`-c '…'`) and modules (`python -m claude`) are not Claude. The walk runs only after a ticket matched, and only on `SessionStart`. When the walk finds nothing for the recorded session id, or finds a process whose start time `ps` cannot read, the recorded pid and start time are kept as a pair. Test override: `ORCH_HOOK_CLAUDE_PID=<pid>` replaces the walk; `ORCH_HOOK_CLAUDE_PID=none` means "the walk found nothing".

| Event | Writes |
|---|---|
| `SessionStart` | session id (if it takes over: `attach` event), pid + start time (kept when the walk finds nothing), `session_seen`=1, activity `working`, `last_seen_at`. Prints the context line `You are the ticket orchestrator for <ticket>. Run \`orch show <ticket>\` before anything else.` Nothing on a `done` ticket or an ignored session. |
| `PostToolUse` | activity `working`, `last_seen_at`. Skipped when the activity is already `working` and `last_seen_at` is under 15 s old (keeps hooks cheap). |
| `Stop` | activity `idle`, `last_seen_at` |
| `SessionEnd` | activity `ended`, `last_seen_at`, `session_end` event with the reason |

Only `SessionStart` and `SessionEnd` write events; activity updates do not.

## Launching sessions

`spawn` and `resume` start a session on a platform:

| Platform | How `orch` starts it | `launch_ref` recorded |
|---|---|---|
| `headless` | `claude -p --session-id <sid> --output-format stream-json --verbose <claude_args>`, prompt on stdin from the brief file, detached in its own process group, output to `logs/<ticket>.log`. Pid recorded at once. | `{"pid": <pid>}` |
| `orca` | `orca terminal create --worktree path:<worktree> --title t<ticket> --command '<cmd>' --json`, then `orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 20000 --json` (folder-trust check, below) | `{"terminal": <handle>}`, the first string value under a key named `handle` in the JSON reply |
| `herdr` | `herdr worktree open --cwd <main checkout> --path <worktree> --label t<ticket> --no-focus`, then `herdr agent start <agent> --kind claude --pane <root pane id> -- <session args> <claude_args>`, then `herdr agent prompt <agent> '<prompt>'` | `{"workspace": <id>, "pane": <id>, "agent": <agent>}` from `.result.workspace.workspace_id` and `.result.root_pane.pane_id`; `<agent>` is `t` + the lowercased ticket id with characters outside `[a-z0-9_-]` turned into `-`, cut to 32 characters |
| `desktop` | Nothing: `orch` cannot open a Desktop session. It records the intent and prints an action for the main orchestrator. | set later by `orch attach --ref` |

For `orca`, `<cmd>` is an interactive session: `claude --session-id <sid> <claude_args> "$(cat '<brief file>')"` (shell-quoted). For `herdr`, Herdr starts `claude` itself (`--kind claude`, so `ORCH_CLAUDE_BIN` does not apply) and the prompt goes in with `agent prompt`. The pid arrives with the `SessionStart` hook.

- The terminal's shell must understand `"$(cat …)"`: a POSIX `sh`-compatible shell (bash, zsh) or fish 3.4 or later.
- The prompt is one command-line argument, so a prompt (brief, or resume prompt with its note) over 128 KB (131072 bytes) is refused on `orca` and `herdr` with exit 3 before step 1.
- Herdr exits 0 even when a command fails: any reply with a top-level `"error"` is a failure. Orca fails with a non-zero exit and `"ok": false`.

**Folder trust.** Interactive `claude` in a folder Claude has not trusted stops at the "trust this folder" dialog (headless `-p` does not). On `orca`, the `terminal wait` reply then carries `blockedReason: "agent-trust-workspace"` (the wait can add up to 20 s to each orca launch); on `herdr`, `agent start` replies with error code `agent_not_ready` ("blocked during startup"), or `agent prompt` with `agent_blocked`, and it counts as the trust block only when the error or the agent's screen (`herdr agent read <agent> --source visible`) mentions "trust"; any other block is a plain launch failure. To keep it from happening, `orca` and `herdr` launches (start and resume, not headless or desktop) first mark the worktree trusted in Claude's user config: `projects[<worktree realpath>].hasTrustDialogAccepted = true`, other keys untouched, written to a temp file with the original's mode and `os.replace`d, then re-read and retried (3 writes at most) when a concurrent claude dropped it. A missing or invalid config file is never created or overwritten: a warning (never the file's contents), no mark, and the launch goes on. The ticket's `trust_marked` (0 nothing, 1 the key, 2 the whole entry) and a `trust_mark` event record what `orch` added; trust that was already there is not recorded and never removed. A launch that fails in step 2 removes the trust it added. Details in [platforms.md](platforms.md) "Folder trust". If the dialog still appears, `orch` records the launch (step 3 runs, plus a `trust_prompt` event), leaves the terminal or workspace open, and exits 3 with `claude is waiting at the folder-trust prompt in <worktree>; open that terminal and accept it once (orch could not mark the folder trusted)`. Once accepted, the session reports in through the hook as usual. On `herdr` the prompt was not sent yet: the message adds the `herdr agent prompt` command that sends it.
- No `--` is placed before the prompt: `claude --help` does not document `--` as end of options. A brief that starts with `-` could be read as an option; start briefs with text.

For `desktop`, `spawn` and `resume` exit 0 and print `{"action": "desktop_start", "cwd": ..., "prompt_file": ..., "title": "t<ticket>"}` (resume: `"action": "desktop_resume"`, plus `"ref"` when one is recorded). The main orchestrator starts or messages the Desktop session itself, then runs `orch attach <ticket> --ref <desktop session id>`. The session id and pid arrive with the `SessionStart` hook.

**Steps.** (1) Commit the intent: phase, platform, session id, worktree, attempt, pid NULL, event, and the in-flight marker (below). (2) Start it. (3) Commit the pid (headless) and `launch_ref`, and clear the marker. On `orca` and `herdr` step 3 has no pid; a `SessionStart` hook that arrived during step 2 (Orca's trust wait, Herdr's `agent start` and `agent prompt`) already recorded the session's pid and start time, and step 3 keeps them. A crash after step 1 leaves the ticket active with no live session, so `stale` lists it. If step 2 fails (binary missing or not executable, worktree gone, platform command exits non-zero or its JSON lacks the id), step 3 restores the ticket exactly as it was, removes the events written in step 1, and the command exits 3 with `cannot start <what> in <cwd>: <error>`. One exception: when a resume closed the old orca terminal or herdr workspace before the failed start, `launch_ref` is restored as null, not as a ref to the closed one. A herdr reply that names a workspace but no root pane, or a failed `agent start` (other than the trust block) or `agent prompt`, closes that workspace before the refusal, unless `worktree open` reported it `already_open`; then, if the agent had started (a failed `agent prompt`, or `agent_not_ready`), `herdr pane close <root pane>` stops it. An orca `terminal create` whose reply names no handle runs `orca terminal close --worktree path:<worktree> --all --json` before the refusal. When `spawn` created the worktree itself (no `--worktree`), a failed launch also removes that worktree again. Writing the prompt file happens before step 1, so a failure there changes nothing. An empty or whitespace-only brief is refused with exit 3 before step 1.

**In-flight marker.** `spawn`, `resume` and `retire` release the write lock while platform commands and engines run, so each first claims the ticket: the `launching` column holds `{"token", "op", "pid", "pid_start", "at"}` (the orch process and when). `spawn` claims it before creating a worktree, `resume` in step 1, `retire` before it closes anything. While a ticket holds a live marker, `spawn`, `resume` and `retire` (with or without `--force`) on it exit 3 with `launch in progress for <ticket>: orch pid <pid> started a <op> at <time>; ...`; so does a `spawn` without `--worktree` of another ticket with the same worktree name. The owner clears the marker in step 3, in the step-2 rollback, when retire finishes or fails, and on any error or interrupt. A marker older than 10 minutes, or whose orch process is gone (pid not running, or running with another start time), is abandoned and ignored, so a crash mid-launch never wedges the ticket.

**Resume prompt.** When the session has reported in before (`session_seen`, or for headless a log line carrying the session id), resume continues it: `--resume <sid>` with a prompt telling the session to run `orch show <ticket>` first. Otherwise it starts fresh with `--session-id <same sid>` and the stored brief. `--note` text is appended to either prompt. A fresh start with no stored brief exits 3 (`no stored brief; re-spawn`).

**Resume on `orca` / `herdr`** first closes the old terminal or workspace when `launch_ref` names one (best effort, ignore errors): `orca terminal close --worktree path:<worktree> --all --json`, `herdr workspace close <workspace>`. Then it opens a new one the same way as `spawn`. Resuming onto `desktop` keeps `launch_ref` only when it is a Desktop ref; any other ref is cleared.

## Commands

Every command accepts `--json` (one JSON object on stdout). Exit codes: `0` ok, `2` usage, `3` gate refused, `4` ticket not found, `5` preflight failed. Refusals print the reason on stderr.

| Command | Who | Effect |
|---|---|---|
| `orch init` | main | Create the directory and database. Safe to re-run. |
| `orch platform` | any | `{"platform": ...}` per "Platforms", and `harness`, `harness_source` per "Harnesses". |
| `orch preflight` | main | Exit 0 and print `verify_env` (`ddev` or `docker`), `base_branch` and `platform`. Exit 5 listing every failure. Checks: `BASE_BRANCH` set in the environment or `.orch` (an optional `export ` prefix is allowed; a quoted value is the text inside the quotes, an unquoted value ends at the first whitespace-then-`#` comment); verification environment is `ddev` when the main checkout has `.ddev/config.yaml` **and** `ddev` is on `PATH`, else `docker` when `config.json` has `verify_harness` **and** `docker` is on `PATH`, else failure; the platform's binary (`orca` or `herdr`) is on `PATH` when the platform needs one. |
| `orch add <ticket> --title T [--url U]` | main | New ticket in `ready`. Exit 3 if it exists. Exit 2 unless the id matches `^[A-Za-z0-9][A-Za-z0-9._-]*$` with no `..` (it names files under `logs/` and `briefs/`). |
| `orch list` | any | All tickets: id, phase, status, platform, health, activity, last_seen_at, review_rounds, pid, alive, retired. |
| `orch show <ticket>` | any | One ticket in full, including `alive`, `health` and `launch_ref`. |
| `orch next` | main | `ready` tickets, oldest first, limited to `max_workers` minus active tickets. Active = not `ready`/`done`/`blocked` and not retired. |
| `orch spawn <ticket> [--worktree P] --brief-file F [--platform X] [--harness H]` | main | Requires `ready`. Without `--worktree`, the platform adapter creates the worktree first ([platforms.md](platforms.md)). Exit 3 if the realpath of `P` is the main checkout or contains it, lies inside the main checkout without being a linked worktree of its own (`git rev-parse --show-toplevel` there is the main checkout), or equals, contains or lies inside the worktree of another non-retired ticket that is not `ready` or `done`. Exit 3 while a launch is in progress (in-flight marker). Stores the brief, then launches per "Launching sessions" on `--platform` (default: the configured platform). Phase `dispatched`, attempt 1. |
| `orch resume <ticket> [--note N] [--platform X] [--harness H]` | main | Exit 3 if the session is alive, a launch is in progress (in-flight marker), or the ticket is `ready`, `done` or retired. A `blocked` ticket first returns to its remembered phase (`unblock` event). Attempt + 1, then launches per "Launching sessions" on the ticket's platform, or `--platform`. |
| `orch attach <ticket> [--ref R] [--session-id S]` | main | Record a Desktop session ref (stored as `{"desktop": R}`) and/or a session id for a session `orch` did not start. Writes an `attach` event. |
| `orch stale` | main | Active tickets whose health is `dead`, including `dispatched` ones nobody reported in for: the recovery list. An `orca`, `herdr` or `desktop` ticket that no session has reported in for yet (no pid) is listed only once `stall_minutes` have passed since its launch, since its pid only arrives with the first hook. |
| `orch hook` | hooks | See "Hooks". |
| `orch phase <ticket> <phase> [--note N]` | ticket | Validated transition (table above). |
| `orch block <ticket> --reason R` | either | Phase `blocked`; remembers the prior phase. |
| `orch unblock <ticket>` | either | Back to the remembered phase. Exit 3 if there is none. |
| `orch ci <ticket> --sha S (--passed \| --failed)` | ticket | Records the CI verdict for that commit. Requires phase `ci`. |
| `orch merged <ticket> --sha S` | ticket | Requires phase `ci`. Exit 3 unless the latest CI verdict for exactly `S` is `passed`. Then phase `done`. |
| `orch retire <ticket> [--force] [--keep-worktree]` | main | Requires `done` (or `--force`) and no launch in progress; holds the in-flight marker while it runs, so no `resume` launches meanwhile. Closes what the platform opened. `headless`: signals the session's process group (SIGTERM, SIGKILL after 3 s) when alive and leading its group. `orca`: `orca terminal close --worktree path:<worktree> --all --json`. `herdr`: `herdr workspace close <workspace>`. Platform close errors are reported but don't block retiring. After closing, a session still alive by the identity check is signalled. Then, unless `--keep-worktree`, removes the folder trust `orch` added for the worktree (the key, or the entry it created; a failure only warns) and removes the worktree, branch and DDEV project through the platform adapter (see [platforms.md](platforms.md)); a refusal there (uncommitted work without `--force`) leaves the ticket un-retired and exits 3. Then sets `retired_at`. `desktop`: prints `{"action": "desktop_archive", "ref": ...}` for the main orchestrator to archive the session. |
| `orch watch [--interval S] [--once]` | any | Live table of non-retired tickets; see [platforms.md](platforms.md). |
| `orch selftest [...]` | main | Lifecycle self-check; see [platforms.md](platforms.md). |
| `orch events <ticket>` | any | The ticket's event log, oldest first. |

Every state change appends an event: timestamp, ticket, kind, from phase, to phase, detail.
