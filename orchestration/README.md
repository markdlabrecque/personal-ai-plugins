# orchestration

## The workflow

1. **You start it.** Type `/orchestration` and list the tickets you want done.
2. **It checks the project.** `BASE_BRANCH` is set in `.env`, and there's a local
   site to test on (DDEV or a Docker harness). If something's missing, it stops
   and tells you.
3. **Each ticket gets its own space.** A fresh worktree cut from `BASE_BRANCH`,
   its own local site, and its own agent session. Several tickets can run at once.
4. **Each ticket goes through the same steps:**
   - **Spec**: what "done" means.
   - **Tests**: written first, and they fail.
   - **Code**: written until every test passes.
   - **Review**: a second agent checks the code. Up to 2 fix rounds.
   - **Verify**: an agent uses the change like a real user. It reports confusing
     spots and errors (console, network, server logs), plus an accessibility
     scan if `ACCESSIBILITY_TESTS=true`. The results go on the ticket as a
     comment with screenshots.
   - **Report**: a short write-up of what changed.
5. **It opens the MR**, waits for CI, and squash-merges once CI is green. If the
   project says a person must merge, it stops and waits for you instead.
6. **Leftover problems become new tickets.** It doesn't stop to ask about them.
7. **It cleans up.** It removes each finished ticket's worktree and local site.
8. **You get one report**: the MR and merge for each ticket, any errors found,
   the new tickets it filed, and anything a person still needs to check.

If a session crashes, it picks up where it left off.

Run coding tickets end to end. A main orchestrator gives each ticket its own worktree and a ticket-orchestrator session on the harness it runs on (Claude Code, Pi or Codex) and the platform it runs on: headless, Orca, Herdr or Claude Desktop (Claude only). Each ticket orchestrator runs the stage agents (test-writer → implementor → reviewer → verifier → reporter), opens the MR and squash-merges once CI is green. Ticket state lives in SQLite behind the `orch` script, and plugin hooks report every session's health, so a ticket resumes after a crash, sleep or network drop.

## What's inside

| Path | What |
|---|---|
| `skills/orchestration/` | The skill: roles, main orchestrator loop, ticket pipeline, `orch` CLI contract, design notes |
| `agents/` | Stage agents: `test-writer`, `implementor`, `reviewer`, `verifier`, `reporter` (spawned as `orchestration:<name>`; plain `<name>` on Codex) |
| `scripts/orch` | State CLI, Python 3.9+ standard library only |
| `scripts/codex-agents` | Writes the stage agents to `~/.codex/agents` for Codex |
| `hooks/hooks.json` | Reports each session's activity to `orch` (Claude Code and Codex) |
| `pi/extension.ts`, `package.json` | Pi package: the same hooks, plus the stage agents for the `subagents` extension |
| `.codex-plugin/plugin.json` | Codex plugin manifest |
| `tests/` | `python3 -m unittest discover -s tests -v` |

## Requirements

- `python3` 3.9+ and `git`.
- The harness on `PATH`: `claude`, `pi` (with the `subagents` extension) or `codex`. For Orca or Herdr, their CLI too (`orca`, `herdr`). For Desktop, the main session needs the `start_session` tool.
- `glab` or `gh` for MRs and CI.
- The `create-worktree` and `retire-worktree` skills for worktree setup and teardown.
- A verification environment: DDEV in the project, or a Docker harness command in `.agents/orchestration/config.json` (`verify_harness`). Without one, preflight stops before any ticket starts.

## Project setup

Add `BASE_BRANCH=<integration branch>` to the main checkout's `.env`. Ticket worktrees are cut from it and MRs squash-merge into it.

Optional: add `ACCESSIBILITY_TESTS=true` to the same `.env` to have the verifier run an automated accessibility scan (axe) on every screen a ticket changes. Missing or any other value means off. Only the main checkout's `.env` counts; worktrees don't have one.

## Install and invoke

The skill is user-invoked only on every harness. Ticket sessions run on the harness the main orchestrator runs on; `ORCH_HARNESS` overrides the detection.

| Harness | Install | Start it |
|---|---|---|
| Claude Code | `/plugin marketplace add <this marketplace>`, then `/plugin install orchestration@affinity-bridge-skills` | `/orchestration` |
| Pi | `pi install <checkout>/orchestration` (needs the `subagents` extension for stage agents). Stage agents run on `openai-codex` models by tier; set `pi_models` in `~/.config/orchestration/config.json` to use other providers | `/skill:orchestration` |
| Codex | `codex plugin marketplace add <checkout>`, `codex plugin add orchestration@affinity-bridge-skills`, then `<checkout>/orchestration/scripts/codex-agents`. Ticket sessions enable hooks themselves (`--enable hooks`) | `$orchestration:orchestration` |

Codex installs a copy of the plugin: run `codex plugin add` again after updating it, and `codex-agents` again after the agents change. Check a machine with `orch selftest` on each harness you use.
