# Orchestration design

Background for the `orchestration` skill: why it is laid out this way, and what is still open. Read it when changing the plugin, not when running a ticket.

## Purpose and scope

The script layer (`orch`) is the deterministic code that holds ticket state and phase gates. Agents call it; they never replace it. The goal is that a ticket survives a dead process, a laptop sleep or a network drop and is picked back up where it was.

- **In scope:** the main orchestrator loop, the per-ticket orchestrator, durable state, phase gates, spawning and resuming sessions, recovery.
- **Out of scope:** ticket ordering and surface-area grouping (another plugin sorts tickets so their touch points stay contained), file locks, and verification-gate tooling such as no-mistakes.
- **Constraints:** personal use, macOS and Linux, one instance per project, state under `.agents/orchestration` in the project root (`~/Projects/<project>`), outside git.

## Design principles

State and gates are scripted and never judged; agents judge only the actions they take on top of freshly read state.

1. **Determinism where it counts.** Phase transitions, the review cap and the merge gate live in code.
2. **State is recorded and read, never inferred.** An agent reads `orch show` fresh, never its memory across turns.
3. **Judgment on actions is allowed.** An ambiguous review comment or an out-of-scope test failure is handled by the ticket orchestrator, so tickets do not get stuck.
4. **No friction by default.** Linting and project rules are opted into per project.
5. **Merge binds to a commit.** `orch merged` requires a recorded CI pass for that exact SHA.

## Hierarchy

```
user
 └─ main orchestrator (interactive session)          one per project
     ├─ orch (state script, SQLite)                  the only state writer
     └─ ticket orchestrator (claude, same platform)  one per ticket, in its worktree
         └─ stage agents: test-writer, implementor, reviewer, verifier, reporter
```

The main orchestrator does traffic control: preflight, add, dispatch, resume, retire. It never does ticket work. Each ticket orchestrator walks one ticket from spec to squash-merge.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Script language | Python 3.9+, stdlib only | Built-in SQLite transactions, the same behaviour on macOS and Linux (no BSD/GNU drift), solid process control, testable |
| State store | SQLite (WAL) in `<project root>/.agents/orchestration/state.db`, outside git | One transaction per command, so a kill leaves old or new state, never half |
| Platforms | `headless`, `orca`, `herdr`, `desktop`. The main orchestrator's platform hosts its ticket sessions; a ticket keeps its platform while its session lives | One clear owner per run; you watch tickets where you already work |
| Session launch | `orch spawn` starts the session on the platform with a fixed `--session-id`; on Desktop it hands the main orchestrator an action instead, because only an agent can open a Desktop session | The session id is known before the session starts, so `orch` can match and `--resume` it |
| Monitoring | Plugin hooks (`SessionStart`, `PostToolUse`, `Stop`, `SessionEnd`) report each session to `orch`; liveness checks the reported pid and its start time | `orch` watches sessions it didn't start, on every platform, and a reused pid is never mistaken for a live session |
| File locks | None | Merge conflicts are resolved by the ticket orchestrator; another plugin keeps ticket surface areas apart |
| Review cap | 2 rounds, then remaining findings become follow-up tickets and the ticket finishes | Bounded cost per ticket; nothing waits on the user |
| Inline fixes | Go to a fresh implementor | Fresh context sees the finding, not the earlier reasoning |
| Done | Squash-merged into `BASE_BRANCH` (the integration branch) after CI passes on that SHA | Review approval is not done; a green merge is |
| Who merges | The ticket orchestrator, via MR | Keeps each ticket's evidence on its MR |
| Who retires | The main orchestrator, after `done` | A ticket session never deletes the ground it stands on |
| Verification | DDEV if the project has it, else the project's Docker harness, else preflight stops before anything starts | Verification is never silently skipped |
| Session permissions | Ticket sessions run with `--dangerously-skip-permissions` by default; a project can narrow `claude_args` | Unattended tickets otherwise stop at every push, merge and delete |
| Skill invocation | `disable-model-invocation: true`; `orch` starts each fresh ticket prompt with `/orchestration:orchestration` | Orchestration launches sessions, worktrees and merges, so only a person starts it. Ticket sessions load it through the command, not the Skill tool |
| Blocked tickets | Keep their worktree | The next attempt reads the partial diff |
| Folder trust | orch marks each Orca/Herdr ticket worktree trusted in Claude's user config before launch and removes it on retire | Interactive claude asks per new folder; unattended tickets can't answer |
| Harnesses | One `orch` with a harness switch: `claude`, `pi`, `codex`. Ticket sessions run on the main orchestrator's harness (`--harness`/`ORCH_HARNESS`, else detected; never saved); harness and platform are independent, except Desktop is Claude-only | One state model, one hook contract and one selftest for every harness; the user works where they already are |
| Skill on Pi and Codex | Same skill, user-invoked only everywhere: Pi package (`package.json` `pi` manifest), Codex plugin (`.codex-plugin/plugin.json`, `agents/openai.yaml` with `allow_implicit_invocation: false`, since Codex ignores `disable-model-invocation`). Fresh and resume prompts start with the harness's own skill command | Only a person starts orchestration; a ticket session must load the skill even when nothing of its earlier turn was saved |
| Pi hooks and agents | A Pi extension forwards session events to `orch hook` with its own pid, and offers the stage agents to the `subagents` extension through a global provider map (`orchestration:<name>`, tools mapped; model tier → Pi model and thinking level, the same models as Codex, reviewer and verifier on the sonnet model with high thinking, reporter on the haiku tier; overridable per machine with `pi_models`; a model the session's registry lacks is dropped so the agent runs on the session's model; implementor without a model) | Pi has no plugin hooks or agents; providers keep one source of truth in `agents/*.md`; stage agents run on the model their tier asks for |
| Codex agents | `scripts/codex-agents` writes `agents/*.md` to `~/.codex/agents/*.toml` (sonnet → gpt-6.1-sol/medium, opus → gpt-6-astra/high; reviewer and verifier gpt-6.1-sol/high; reporter gpt-6-luna/low; implementor without a model; reviewer read-only, verifier inherits the sandbox) | Codex plugins cannot ship agents. Sol at high effort is enough for review and verification, and costs less than Astra |
| Codex session ids | Codex picks the thread id: `spawn` records none, the first `SessionStart` from the launched process (headless) or the first to report in (Orca/Herdr) attaches it; the headless log's `thread.started` is the fallback; resume continues only a thread with a saved rollout | `codex exec` has no `--session-id`; a thread killed before its first turn cannot be resumed |
| Codex folder trust | Append a `[projects."<path>"]` trust table to `$CODEX_HOME/config.toml` for Orca/Herdr launches when none exists, remove exactly it on retire | The interactive trust dialog ignores `-c` overrides and even the bypass flag |
| Pi liveness | Record the process start time at launch | Pi rewrites its process title, so its command line never names the session |

## Ticket phases

Defined in [orch-cli.md](orch-cli.md). Status is derived from phase:
`ready → in_progress → in_review → verified → done`, plus `blocked`.

## Recovery

- **Session died mid-phase:** `orch stale` lists it; `orch resume` restarts the same Claude session; the ticket orchestrator reads `orch show` and redoes the recorded phase if its output is missing.
- **Main orchestrator died:** a new main session runs `orch stale` first and resumes from there. Nothing it needs lives in its own memory.
- **Machine restarted:** same as above; the SQLite file is on disk.

## Open questions

- [ ] Cross-host pickup: SQLite is machine-local. Handing a ticket from macOS to a Linux host needs either a tracked export of ticket phase or a shared store.
- [ ] Post-merge integration checks: how a failure on `BASE_BRANCH` after a squash-merge routes back (new ticket, or revert).
- [ ] A narrow race remains: between the intent commit and the pid commit, a concurrent `stale` + `resume` could start a second headless session on the same id.
- [ ] Liveness uses `ps`. Checked on macOS only; procps on Linux supports the flags, busybox does not.
- [ ] Orca's pane env vars (`ORCA_TERMINAL_HANDLE`, `ORCA_WORKTREE_ID`) are undocumented; set `ORCH_PLATFORM=orca` if detection misses.
- [ ] Every session with the plugin enabled runs `orch hook` on each tool call. It returns fast when no ticket matches, but it is a Python start per call.
- [ ] Merge SHA drift: the report commit lands after review, so the reviewed SHA and the merged SHA differ. Today the gate binds to the CI-passed SHA only.

## Follow-ups from the platforms review (round 2 cap)

- [ ] Launch marker expiry: the 10-minute age check wins over a live owner, so a slow DDEV provision can be taken over and its fresh worktree discarded. Treat a marker as live while its pid and start time check out; use age only when the start time is unknown. Guard step 3 and rollback with `AND launching=<token>`.
- [ ] Interrupted selftest launch: Ctrl-C during spawn step 2 leaves pid and `launch_ref` empty, so teardown can't kill the headless session or close the herdr workspace. `clean` reports it. Teardown should also signal `session_processes(sid)` and close herdr by agent name.
- [ ] SIGTERM during `run_engine` leaves the create-worktree child running. Kill and wait it in a `finally`.
- [ ] herdr `already_open` rollback closes the root pane on any `agent_not_ready`. Close it only after `herdr agent get` shows orch's agent in that pane.
- [ ] An interrupt inside `release_launch` can leave a marker owned by selftest's own pid, so teardown's retire refuses. `claim_launch` should treat a marker owned by `os.getpid()` as reclaimable.
- [ ] `orch show`/`list` don't expose a live `launching` marker, so a ticket mid-resume shows in `stale` and a retry exits 3 with no visible reason. Add `launching` (op, at) to the ticket output.
- [ ] Ctrl-C during `create_worktree` in a real `orch spawn` skips `discard()`, leaving a half-made worktree that blocks later spawns. Catch `BaseException` around create, discard, re-raise.

## Follow-ups from the folder-trust review (round 2 cap)

- [ ] Selftest records the main Herdr workspace id in a `finally` even when the launch refused before Herdr opened anything; a workspace the user opens in that gap would be closed at teardown. Record it only when the launch reached Herdr.
- [ ] Trust writes don't keep the config file's owner or extended attributes (only matters if someone else owns it).
- [ ] If `os.fdopen` fails after `mkstemp`, the descriptor leaks.
- [ ] A second ticket on a shared worktree skips marking without checking the trust entry is still in the file.
- [ ] Selftest on Orca leaves the repo registered with Orca when it ran `orca repo add`. Like the Herdr main workspace, unregister it at teardown only when selftest added it (`orca project setup-delete --setup <repoId>`).
