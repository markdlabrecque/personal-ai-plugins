# Timesheet skill — proposed updates to support `value-estimates`

The `value-estimates` skill leans on two data sources: the daily report markdown files and Harvest time entries. The current shapes of both make per-ticket aggregation noisier than it needs to be. The changes below would tighten that signal substantially. None of these are blocking — the skill works today — but each one removes a heuristic.

## Problem 1: ticket IDs in daily reports are inconsistent

**Today.** Tickets show up as `(#194)`, `(ticket #184)`, `#189` in the body, or sometimes only implied by a branch name. Some entries have no ticket reference at all even though one exists.

**Proposal.** Add a structured `**Tickets:**` line to every entry the timesheet skill processes. Existing free-form references stay supported as fallback parsing.

```markdown
### Implementation: Communities Facet for Search
- **Project:** ih
- **Tickets:** #189
- Created facets.facet.communities.yml config…
```

The timesheet skill should:
1. When reading a daily report, parse `**Tickets:**` first; fall back to regex scan of the body.
2. When an entry has no ticket reference, prompt the user inline ("entry on 2026-03-11 'Scope facet label JS…' has no ticket — link one?") instead of silently moving on.
3. Optionally backfill `**Tickets:**` lines into the markdown after the user answers, so the file becomes self-describing for next time.

## Problem 2: Harvest entries are placeholder hours, not real durations

**Today.** The timesheet skill creates one 1.0h entry per project per day. The user later edits each entry's duration in the Harvest UI to reflect actual time. That's fine, but per-ticket variance (the headline number in the value-estimates report) only becomes meaningful **after** the user does that pass.

**Proposal.** Two complementary changes:

1. **Backsync flow.** Add a `--backsync` mode to the timesheet skill that pulls every Harvest entry for the past N days and writes the *actual* hours back into the matching daily report entry as a `**Hours:**` line. This makes the daily report a faithful mirror of Harvest at any point.
2. **One entry per ticket per day, not one per project per day.** When a daily report entry has a `**Tickets:**` line, create a Harvest entry per ticket with the placeholder duration split evenly (or `0.0h` if Harvest accepts it), and put the ticket ID in the notes. This removes the even-split heuristic in `value-estimates` Step 6 — every Harvest entry then maps to exactly one ticket.

## Problem 3: no aggregated ticket log

**Today.** To answer "how many hours have we spent on `#194` so far?" you have to scan all daily reports + all Harvest entries.

**Proposal.** Maintain a sidecar file at `~/daily_reports/.tickets.json` that the timesheet skill updates on every run:

```json
{
  "ih#189": {
    "title": "Search improvements",
    "first_seen": "2026-03-11",
    "last_seen": "2026-03-22",
    "days_active": 8,
    "harvest_hours": 14.5,
    "harvest_entry_ids": [12345, 12346, ...]
  }
}
```

This becomes the canonical per-ticket rollup — lookups are O(1), and the value-estimates skill can read it directly instead of reparsing markdown + paginating Harvest. Other skills (sprint reviews, retrospectives, client status updates) benefit too.

The `.tickets.json` file is data, not config — it should be gitignored if `~/daily_reports/` is ever versioned.

## Problem 4: project mapping lives in two places

**Today.** Timesheet maps log-project → Harvest-project via fuzzy matching at runtime. value-estimates needs Harvest-project → GitLab-project. Eventually a third skill will want GitLab-project → Linear, etc.

**Proposal.** Promote the project map out of skill-local context files into a single shared file, e.g. `~/.config/affinitybridge/projects.yml`:

```yaml
- harvest: "Island Health"
  gitlab: "affinitybridge/island-health/main-site"
  log_aliases: ["ih", "island-health"]
  excluded: false
- harvest: "Affinity Bridge [INT] Internal"
  log_aliases: ["internal", "admin"]
  internal: true
```

Both skills read from this file. New skills slot in by reading the same file. Adding a project means editing one place.

## Suggested rollout order

1. **Tickets sidecar (`~/daily_reports/.tickets.json`)** — biggest single win for value-estimates, no behaviour change to existing timesheet flow.
2. **`**Tickets:**` line in daily reports** — quick to add to the parser; backfill is optional.
3. **Shared project map** — mechanical refactor, unblocks future skills.
4. **Per-ticket Harvest entries** — bigger workflow change; do this only after the sidecar and the Tickets line are in place, and confirm with the user that splitting the placeholder helps more than it hurts.
5. **Backsync flow** — the most ambitious; depends on (4) being stable.

## Roadmap items for the `value-estimates` skill itself

These are not timesheet changes — they're follow-ups for this skill once the underlying data is cleaner.

- **Test cases.** Build a small eval set (`evals/evals.json`) using real recent prompts: a typical 30-day request, a label-filtered request, a request that should hit the "no spec" path, and a request against a project with no GitLab mapping yet. Run them through skill-creator's review loop.
- **Better variance recording.** Right now variance is computed and printed, but not retained anywhere. Once the timesheet sidecar (`~/daily_reports/.tickets.json`) lands, extend it (or add a parallel `~/daily_reports/.estimates.json`) so each ticket carries `{estimate_hours, estimate_source, actual_hours, variance, computed_at}`. That gives us a longitudinal view: are spec-derived estimates trending more accurate over time? Are certain label categories systematically under-estimated? Without persistence, every report is a snapshot — with it, the data compounds.
