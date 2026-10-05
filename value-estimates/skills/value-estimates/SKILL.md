---
name: value-estimates
description: Generate a value-based estimate report for a project — tickets billed in a period (from Harvest entry notes) cross-referenced with GitLab issues for effort estimates, compared against actual hours logged in Harvest. Use when the user asks for value-based estimates, an estimate report, or "estimated vs actual spend on project X". Requires the Harvest project name; optional time range and label filter.
---

# Value Estimates Skill

Produce a report that, for a given Harvest project and time window, lists every ticket touched, the **estimated** effort (derived from the GitLab spec or an explicit estimate on the ticket), and the **actual** hours logged in Harvest. The report also surfaces tickets that lack a usable spec so the user knows where definition is missing.

The skill reads only external systems: Harvest (which tickets were worked, and the hours) and GitLab (specs and estimates). It does not read daily logs or any other skill's files.

The report is printed to the conversation by default. After printing, ask the user whether to also save it as a Markdown file under `docs/value-estimates/` of the current working directory. This subfolder is expected to be gitignored — value-estimate reports may include client-sensitive hours/ticket data and should not be committed by default.

## Arguments

The skill accepts the following arguments (free-form — extract from the user's prompt or ask):

- **project** *(required)* — Harvest project name (or close fuzzy match). If the user did not name a project, ask before doing anything else.
- **`--from YYYY-MM-DD` / `--to YYYY-MM-DD`** *(optional)* — explicit date range.
- **`--days N`** *(optional)* — alternative to `--from/--to`; covers the last N days ending yesterday.
- **`--labels label1,label2`** *(optional)* — only include tickets whose GitLab labels match **any** of the supplied labels (case-insensitive).
- **`--save`** *(optional)* — skip the post-report prompt and write to `docs/value-estimates/` immediately.

If neither `--from/--to` nor `--days` is supplied, **always ask the user for a time frame**, suggesting "last 30 days" as the default.

## Step 0: Load config

Config lives in `~/.config/value-estimates/` (or `VALUE_ESTIMATES_CONFIG_DIR`) and belongs to this skill alone; no other skill reads or writes it. Create the directory if it is missing.

- **`projects.yml`** — maps each Harvest project to its GitLab project. One entry per project:

  ```yaml
  - harvest: "Example Client Portal"
    gitlab: "example/client-portal"
  ```

  An entry may also carry `slack_channel` (no `#`), the channel where a summary of the report is posted. A missing file is an empty map, not an error: Step 1 asks for the mapping and appends it.
- **`local-context.md`** — per-machine settings: the Harvest `user_id` (a line like `user_id: 123456`) used to scope Step 3. If it is **not set**, do not guess: fetch `GET /v2/users/me`, show the user the id, name, and email it resolves to, and ask them to confirm it (or supply the correct id). Then write `user_id: <id>` to this file so later runs skip the prompt.
- **`estimates.json`** — variance history this skill writes in Step 7.

## Step 1: Resolve project and date range

1. Match the requested project name against `harvest` in `projects.yml` (fuzzy, case-insensitive). If nothing matches, or the match has no `gitlab`, confirm the Harvest project name against the user's Harvest project assignments, ask the user for the GitLab project path, and append the entry to `projects.yml`.
2. Confirm the date range. Convert relative phrases ("last sprint", "April") to absolute `YYYY-MM-DD`. If the user said nothing, ask — propose 30 days back through yesterday.

## Step 2: Verify `glab` is usable

Run `glab auth status --hostname git.affinitybridge.com` once. If it fails (not installed, not authenticated, network error), report the failure and exit. **Do not** fall back to raw `curl` — the user has explicitly requested `glab`.

## Step 3: Pull Harvest entries and collect tickets

Harvest is the source of truth for both **which tickets were worked** and **actual hours**. Each entry's notes name its tickets.

**Ticket extraction from notes.** Prefer **ticket header lines** — lines that consist only of `#NNN` tokens (e.g. `#265` or `#487 #489`). When at least one header line is present, only the tickets on header lines count; this stops a bullet that merely mentions another ticket (e.g. "narrow the assertion to the #435 error summary") from stealing hours. When there are no header lines (legacy or hand-typed notes), fall back to any `#NNN` anywhere in the notes.

**Hours.** Split each entry's hours **evenly across the tickets it references**. This always reflects the user's edited durations.

**Context per ticket.** Record the dates each ticket appears on and the bullets under its header (used as fallback context when the GitLab ticket has no spec).

Scope the fetch with the `user_id` stored in `local-context.md` (if unset, stop and ask rather than guessing), so a manager-level token does not count teammates' hours. In a single Bash call, fetch all Harvest entries for the matched project across the date range. Use Python (not `jq`) because notes contain literal newlines:

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
USER_ID = '<user_id from local-context.md>'  # stored Harvest user_id; scopes reads so a manager token doesn't count teammates' hours
FROM = '<from>'
TO = '<to>'

ticket_re = re.compile(r'#(\d+)')
header_re = re.compile(r'^\s*(?:#\d+\s*)+$')  # a line made only of #NNN tokens
hours_by_ticket = defaultdict(float)
dates_by_ticket = defaultdict(set)
bullets_by_ticket = defaultdict(list)
unmatched_hours = 0.0

page = 1
while True:
    req = urllib.request.Request(
        f'https://api.harvestapp.com/v2/time_entries?user_id={USER_ID}&project_id={PROJECT_ID}&from={FROM}&to={TO}&page={page}',
        headers=headers)
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    for e in data['time_entries']:
        notes = e.get('notes') or ''
        header_ids = set()
        current = []
        for line in notes.splitlines():
            if header_re.match(line):
                current = ticket_re.findall(line)
                header_ids.update(current)
            elif line.strip() == '(no ticket)':
                current = []
            elif line.strip().startswith('- '):
                for tid in current:
                    bullets_by_ticket[tid].append(line.strip()[2:])
        # Prefer header lines; fall back to any #NNN for legacy notes.
        ids = header_ids or set(ticket_re.findall(notes))
        if ids:
            # Split this entry's hours evenly across the tickets it mentions.
            share = e['hours'] / len(ids)
            for tid in ids:
                hours_by_ticket[tid] += share
                dates_by_ticket[tid].add(e['spent_date'])
        else:
            unmatched_hours += e['hours']
    if not data.get('next_page'):
        break
    page = data['next_page']

print(json.dumps({
    'tickets': {t: {'hours': round(h, 2), 'dates': sorted(dates_by_ticket[t]), 'bullets': bullets_by_ticket[t]}
                for t, h in hours_by_ticket.items()},
    'unmatched_hours': round(unmatched_hours, 2),
}))
"
```

**Why even-split:** one Harvest entry covers all of a project's tickets for the day, and there is no finer-grained signal than the entry's hours, so split equally and disclose this in the report's methodology footer so the user can interpret variance accordingly. Legacy entries (one per ticket, or free-form notes) go through the same code path.

`unmatched_hours` (Harvest hours on this project with no ticket reference in the notes) is reported separately so the user can spot under-tagged entries.

## Step 4: Pull each ticket from GitLab

For each ticket ID, in a single batched Bash call where possible:

```bash
glab api --hostname git.affinitybridge.com "projects/<URL-ENCODED-PROJECT-PATH>/issues/<IID>" \
  --jq '{iid, title, description, labels, time_stats, web_url, state}'
```

URL-encode the project path (`/` → `%2F`). Always pass `--hostname`: without it, `glab` picks the host from the cwd's git remote and falls back to gitlab.com, which returns `401` from any non-GitLab checkout. Collect:

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

## Step 6: Build the report

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

Tickets billed in Harvest that lack enough spec to estimate. Each entry lists what's missing.

- **#789** — <title> — *missing: acceptance criteria, scope*
- **#790** — <title> — *missing: any description (placeholder body only)*

## Methodology

- Estimate sources, in priority order: GitLab `/estimate`, spec-embedded number, spec-derived range, undefined.
- Actuals pulled from Harvest by parsing ticket IDs from entry notes (ticket header lines preferred; any `#<id>` for legacy notes). Each entry's hours are split evenly across the tickets it references, so per-ticket actuals are an even-split approximation when several tickets share an entry.
- Unmatched hours = Harvest entries on this project whose notes contain no `#<id>` reference (e.g. no-ticket-only entries).
```

For ranged estimates, **always use the high end of the range** as the estimate value for the variance calculation. Variance is `actual − high`. This treats the upper bound as the commitment.

## Step 7: Record variance history

After printing the report, append this run's per-ticket results to **`estimates.json`** in the config dir, so estimate accuracy can be tracked over time instead of only as point-in-time snapshots. Do this on every run; it is local history, not the client-facing report, so it needs no prompt.

Keys are `{gitlab_path}#{iid}`; each value is a list of snapshots, oldest first:

```json
{
  "affinitybridge/islandhealth#189": [
    {
      "computed_at": "2026-10-04",
      "range": ["2026-09-01", "2026-09-30"],
      "estimate_hours": 6,
      "estimate_source": "derived from spec",
      "actual_hours": 5.5,
      "variance": -0.5,
      "labels": ["search"]
    }
  ]
}
```

- `estimate_hours` is the value used for variance (the high end of a range); `null` for undefined tickets, with `variance` also `null`.
- `actual_hours` is the even-split figure from Step 3, so per-ticket variance carries the same approximation as the report.
- A rerun with the same `computed_at` and `range` replaces that snapshot instead of adding a duplicate.
- Read → mutate in memory → write atomically (`estimates.json.tmp`, then rename). Create the file if it does not exist.

## Step 8: Offer to save

After printing, ask: *"Save this report to `docs/value-estimates/<project-slug>-value-estimate-<from>_<to>.md`?"* — unless `--save` was passed, in which case write it directly. Create `docs/value-estimates/` if missing.

The `docs/value-estimates/` folder should be gitignored (these reports often contain client-sensitive hours and ticket detail). If the current repo's `.gitignore` does not already list `docs/value-estimates/`, add the line on first save and mention to the user that you did.

## Failure modes (fail loud, exit clean)

- `glab` not authenticated → print the `glab auth status` error, instruct the user to run `glab auth login`, exit.
- Harvest env vars missing → print which one is missing, point at `~/.zshenv`, exit.
- No GitLab project mapping for the requested Harvest project → ask the user once, persist, continue.
- No tickets matched in date range → print a short note ("No tickets found for `<project>` between `<from>` and `<to>`") and exit; don't generate an empty report.
