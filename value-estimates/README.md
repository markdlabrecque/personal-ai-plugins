# value-estimates

Compare estimated effort with actual hours for one Harvest project over a date range. For each ticket billed in that range, the report shows the estimate (from GitLab) next to the hours logged (from Harvest), and lists tickets whose spec is too thin to estimate.

## How it works

1. **Harvest.** Fetch your time entries for the project and range. The `#NNN` ticket header lines in each entry's notes say which tickets were worked. Each entry's hours are split evenly across the tickets it names. Hours on entries with no ticket are reported as "unmatched".
2. **GitLab.** Fetch each ticket with `glab` to get its title, description, labels, and time estimate.
3. **Estimate.** In priority order: the GitLab `/estimate`, a number written in the spec, an estimate derived from the spec, or "undefined" with a note on what the spec is missing.
4. **Report.** Print a summary and a table of estimate, actual, and variance per ticket. Variance is `actual − estimate`, using the high end of a range.
5. **History.** Append each ticket's numbers to `estimates.json` so you can see over time whether estimates are getting more accurate.

This plugin reads only Harvest and GitLab. It doesn't need the `timesheet` plugin, but works best on entries written in its format (one entry per project per day, with notes grouped under `#NNN` header lines).

Per-ticket actuals are approximate whenever several tickets share an entry. Totals per project are exact.

## Usage

Ask Claude for "a value-based estimate for <project>" or "estimated vs actual spend on <project>".

- **project** (required) — the Harvest project name, or a close match.
- `--from YYYY-MM-DD --to YYYY-MM-DD` or `--days N` — the range. If you give neither, the skill asks and suggests the last 30 days.
- `--labels a,b` — only include tickets with any of these GitLab labels.
- `--save` — write the report to `docs/value-estimates/` in the current repo without asking. The skill adds that folder to `.gitignore`, since reports can hold client-sensitive hours.

## Setup

- Export `HARVEST_TOKEN` and `HARVEST_ACCOUNT_ID` (for example from `~/.zshenv`).
- Authenticate `glab` against `git.affinitybridge.com`.
- Requires `python3`.

## Configuration

Config lives in `~/.config/value-estimates/` (override with `VALUE_ESTIMATES_CONFIG_DIR`) and belongs to this plugin alone. The skill creates what's missing as it goes.

- **`projects.yml`** — maps each Harvest project to its GitLab project. When a project has no mapping, the skill asks once and appends it.

  ```yaml
  - harvest: "Example Client Portal"
    gitlab: "example/client-portal"
    slack_channel: acct-example   # optional
  ```

- **`local-context.md`** — your Harvest `user_id`. The skill asks you to confirm it on first run and saves it. All Harvest reads are scoped to it, so a manager token doesn't count your teammates' hours.
- **`estimates.json`** — variance history, keyed by `{gitlab_path}#{iid}`. Written by the skill; don't edit it by hand.

## History

**0.3.0**
- Tickets now come from Harvest entry notes, not from the daily logs.
- Stopped reading the timesheet `tickets.json` sidecar.
- Added variance history in `estimates.json`.
- Moved config to `~/.config/value-estimates/`.
- All `glab` calls name the GitLab host, so they work from any directory.
