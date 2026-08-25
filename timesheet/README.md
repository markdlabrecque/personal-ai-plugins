# timesheet

Fill out Harvest timesheets from daily log markdown files in `~/daily_reports/`. Includes a post-commit hook that appends each git commit to today's daily report so the source data accumulates automatically.

> **Personal fork.** Forked from `timesheet@affinity-bridge-skills` at v0.4.0
> (`claude-code-marketplace` commit `2b05c52`) so it can track a personal
> workflow: a `.bare` + `work/<repo>/<branch>` git worktree layout, and the
> tooling in this repo. It lives here alongside `value-estimates`, which shares
> the same `~/daily_reports/` and `meta/projects.yml` contract. Upstream
> changes are pulled in by hand, not merged. See `docs/roadmap.md`.

## What it does

Two parts:

### 1. The skill (`timesheet`)

Reads daily report markdown files, maps commits and ticket activity to Harvest projects, and creates time entries. Maintains a `~/daily_reports/meta/tickets.json` sidecar with per-ticket Harvest entry IDs and hours.

**Flags:**

- `--analyze [N]` — instead of creating entries, scan the last N days (default 30) of Harvest and flag weekdays with low hours logged. Useful for catching missed days.
- `--dry-run` — walk through the normal flow and print the planned-entries summary table, then stop. No POST to Harvest, no `tickets.json` update.

**Environment overrides (testing/eval support):**

- `DAILY_REPORTS_DIR` — use a different path instead of `~/daily_reports/` for both reports and the `meta/` config dir.

### 2. The post-commit hook (`daily-log`)

Auto-installed when the plugin is enabled. On every `git commit`, appends a line to `~/daily_reports/{YYYY-MM-DD-Day}.md` recording the commit hash, message, and originating repo/remote. This is the source data the skill reads from.

The hook is registered via `hooks/hooks.json` on `PostToolUse` for Bash commands matching `git commit`.

## Prerequisites

- Harvest account with API access. Set `HARVEST_TOKEN` and `HARVEST_ACCOUNT_ID` in the environment.
- `~/daily_reports/meta/projects.yml` mapping Harvest project names to GitLab paths and log aliases.
- `python3` available (used for Harvest API calls — `jq` chokes on newlines in time-entry notes).

## How to use

Trigger by:

- "Fill out my timesheet"
- "Log my time"
- "Submit hours to Harvest"
- "Sync daily reports to Harvest"
- "Check for missing time" (analyze flow)

## Files involved

- `hooks/hooks.json` — registers the post-commit hook with Claude Code.
- `hooks/daily-log.sh` — appends commits to today's daily report.
- `bin/harvest-post` — posts the confirmed time entries to Harvest from a JSON file (the skill calls this instead of writing an ad hoc POST loop each run).
- `scripts/setup.sh` — one-time setup helper.
- `skills/timesheet/SKILL.md` — full skill instructions.
