---
name: value-estimates
description: "Generate a value-based estimate report for a project — pulls tickets delivered in a given time period from daily reports, cross-references each with its GitLab issue to derive an effort estimate, and compares against actual hours logged in Harvest. Trigger this skill whenever the user asks for value-based estimates, an estimate report, a delivery/effort summary for a project, or anything resembling 'how much did we estimate vs actually spend on project X', even if they don't use the exact phrase 'value-based estimate'. Required: Harvest project name. Optional: time range (default last 30 days), GitLab label filter."
---

# Value Estimates Skill

Produce a report that, for a given Harvest project and time window, lists every ticket touched, the **estimated** effort (derived from the GitLab spec or an explicit estimate on the ticket), and the **actual** hours logged in Harvest. The report also surfaces tickets that lack a usable spec so the user knows where definition is missing.

The report is printed to the conversation by default. After printing, ask the user whether to also save it as a Markdown file under `docs/value-estimates/` of the current working directory. This subfolder is expected to be gitignored — value-estimate reports may include client-sensitive hours/ticket data and should not be committed by default.

## Arguments

The skill accepts the following arguments (free-form — extract from the user's prompt or ask):

- **project** *(required)* — Harvest project name (or close fuzzy match). If the user did not name a project, ask before doing anything else.
- **`--from YYYY-MM-DD` / `--to YYYY-MM-DD`** *(optional)* — explicit date range.
- **`--days N`** *(optional)* — alternative to `--from/--to`; covers the last N days ending yesterday.
- **`--labels label1,label2`** *(optional)* — only include tickets whose GitLab labels match **any** of the supplied labels (case-insensitive).
- **`--save`** *(optional)* — skip the post-report prompt and write to `docs/value-estimates/` immediately.

If neither `--from/--to` nor `--days` is supplied, **always ask the user for a time frame**, suggesting "last 30 days" as the default.

## Step 0: Load shared config

Read two files from `~/daily_reports/meta/`:

- **`projects.yml`** — shared project map. The relevant fields here are `harvest` (official Harvest name), `gitlab` (GitLab project path), and `log_aliases`. Skip entries with `excluded: true`.
- **`local-context.md`** — per-machine config (currently the daily reports path; defaults to `~/daily_reports/`).

Also check for **`~/daily_reports/meta/tickets.json`** (the timesheet-skill sidecar). When present, it gives O(1) per-ticket lookups for `harvest_hours`, `harvest_entry_ids`, `first_seen` / `last_seen`, etc. — used in Step 6 below.

If `projects.yml` is missing, tell the user to create it (see the timesheet skill's `local-context.example.md` for guidance) and stop. If a Harvest project has no `gitlab` mapping, ask once and append the new entry to `projects.yml`.

## Step 1: Resolve project and date range

1. Match the requested project name against the Harvest project map in `projects.yml` (fuzzy, case-insensitive — match against `harvest` and `log_aliases`). If no `gitlab` field exists on the matched entry, ask the user for the GitLab project path and add it to `projects.yml`.
2. Confirm the date range. Convert relative phrases ("last sprint", "April") to absolute `YYYY-MM-DD`. If the user said nothing, ask — propose 30 days back through yesterday.

## Step 2: Verify `glab` is usable

Run `glab auth status` once. If it fails (not installed, not authenticated, network error), report the failure and exit. **Do not** fall back to raw `curl` — the user has explicitly requested `glab`.

## Step 3: Collect ticket IDs from daily reports

Read every `~/daily_reports/YYYY-MM-DD-*.md` in the date range. Extract:

- All ticket references — prefer the `**Tickets:**` line if present (authoritative; one or more `#NNN` separated by commas). Otherwise scan the entry body for `#123`, `(#123)`, `ticket #123`, `(ticket #123)`. Capture the bare integer.
- The project context for each entry (the same fuzzy-matching rules used by the timesheet skill — `**Project:** name`, `### date — name`, freeform mention).
- Skip entries that don't belong to the requested Harvest project. Daily reports are noisy; only keep entries whose project context matches.

Record, per ticket ID: the set of dates it appeared on, and the `###` headers it appeared under (used as fallback context if the GitLab ticket has no spec).

If the same ticket has multiple project contexts across days, prefer the matched one but note the ambiguity in the report.

## Step 4: Pull each ticket from GitLab

For each ticket ID, in a single batched Bash call where possible:

```bash
glab api "projects/<URL-ENCODED-PROJECT-PATH>/issues/<IID>" \
  --jq '{iid, title, description, labels, time_stats, web_url, state}'
```

URL-encode the project path (`/` → `%2F`). Collect:

- `title`
- `description` (the spec)
- `labels` (array)
- `time_stats.time_estimate` (seconds; 0 if unset)
- `time_stats.human_time_estimate` (pre-formatted)
- `web_url`
- `state` (open/closed)

If a ticket 404s, record it as "ticket not found in GitLab project" and continue.

### Apply label filter

If `--labels` was supplied, drop tickets whose labels don't intersect (case-insensitive) with the filter. Keep a count of dropped tickets for the report footer.

## Step 5: Derive an estimate per ticket

Apply this priority order:

1. **Explicit GitLab estimate.** If `time_stats.time_estimate > 0`, use that (convert seconds → hours). Mark source as `gitlab /estimate`.
2. **Estimate embedded in the spec.** Scan the description for patterns like `Estimate: 4h`, `~6 hours`, `Effort: 3-5h`, `Total: 12h`. If found, use that. Mark source as `spec field`.
3. **Spec-derived estimate.** If the description contains a meaningful spec (acceptance criteria, task breakdown, scope) but no explicit number, derive a concrete hour estimate grounded in real human work time. Walk through the spec and account for the actual activities the ticket implies — reading and orienting in the affected code, writing the change, local testing, manual QA, code review back-and-forth, and any deployment or migration steps. Sum those into a single number of hours (or a tight range like `5–7h` when genuine uncertainty warrants it). Avoid abstract t-shirt sizes or category buckets — the number should answer "how many hours of focused work would a competent engineer on this codebase actually spend?". Mark source as `derived from spec`.
4. **Undefined.** If the description is empty, a placeholder, or so thin it can't support an estimate, **do not guess.** Add the ticket to the **Undefined Tasks** list with specific feedback on what's missing — e.g. "no acceptance criteria", "no scope/file boundaries", "outcome not stated", "no reproduction steps for a bug".

## Step 6: Pull actual hours from Harvest

Harvest is the canonical source of truth for actuals.

**Fast path — sidecar.** If `~/daily_reports/meta/tickets.json` exists, prefer it for tickets that have a `{project_slug}#{ticket}` key matching this run's project + ticket set. Read `harvest_hours` directly per ticket. The timesheet skill writes one Harvest entry per ticket (since the per-ticket placeholder change), so each entry maps cleanly to a single ticket — no even-split required.

**Fallback — scan notes.** For tickets not present in the sidecar (older entries created before the sidecar landed, or projects the timesheet skill never touched), fall back to scanning the **notes field** of each Harvest entry for ticket references using the same regex as Step 3.

In a single Bash call, fetch all Harvest entries for the matched project across the date range. Use Python (not `jq`) because notes contain literal newlines:

```bash
python3 -c "
import urllib.request, json, os, re
from collections import defaultdict

token = os.environ['HARVEST_TOKEN']
account_id = os.environ['HARVEST_ACCOUNT_ID']
headers = {
    'Authorization': f'Bearer {token}',
    'Harvest-Account-Id': account_id,
    'User-Agent': 'Claude-ValueEstimates-Skill'
}

# Resolve the Harvest project ID (search active assignments, fuzzy match handled in caller).
# Then page through time_entries filtered by project_id and date range.
PROJECT_ID = '<resolved-id>'
FROM = '<from>'
TO = '<to>'

ticket_re = re.compile(r'#(\d+)')
hours_by_ticket = defaultdict(float)
unmatched_hours = 0.0
entries = []

page = 1
while True:
    req = urllib.request.Request(
        f'https://api.harvestapp.com/v2/time_entries?project_id={PROJECT_ID}&from={FROM}&to={TO}&page={page}',
        headers=headers)
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    for e in data['time_entries']:
        notes = e.get('notes') or ''
        ids = set(ticket_re.findall(notes))
        if ids:
            # Split this entry's hours evenly across the tickets it mentions.
            share = e['hours'] / len(ids)
            for tid in ids:
                hours_by_ticket[tid] += share
        else:
            unmatched_hours += e['hours']
        entries.append({'date': e['spent_date'], 'hours': e['hours'], 'notes': notes, 'tickets': sorted(ids)})
    if not data.get('next_page'):
        break
    page = data['next_page']

print(json.dumps({'hours_by_ticket': hours_by_ticket, 'unmatched_hours': unmatched_hours, 'entries': entries}))
"
```

**Why even-split across mentioned tickets (fallback path only):** legacy Harvest entries (created before the per-ticket placeholder change) may reference multiple tickets in their notes. With no finer-grained signal, split equally and disclose this in the report's methodology footer so the user can interpret variance accordingly. New entries (sidecar path) are 1:1 ticket-to-entry, so this caveat doesn't apply to them.

`unmatched_hours` (Harvest hours on this project with no ticket reference in the notes) is reported separately so the user can spot under-tagged entries.

## Step 7: Build the report

Follow this exact structure. Keep the language tight — one row per ticket, no editorial padding.

```markdown
# Value Estimate Report — <Harvest project name>

**Range:** <from> to <to> (<N> days)
**Tickets matched:** <count>  ·  **Tickets dropped by label filter:** <count>  ·  **Undefined:** <count>

## Summary

| Metric | Hours |
|--------|------:|
| Total estimated (low) | X.X |
| Total estimated (high) | X.X |
| Total actual (Harvest) | X.X |
| Unmatched Harvest hours (no ticket in notes) | X.X |
| Variance vs midpoint | ±X.X (±NN%) |

## Tickets

| Ticket | Title | Labels | Estimate | Source | Actual | Variance |
|--------|-------|--------|---------:|--------|-------:|---------:|
| [#123](url) | … | a, b | 4–6h | derived from spec | 5.5h | +0.5h |
| [#456](url) | … | c | 2h | gitlab /estimate | 3.0h | +1.0h |

## Undefined Tasks

Tickets that appeared in daily reports but lack enough spec to estimate. Each entry lists what's missing.

- **#789** — <title> — *missing: acceptance criteria, scope*
- **#790** — <title> — *missing: any description (placeholder body only)*

## Methodology

- Estimate sources, in priority order: GitLab `/estimate`, spec-embedded number, spec-derived range, undefined.
- Actuals pulled from Harvest by parsing ticket IDs from entry notes. Where one entry mentions multiple tickets, hours are split evenly across them.
- Unmatched hours = Harvest entries on this project whose notes contain no `#<id>` reference.
```

For ranged estimates, **always use the high end of the range** as the estimate value for the variance calculation. Variance is `actual − high`. This treats the upper bound as the commitment.

## Step 8: Offer to save

After printing, ask: *"Save this report to `docs/value-estimates/<project-slug>-value-estimate-<from>_<to>.md`?"* — unless `--save` was passed, in which case write it directly. Create `docs/value-estimates/` if missing.

The `docs/value-estimates/` folder should be gitignored (these reports often contain client-sensitive hours and ticket detail). If the current repo's `.gitignore` does not already list `docs/value-estimates/`, add the line on first save and mention to the user that you did.

## Failure modes (fail loud, exit clean)

- `glab` not authenticated → print the `glab auth status` error, instruct the user to run `glab auth login`, exit.
- Harvest env vars missing → print which one is missing, point at `~/.zshenv`, exit.
- No GitLab project mapping for the requested Harvest project → ask the user once, persist, continue.
- No tickets matched in date range → print a short note ("No tickets found for `<project>` between `<from>` and `<to>`") and exit; don't generate an empty report.

## Roadmap

This skill has known limitations that depend on improvements to the timesheet skill and on richer per-entry data. See `docs/timesheet-roadmap.md` in this skill's directory for the proposed changes.
