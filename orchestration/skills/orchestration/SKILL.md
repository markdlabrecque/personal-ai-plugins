---
name: orchestration
description: >-
  Run coding tickets end to end. A main orchestrator gives each ticket its own worktree and ticket-orchestrator session on the same harness (Claude Code, Pi or Codex) and platform (headless, Orca, Herdr or Claude Desktop) it runs on; each ticket orchestrator runs test-writer, implementor, reviewer, verifier and reporter subagents, opens the MR and squash-merges on green CI. State lives in SQLite behind the `orch` script and plugin hooks report each session's health, so tickets resume after a crash or network drop. User-invoked only: type `/orchestration` (or `/orchestration:orchestration`) in Claude Code, `/skill:orchestration` in Pi, or `$orchestration:orchestration` in Codex to start, resume or supervise tickets. Ticket sessions are launched with that full form.
disable-model-invocation: true
---

# Orchestration

Two kinds of orchestrator and a set of stage agents:

| Role | Runs as | Does | Never does |
|---|---|---|---|
| **Main orchestrator** | The session the user talks to | Preflight, adds tickets, creates worktrees, spawns and resumes ticket orchestrators, retires finished worktrees | Ticket work of any kind |
| **Ticket orchestrator** | One session per ticket, in its worktree, on the main orchestrator's harness and platform | Writes the stage spec, runs the stage agents, triages review, opens the MR, merges on green CI | Create worktrees, spawn other ticket sessions, retire itself |
| **Stage agents** | Subagents of a ticket orchestrator | One phase each (table in [references/ticket-pipeline.md](references/ticket-pipeline.md)) | Write state, talk to the user |

## Principles

1. **State is scripted, never judged.** Every phase change goes through `orch` ([references/orch-cli.md](references/orch-cli.md)). No agent edits state by hand or infers it from memory.
2. **Read fresh.** Run `orch show <ticket>` before every decision and after every resume. What you remember from earlier in the conversation may be stale.
3. **Judge actions, not state.** An ambiguous review comment or an out-of-scope test failure is the ticket orchestrator's call. It decides, acts, then records the result through `orch`.
4. **Gates are opt-in per project.** Linting and project rules run where the project's `AGENTS.md` turns them on. Nothing is assumed globally.
5. **Merge binds to a commit.** `orch merged` refuses unless CI passed for that exact SHA.

`orch` is `scripts/orch` in the plugin: `${CLAUDE_PLUGIN_ROOT}/scripts/orch` in Claude Code; in Pi and Codex, `../../scripts/orch` from the directory holding this file. Below it is written as `orch`.

Stage agents are named per harness: `orchestration:<name>` in Claude Code (the Agent tool) and Pi (the `subagent` tool); `<name>` as the `spawn_agent` agent type in Codex, from `~/.codex/agents` (`scripts/codex-agents` writes them). [references/ticket-pipeline.md](references/ticket-pipeline.md) uses the Claude names.

## Which role am I?

- The prompt says **"You are the ticket orchestrator for <ticket>"** → follow [references/ticket-pipeline.md](references/ticket-pipeline.md). Start with `orch show <ticket>`.
- Otherwise you are the **main orchestrator** → follow the section below.
- A coding request with **no ticket** (a quick fix in the current repo) → run the ticket pipeline in this session without `orch` state: you act as the ticket orchestrator, the worktree is the current checkout, and completion follows the project's `AGENTS.md`.

## Main orchestrator

A request to start, work on, or resume tickets authorizes this whole loop. Do not re-ask for each step.

1. **Check the main checkout.** Branch and working tree. Surface uncommitted work before starting; preserve it.
2. **Preflight.** `orch init`, then `orch preflight`. It reports the harness and platform you are running on; every ticket session you start runs there too (see "Platforms" below). Exit 5 is a stop: nothing gets created. Tell the user what failed. A missing `BASE_BRANCH` needs a line in `.env`. No verification environment (no DDEV, no `verify_harness` Docker harness) needs a decision on how verification should run. Ask once, two options max, with a recommendation.
3. **Recover first.** `orch stale` lists tickets whose session died. `orch resume <ticket>` each one. The ticket orchestrator picks up from its recorded phase.
4. **Add tickets.** For each requested ticket: read the ticket, its comments and linked MRs; check dependencies and readiness per the project's `AGENTS.md`; assign it if the project says to; then `orch add <ticket> --title "<title>" --url <url>`.
5. **Dispatch.** `orch next` returns what fits under `max_workers`. For each:
   1. Create and provision the worktree with the `create-worktree` skill. The worktree name is the ticket id alone (`19`, not `ticket-19`). It is cut from `BASE_BRANCH`.
   2. Write the brief (template below) to a temp file. Accessibility tests are `on` only when the main checkout's `.env` has `ACCESSIBILITY_TESTS=true` (any case). Missing, or any other value, is `off`. Read that key from the main checkout, never from the worktree: worktrees have no `.env`.
   3. `orch spawn <ticket> --worktree <absolute path> --brief-file <file>`. On Desktop, carry out the printed action (below).
   A ticket whose prerequisite is not `done` stays in `ready` until it is.
6. **Supervise until every ticket is done.** Check `orch list` on a slow cadence (a background wakeup or monitor, not a sleep loop). React by phase and `health`:
   - `done` → `orch retire <ticket>` (on Desktop, carry out its action), then the `retire-worktree` skill for that worktree and its DDEV project. Then dispatch anything newly unblocked.
   - `dead` and not done (`orch stale`) → `orch resume <ticket>`. If the same ticket dies twice in a row at the same phase, look at why (headless: the tail of `.agents/orchestration/logs/<ticket>.log`; Orca/Herdr/Desktop: the session itself), fix the cause if it is environmental, and resume. Otherwise, report it.
   - `idle` and not done or blocked → the session finished a turn without finishing the ticket. Headless sessions exit at that point and show `dead`, so they get resumed. On Orca, Herdr or Desktop the session stays open, so send it a message (`orca terminal send`, `herdr agent prompt`, or the Desktop session tool): "Run `orch show <ticket>` and carry on."
   - `stalled` → look at the session. Kill it only if it is truly stuck; it then shows `dead` and gets resumed.
   - `blocked` → read the reason with `orch show`. If it is a permitted stop (see the pipeline reference), ask the user, then `orch resume <ticket> --note "<answer>"`. Resume restores the phase the ticket was blocked from.
7. **Report.** When the batch is done: per ticket, the MR, the merge SHA, the errors the verifier reported (listed in the MR description), the follow-up tickets filed, and anything a person still needs to look at.

The main orchestrator never runs stages, edits code, or merges. If a ticket session cannot be started, report the blocker; never fall back to doing the ticket in this session.

### Ticket brief

```
You are the ticket orchestrator for <ticket-ref> (<ticket-url>), working in
<absolute-worktree-path> on branch <branch>. Follow
references/ticket-pipeline.md. Start with `orch show <ticket-id>`;
the recorded phase is where you are. BASE_BRANCH is <base>: rebase onto it and
target your MR at it. Verification environment: <ddev | docker>.
Accessibility tests: <on | off>. You own this
ticket until it is merged. Do not create worktrees, spawn ticket sessions, or
retire anything. Record every phase change with `orch`.

Scope: <scope and acceptance criteria>
Known premises to verify: <premises>
Dependencies / related tickets: <list or none>
```

## Platforms

The platform running the main orchestrator hosts every ticket session it starts: `headless`, `orca`, `herdr` or `desktop` (`orch platform`). Ticket sessions also run on the main orchestrator's harness, `claude`, `pi` or `codex`, which `orch` detects (override: `ORCH_HARNESS`, or `--harness` on `spawn`/`resume`). Desktop hosts Claude only. Stage agents always run inside their ticket session.

- **headless, orca, herdr:** `orch spawn`/`resume` start the session themselves. On Orca and Herdr each ticket gets its own terminal or workspace, so you can watch and type into it.
- **desktop:** `orch` cannot open a Desktop session, so it prints an action and you carry it out:
  - `desktop_start` → start a linked session with the `start_session` tool in `cwd`, titled `title`, with the contents of `prompt_file` as its prompt. Then `orch attach <ticket> --ref <the new session id>`.
  - `desktop_resume` → if the session in `ref` still exists, message it with the contents of `prompt_file`; otherwise start a new one as above and `orch attach` it.
  - `desktop_archive` → archive the session in `ref`.
  If `start_session` is not available in this session (it isn't on every Desktop build or account), don't start anything. Tell the user Desktop can't host ticket sessions here, and that they can run the main session from a terminal instead (headless), or inside Herdr or Orca to watch tickets live. Desktop recovery needs this main session running; the other platforms can recover from any session.
- A ticket stays on the platform it started on while its session lives. A dead ticket can move with `orch resume <ticket> --platform <platform>`.

The plugin's hooks report every session's activity to `orch`, whoever started it. That is how `orch list` knows each ticket's `health` (`working`, `idle`, `stalled`, `dead`).

## Recovery, in one line

Sessions die; state does not. The main orchestrator continues the same session with `orch resume`. The ticket orchestrator reads `orch show`, then redoes the recorded phase from its start if that phase's output is not on disk.

## Design background

[references/design.md](references/design.md) holds the reasoning behind this layout and its open questions.
