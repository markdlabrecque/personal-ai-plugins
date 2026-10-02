---
name: timesheet
description: "Fill out Harvest timesheet from daily log files. Use this skill whenever the user mentions timesheets, time tracking, time entries, logging hours, filling out Harvest, submitting hours, or anything related to recording work time — even if they just say 'log my time' or 'do my timesheet'. Also trigger when the user asks to sync daily reports/logs to Harvest."
---

# Timesheet Skill

Create Harvest time entries from the user's daily report markdown files in `~/daily_reports/`.

## Arguments

Check the skill arguments for flags before proceeding:

- `--analyze [N]` — Run the **Analyze** flow (see below) instead of the normal entry-creation flow. `N` is an optional number of days to look back (default: 30). If this flag is present, skip straight to the Analyze section.
- `--dry-run` — Walk Steps 1–4 normally, print the planned-entries summary table, then **stop**. Do not POST to Harvest, do not update `tickets.json`. Used for evals and for previewing what a run would do.

**Environment overrides (testing/eval support):**
- `DAILY_REPORTS_DIR` — if set, use this path instead of `~/daily_reports/` for both daily report files and the `meta/` config dir. Lets eval fixtures live entirely outside the user's real reports.

If no `--analyze` flag is present, proceed with the normal flow starting at Step 1.

---

## Analyze flow

When `--analyze` is passed, check Harvest for weekdays with low hours logged.

### Analyze Step 1: Determine lookback period

If the user passed a number after `--analyze` (e.g. `--analyze 60`), use that as the number of days. Otherwise, ask the user how many days to look back — but let them press enter / skip to accept the default of 30 days.

Calculate `START_DATE` as today minus N days, and `END_DATE` as **yesterday** (today minus 1). Today is excluded since the day isn't over yet.

### Analyze Step 2: Fetch time entries and identify gaps

Fetch all time entries for the date range in a **single Bash call** using Python. The Harvest API paginates at 100 entries per page, so handle pagination. Also fetch the user ID and company base URI for generating direct links.

**Important:** Use Python (`urllib.request` + `json`) for any Harvest API call that returns time entries. The `notes` field can contain literal newlines that break `jq`. The `jq` tool is fine for endpoints that don't return notes (e.g., project assignments, company info).

```bash
python3 -c "
import urllib.request, json, os
from datetime import datetime, timedelta

token = os.environ['HARVEST_TOKEN']
account_id = os.environ['HARVEST_ACCOUNT_ID']
headers = {
    'Authorization': f'Bearer {token}',
    'Harvest-Account-Id': account_id,
    'User-Agent': 'Claude-Timesheet-Skill'
}

def api_get(url):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

# Get base URI and user ID for day links
base_uri = api_get('https://api.harvestapp.com/v2/company')['base_uri']
user_id = api_get('https://api.harvestapp.com/v2/users/me')['id']

# Paginate time entries
hours_by_date = {}
page = 1
while True:
    data = api_get(f'https://api.harvestapp.com/v2/time_entries?user_id={user_id}&from=START_DATE&to=END_DATE&page={page}')
    for entry in data['time_entries']:
        d = entry['spent_date']
        hours_by_date[d] = hours_by_date.get(d, 0) + entry['hours']
    if not data.get('next_page'):
        break
    page = data['next_page']

# Enumerate weekdays and find gaps
start = datetime.strptime('START_DATE', '%Y-%m-%d')
end = datetime.strptime('END_DATE', '%Y-%m-%d')
d = start
weekday_count = 0
while d <= end:
    if d.weekday() < 5:  # Mon-Fri
        weekday_count += 1
        ds = d.strftime('%Y-%m-%d')
        day_name = d.strftime('%a')
        total = hours_by_date.get(ds, 0)
        if total < 6:
            ymd = d.strftime('%Y/%m/%d')
            status = 'Missing' if total == 0 else 'Low'
            print(f'{ds}|{day_name}|{total}|{status}|{base_uri}/time/day/{ymd}/{user_id}')
    d += timedelta(days=1)

print(f'WEEKDAY_COUNT={weekday_count}')
"
```

### Analyze Step 3: Print report

From the data, identify all weekdays with < 6 hours (or 0 hours). Display a markdown table sorted by date. Each row includes a direct link to that day in Harvest.

The Harvest day URL format is: `{BASE_URI}/time/day/{YYYY}/{MM}/{DD}/{USER_ID}`

| Date | Day | Hours | Status | Link |
|------|-----|-------|--------|------|
| 2026-03-15 | Mon | 0.0 | Missing | [view](https://example.harvestapp.com/time/day/2026/03/15/123456) |
| 2026-03-18 | Thu | 4.0 | Low | [view](https://example.harvestapp.com/time/day/2026/03/18/123456) |

- **Missing** = 0 hours
- **Low** = greater than 0 but less than 6 hours

End with a summary line: e.g., "3 weekdays with < 6 hours out of 22 weekdays in range."

---

## Normal flow

### Overview

The user's daily work log is a **multi-source, append-only** stream of events (`commit`, `session`, and `manual`) captured to `~/daily_reports/{date}.jsonl` (see *How the daily log is captured*). For a given date range this skill: reads the raw events, **enriches and denoises them** (Step 2.5 — drops ignored noise, summarizes Claude sessions, pulls GitLab activity, collapses duplicates), resolves each to a Harvest project, and creates **one Harvest time entry per Harvest project per day** — always `0.02h` (≈1 minute) as a placeholder the user adjusts to actuals later, Development task. The entry's notes hold one section per ticket (then a no-ticket section), so a day's work on several tickets in the same project is one row to fill in, not many. Events that touch several tickets appear once, under a combined ticket header. Per-ticket hours downstream are an **even split** of the entry's hours across the tickets in its notes.

## Credentials

The Harvest API credentials are read from environment variables:
- `HARVEST_TOKEN` — Personal Access Token
- `HARVEST_ACCOUNT_ID` — Harvest account ID

These are exported from `~/.zshenv` (see `example.zshenv` in this skill directory for a template).

**Every Bash call that touches the Harvest API must begin with `source ~/.zshenv &&`** so it picks up the current token. A long-running session may have been started with a stale or wrong token in its environment; sourcing at call time makes the skill authoritative rather than depending on the session's ambient env. Do not rely on the harness having the right values already loaded.

**Confirm identity before writing.** The intended Harvest `user_id` is stored in `local-context.md` (Step 0 asks for and persists it on first run). Before any POST/DELETE, fetch `GET /v2/users/me` and verify its id matches the stored `user_id` — a token can silently belong to a different Harvest user; if they differ, stop and ask the user rather than writing. For entry creation this check is built into `bin/harvest-post` (see *Step 5*), which refuses to post when the token resolves to another user. All read queries for existing entries must be scoped with `?user_id={id}` using the stored id; an unscoped `/time_entries` returns the whole team when the token has manager access.

## Step 0: Load shared config

Read two files from `~/daily_reports/meta/`:

- **`projects.yml`** — shared project map (used by every skill that touches Harvest / GitLab / daily logs). Each entry can carry: `harvest` (official Harvest project name — **or a list of names** when one codebase bills to several Harvest projects; see *Multi-project codebases*), `gitlab` (project path), `log_aliases` (tokens used in daily logs), `internal: true` (the daily admin / fallback project), `admin_task` (task name on the internal project), `excluded: true` (silently skip). The file may also have a top-level `ignore:` list of glob patterns for raw noise (throwaway/test repos, scratch branches) — see the Enrichment step. Parse with PyYAML or a small custom parser — entries are simple key/value blocks.
- **`local-context.md`** — per-machine bits that aren't shared: the daily reports path (defaults to `~/daily_reports/`) and the Harvest `user_id` (see below).

If `projects.yml` is missing, tell the user to create `~/daily_reports/meta/projects.yml` (use `local-context.example.md` as a starting reference for `local-context.md`) and stop.

**Harvest `user_id`.** This skill scopes every Harvest read and write to a specific user (see *Credentials* → *Confirm identity before writing*). Read the `user_id` from `local-context.md` (a line like `user_id: 123456`). If it is **not set**, do not guess and do not silently fall back to `/v2/users/me` — a token can belong to the wrong Harvest user. Instead: fetch `GET /v2/users/me`, show the user the id, name, and email it resolves to, and ask them to confirm it is the intended person (or supply the correct id). Then **write the confirmed id back to `local-context.md`** as `user_id: <id>` (creating the file if it doesn't exist) so subsequent runs skip the prompt. Use this stored id everywhere the flow needs `user_id`.

From `projects.yml`, derive:
- **Excluded projects** — every entry with `excluded: true`. Match against log project names case-insensitively, against both `log_aliases` and `harvest` (when present).
- **Internal project** — the single entry with `internal: true`. Its `harvest` value is the daily admin project; its `admin_task` is the task name to use.
- **Ignore globs** — the top-level `ignore:` list (may be absent → empty). Used by the Enrichment step to drop raw-noise events before anything reaches Harvest.
- **Multi-project codebases** — **normalize every entry's `harvest` to a list** (a scalar becomes a one-item list). A one-item list resolves directly (unchanged 1:1 behaviour); a list of more than one means the codebase bills to several Harvest projects and triggers the *Project disambiguation* prompt in Step 4. The `internal` entry must name a single project — if it's given a list, use the first and warn.

## How the daily log is captured (background)

The daily log is a **multi-source, append-only** record. Three capturers write newline-delimited JSON (one event per line) to `~/daily_reports/{YYYY-MM-DD-Day}.jsonl`:

- **`commit`** — a git commit (via the plugin's PostToolUse hook and/or a git-native post-commit shim; both dedupe on SHA). Fields: `repo`, `branch`, `tickets[]`, `sha`, `summary`.
- **`session`** — a Claude Code session ended (SessionEnd hook). Fields: `cwd`, `repo`, `branch`, `transcript`, `session_id`, `reason`, `duration_s`, and `summary: null` — the summary is **deliberately left null for the Enrichment step to fill** by reading the transcript.
- **`manual`** — the `worklog "…"` CLI, for work no hook sees (calls, meetings, review, research). Fields: `summary`, optional `project`, `tickets[]`.

Every event has `ts` (ISO 8601) and `source`. Because the log is intentionally noisy (every commit, every session), the Enrichment step below is responsible for collapsing it into clean billable items.

**Legacy:** logs written before the JSONL cutover are Markdown `{date}.md` files (see the Legacy Markdown appendix). Read both formats for the range.

## Step 1: Determine the date range

If the user hasn't specified dates, ask them what time period they want to log. Common patterns:
- "today" / "yesterday"
- "this week" / "last week"
- "March 10-14"
- A specific date like "Friday"

Convert relative references to absolute dates. Daily report filenames follow the pattern `{YYYY-MM-DD}-{DayOfWeek}.jsonl` (current) or `{YYYY-MM-DD}-{DayOfWeek}.md` (legacy).

## Step 2: Fetch all data in a single call

Gather existing Harvest entries, project assignments, and daily report contents in **one Bash call**. Use `jq` for project assignments (safe — no notes field) and Python for time entries (notes field contains literal newlines that break `jq`).

Replace `START_DATE` and `END_DATE` with the first and last dates of the range, and list the date glob patterns in the `for` loop.

```bash
echo "=== EXISTING ==="
python3 -c "
import urllib.request, json, os
headers = {
    'Authorization': 'Bearer ' + os.environ['HARVEST_TOKEN'],
    'Harvest-Account-Id': os.environ['HARVEST_ACCOUNT_ID'],
    'User-Agent': 'Claude-Timesheet-Skill'
}
# Filter to the current user. The token may have manager access, in which case
# an unfiltered /time_entries returns the whole team and every day looks 'already
# logged'. Always scope by user_id.
uid_req = urllib.request.Request('https://api.harvestapp.com/v2/users/me', headers=headers)
with urllib.request.urlopen(uid_req) as resp:
    user_id = json.loads(resp.read())['id']
dates = set()
page = 1
while True:
    req = urllib.request.Request(
        f'https://api.harvestapp.com/v2/time_entries?user_id={user_id}&from=START_DATE&to=END_DATE&page={page}',
        headers=headers)
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    for e in data['time_entries']:
        dates.add(e['spent_date'])
    if not data.get('next_page'):
        break
    page = data['next_page']
print(json.dumps(sorted(dates)))
"

HEADERS=(-H "Authorization: Bearer $HARVEST_TOKEN" \
         -H "Harvest-Account-Id: $HARVEST_ACCOUNT_ID" \
         -H "User-Agent: Claude-Timesheet-Skill")

echo "=== PROJECTS ==="
curl -s "https://api.harvestapp.com/v2/users/me/project_assignments?is_active=true" \
  "${HEADERS[@]}" | jq '[.project_assignments[] | {
    name: .project.name,
    id: .project.id,
    tasks: [.task_assignments[] | {name: .task.name, id: .task.id}]
  }]'

echo "=== REPORTS ==="
# Read JSONL (current) and .md (legacy) for each date in the range. List one
# glob pair per date. JSONL is the raw multi-source event stream; .md is only
# present for dates before the JSONL cutover.
for f in ~/daily_reports/START_DATE-*.jsonl ~/daily_reports/START_DATE-*.md \
         ~/daily_reports/NEXT_DATE-*.jsonl ~/daily_reports/NEXT_DATE-*.md; do
  [ -f "$f" ] && echo "--- $(basename "$f") ---" && cat "$f"
done
```

**If any entries already exist for a given date** (present in the `EXISTING` array), **skip that entire day.** Do not create any new entries for it. Mention skipped days in the summary table so the user knows.

If a daily report file doesn't exist for a given date, skip it silently — weekends and days off won't have files.

## Step 2.5: Enrichment — reconstruct and denoise the day

The raw JSONL log is intentionally a firehose: every commit, every session, every `worklog` line. This step collapses it into a clean set of billable work items **before** any grouping or Harvest mapping. Run it per date over the events fetched in Step 2. Do the work with judgment (you are the model) — there is no rigid parser.

Process events in this order:

**1. Drop ignored noise.** Discard any event whose `repo` or `repo/branch` matches one of the **ignore globs** from `projects.yml` (case-insensitive). Also drop events whose project resolves to an `excluded: true` entry. Count what you dropped and report it in Step 7 — **never silently truncate.** (Example: `acr-localgit-*` sandbox commits.)

**2. Summarize `session` events.** Each `source:"session"` event has `summary: null` by design. For each one:
   - **If it is throwaway** — very short (`duration_s` under ~120s) *and* the same repo/day already has `commit` or `manual` events — drop it. The session only exists because you committed; counting it again would double-log.
   - **Otherwise, summarize it.** Read its `transcript` file (JSONL; the user's asks are the `type:"user"` messages) and write a one-line summary of what was actually accomplished. Infer `tickets[]` (from branch name, transcript content, or commits in the same repo/day) and the project (from `cwd`/`repo`). Keep only billable substance; if the session was pure exploration with no real outcome, drop it.
   - **Backstop:** if `transcript` is missing or unreadable, fall back to `"Claude session — <repo>/<branch>"` as the summary and let the user confirm in Step 4.

**3. Pull GitLab activity (if available).** This catches review/triage work that never produced a local commit. If `glab` is on PATH (and a token is configured), pull the user's activity for the range:
   ```bash
   glab api "/events?after=START_MINUS_1&before=END_PLUS_1&per_page=100" 2>/dev/null
   ```
   Keep only meaningful actions (commented on / approved an MR, opened/closed/merged an MR, opened/closed an issue). For each, derive a work item: project from the event's GitLab project path matched against `projects.yml` `gitlab:`, ticket from the issue/MR iid, summary from the action + title. If `glab` is unavailable or unauthenticated, **skip this and note it in Step 7** ("GitLab activity not pulled — glab unavailable"). Never fail the run over it.

**4. Merge, dedupe, collapse.** Combine the surviving `commit`, `session`, `manual`, and GitLab items. Collapse everything that refers to the same `(date, resolved-project, ticket)`:
   - A session whose only outcome was commits you already have → folded in (no separate line).
   - Multiple commits / a commit + a GitLab MR comment on the same ticket/day → one item whose summary is the **union** of their bullets (drop near-duplicate text).
   - A `manual` entry with an explicit `project`/`tickets` is authoritative for its own mapping.

The output of this step is a denoised list of work items, each with: a **date**, a **project hint** (`repo` or `project`), **`tickets[]`**, and one or more **summary bullets**. This feeds Step 3 exactly as the old per-`###`-entry list used to.

## Step 3: Parse and group entries

Step 3 now operates on the **enriched work items** from Step 2.5, not raw log lines. Each item carries a project hint (`repo`/`project`), `tickets[]`, and summary bullet(s). (For **legacy `.md`** dates with no JSONL, parse entries first via the Legacy Markdown appendix, then treat each parsed entry as a work item here.)

Resolve each item's project hint to a project name (matching is finalized in Step 4). Then determine its tickets — sources in priority order:

1. **The work item's `tickets[]`** (populated by capture or by Enrichment — from a commit subject, a `worklog -t`, a GitLab iid, or a session inference). Authoritative — use it and skip the regex scan. For legacy `.md` entries this is the `**Tickets:**` line.
2. **Regex scan** of the item's summary bullet(s) for `#NNN` patterns (`#189`, `(#189)`, `ticket #189`). Capture all distinct IDs.
3. **No reference found.** Prompt the user inline: *"entry on YYYY-MM-DD '<summary>' has no ticket — link one? (enter a `#NNN`, or press enter to leave unlinked)"*. If the user supplies a ticket, treat it as authoritative for this run. If they skip, the item goes in the no-ticket section of that (date, project)'s entry.

Backfilling user-supplied tickets back into the source log is **out of scope** for now — see the Roadmap section. The prompt only collects the ticket for this run.

**Multiple tickets on one item** → the item stays a single item carrying all its tickets; it is written **once** in the entry's notes, under a combined header (see below). Do not duplicate its bullets per ticket.

**Grouping key: `(date, resolved Harvest project)`.** Project resolution (Step 4, including multi-project disambiguation, which is asked per `(codebase, ticket)`) happens **before** grouping. Then all items whose project resolves to the same Harvest project on the same date become **one** Harvest entry (`0.02h`, Development task). One codebase can therefore yield two entries on one day if its tickets resolve to different Harvest projects; two codebases billing to the same Harvest project share one entry.

Format the entry's notes as one section per ticket, in ascending ticket order (a combined header such as `#142 #143` sorts by its lowest ticket number among the sections), then a `(no ticket)` section last. Each section is a header line followed by `- ` bullets (the item's summary, trimmed of timestamps, project names, and the leading `#NNN` token). Within a ticket section, collapse multiple commits on that ticket into its bullets. An item tied to several tickets appears once, under a combined header listing them (e.g. `#487 #489`) — no duplicate bullets. Example:

```
#265
- Update site search placeholder to 'Search Island Health'
- Fix /search clear button position and remove duplicate
#266
- Add ih-search:relevance-report drush command
#487 #489
- Cross-cutting session-token refactor
(no ticket)
- Merge branch '268-synonyms-management-page' into search
```

Omit the `(no ticket)` header when the entry has no ticket sections (entry is only no-ticket work → plain bullets, no header). A merge commit or chore-only item with no ticket reference (that the user opts not to link) goes in the no-ticket section.

### Exclusion rule

Silently skip any entry whose project name matches one of the **excluded projects** from `.local-context.md` (case-insensitive). Never create Harvest time entries for excluded projects.

If an entry has no identifiable project, assign it to the fallback bucket (see Step 4).

## Step 4: Resolve Harvest projects

Use the `PROJECTS` data already fetched in Step 2 (which contains project name, ID, and task assignments for each active project).

From this data:
1. Build a lookup of project names to IDs
2. Find the "Development" task ID (search task assignments for a task named "Development")
3. Match each log project name against entries in `projects.yml` — first by `log_aliases` (exact, case-insensitive), then by fuzzy match against `harvest` (keywords, ignoring case/punctuation; when `harvest` is a list, fuzzy-match against **any** name in it). The matched entry then resolves to a Harvest project:
   - **Single-project entry** (`harvest` normalizes to one name) — that name maps to a Harvest project ID via the lookup from step 1. For example, log alias `ih` resolves to `Modernization of Island Health’s Digital Entry Point...`, which maps to a project ID in Harvest.
   - **Multi-project entry** (`harvest` is a list of more than one) — the codebase bills to several Harvest projects, and the right one can differ per work item (one ticket is retainer work, another a fixed-bid phase), so it can't be resolved automatically. **Consult the user** via *Project disambiguation* (below) to pick which listed project this item's entry belongs to.
4. Identify the **internal project** (the entry with `internal: true` in `projects.yml`) — find its ID in the project list. This is used for two purposes:
   - **Fallback**: any log entry whose project can't be matched gets assigned here.
   - **Daily admin entry**: for every **weekday** (Mon–Fri) being processed, automatically add a 0.02h entry to this project with the **admin task** from `projects.yml` and a blank comment. This entry should always appear in the summary table. Do **not** add an admin entry on weekends (Sat/Sun), even if the user logged work on those days.
   - The admin entry stays a **separate** entry (internal project, admin task, blank notes). Any Development-task work that resolves to the internal project (including fallback items) is its own Development entry under the same `(date, project)` grouping rule — a different task from admin, so still at most one of each per day.

**Placeholder duration:** every entry created by this skill — per-project Development entries and the admin entry — uses `0.02h` (≈1 minute). The user adjusts each entry's duration to actuals later in the Harvest UI. The placeholder is intentionally tiny so untouched entries are obvious.

The API paginates at 100 results. If `next_page` is present in the Step 2 project response, fetch subsequent pages in a follow-up call. In practice, most users have fewer than 100 active project assignments.

### Project disambiguation (multi-project codebases)

When a work item resolves to a **multi-project** entry (Step 4.3), prompt the user inline **before** building the summary table — mirroring the no-ticket prompt in Step 3:

> *entry on YYYY-MM-DD [#NNN] '<summary>' — codebase `<alias>` maps to multiple Harvest projects; which applies? [1] Omni - Retainer  [2] Omni - Phase 2  (enter a number, default 1)*

- **Cache the answer keyed by `(codebase, ticket)` for the run**, so the same ticket never re-prompts across multiple days, while different tickets on the same codebase are asked independently (they may bill to different projects). A no-ticket item caches under `(codebase, "__none__")`.
- **Non-interactive run or empty reply** → default to the **first** listed project and record it in the final summary (`defaulted <alias> → <project> (N candidates)`). Never silently guess without surfacing it.
- **Excluded interplay:** if **every** candidate of a multi-project entry is `excluded: true`, skip the item (silent, like any excluded project). Otherwise disambiguate among the non-excluded candidates only.

After resolving projects (and disambiguation), group items by `(date, Harvest project)` as described in Step 3. Before creating any entries, show the user a summary table with **one row per entry**; the Ticket column lists every ticket in the entry (`(none)` for the no-ticket section):

| Date | Log Project | Harvest Project | Ticket | Hours | Summary |
|------|------------|-----------------|--------|-------|---------|
| 2026-03-25 | clientportal/api | Client Portal - API | #142, #143, (none) | 0.02 | #142<br>- Config cleanup<br>- PHPUnit setup<br>#143<br>- Fix token refresh<br>(no ticket)<br>- Merge release branch |
| 2026-03-25 | (admin) | *(internal project)* | — | 0.02 | |

Ask the user to confirm before proceeding. This matters because fuzzy matching can produce wrong mappings. **Flag any row resolved via project disambiguation** (e.g. a `*` on the Harvest Project cell) and **list any auto-defaulted picks** (non-interactive fallback to the first candidate) just above the table, so a wrong multi-project mapping is easy to catch here.

## Step 5: Create time entries

For all confirmed entries, POST them with the bundled `bin/harvest-post` script — **one Bash call, no hand-written POST loop.** The script owns identity verification, the POST loop, HTTP error handling, and the result lines, so a run only has to produce the entry data. The account uses duration-based tracking (not timestamp timers); supplying `hours` without `started_time` does not start a timer (`is_running: false` in the response).

Each entry's `notes` use the sectioned format from Step 3: a ticket header line (`#NNN`, or `#NNN #MMM` for an item tied to several tickets) followed by its bullets, one section per ticket, then `(no ticket)` last. Header lines that consist only of `#NNN` tokens are what downstream tools (value-estimates, future report skills) parse for per-ticket aggregation. An entry with only no-ticket work has plain bullets; the admin entry has blank notes.

**Locating the script.** It lives at `bin/harvest-post` inside this plugin — `"$CLAUDE_PLUGIN_ROOT/bin/harvest-post"` when that variable is set. If it isn't, derive it from this skill's own path (`<this SKILL.md>/../../../bin/harvest-post`). Do not copy the script elsewhere and do not reimplement it inline.

**Write the entries to a JSON file, then run the script.** The file is a JSON list; each object is passed to Harvest as-is and must carry `project_id`, `task_id`, `spent_date`, and `hours` (`notes` optional). Write it with a heredoc or a small Python dump — never inline the JSON as a shell argument, since notes contain newlines.

```bash
source ~/.zshenv && \
cat > /tmp/harvest-entries.json <<'JSON'
[
  {"project_id": 111, "task_id": 222, "spent_date": "2026-03-23", "hours": 0.02,
   "notes": "#142\n- Task one\n- Task two\n#143\n- Task three\n(no ticket)\n- Merge release branch"},
  {"project_id": 111, "task_id": 333, "spent_date": "2026-03-23", "hours": 0.02, "notes": ""}
]
JSON
"$CLAUDE_PLUGIN_ROOT/bin/harvest-post" --user-id 123456 /tmp/harvest-entries.json
```

`--user-id` is **required** and takes the confirmed `user_id` from `local-context.md`. The script fetches `GET /v2/users/me` and refuses to post anything if the token resolves to a different Harvest user — this is the identity check from *Credentials*, so the flow does not need to do it separately.

Output is one pipe-delimited line per entry, in input order:

```
OK|2920326492|2026-03-23|Client Portal - API|0.02
OK|2920326493|2026-03-23|Acme Corp [INT] Internal|0.02
FAIL|2|422|Project is archived
```

- `OK|<entry_id>|<spent_date>|<project name>|<hours>` — the `entry_id` is what Step 6 writes to the sidecar.
- `FAIL|<index>|<status>|<message>` — `index` is the entry's position in the JSON list. Failures do not stop the run; report them in Step 7.
- Exit status: `0` all created, `1` at least one `FAIL`, `2` a usage/config/identity error (**nothing was posted** — fix and rerun).

For `--dry-run` (see *Flags*), the flow stops after the Step 4 table and never reaches this step. The script's own `--dry-run` flag validates the JSON and the identity check and prints `DRY|...` lines without posting — useful when debugging the entry payload itself.

## Step 6: Update tickets sidecar

After successful entry creation, update `~/daily_reports/meta/tickets.json` so per-ticket rollups are O(1) for downstream skills (`value-estimates`, future report skills).

Schema — keys are `{project_slug}#{ticket}`, where `project_slug` is the first `log_aliases` token of the matched project entry in `projects.yml` (so `ih#189`, not the long Harvest name):

```json
{
  "ih#189": {
    "title": "Update site search placeholder to 'Search Island Health'",
    "harvest_project": "Modernization of Island Health’s Digital Entry Point for Health Services | VIHA PO# 1401706",
    "first_seen": "2026-05-04",
    "last_seen": "2026-05-04",
    "days_active": 1,
    "harvest_hours": 0.02,
    "harvest_entry_ids": [2920326492]
  }
}
```

Upsert rules per ticket touched in this run:
- `title` — set on first sight to the first bullet of the ticket's section in the first entry it appears in; never overwritten unless empty.
- `harvest_project` — the matched Harvest project name.
- `first_seen` / `last_seen` — min / max of all dates this ticket appears on (across the lifetime of the file, not just this run).
- `days_active` — count of distinct dates in the union of all dates this ticket has appeared on.
- `harvest_hours` — sum, over every linked Harvest entry id, of `entry hours / number of distinct tickets referenced in that entry's ticket headers`. This is an **even split**: an entry shared by several tickets contributes an equal share to each (the no-ticket section does not count as a ticket). Ticket counting uses the same extraction rule as value-estimates Step 6 (header lines made only of `#NNN` tokens; if none, any `#NNN` in the notes). Round each ticket's `harvest_hours` to 2 decimals only after summing. Re-derive from Harvest, do not just add this run's hours, so user-edited durations are reflected accurately.
- `harvest_entry_ids` — append-only set of Harvest entry IDs whose notes include this ticket. Since entries are per-project-per-day, **every ticket in an entry gets that entry's id appended**; one id is therefore shared by all tickets in the entry.

If the file doesn't exist, create it. Read → mutate in memory → write atomically (write to `tickets.json.tmp`, rename). The no-ticket section and the admin entry are **not** recorded in the sidecar (an entry with only no-ticket work creates no sidecar keys).

The sidecar is also a natural surface for a future `--backsync` mode (see Roadmap) that pulls actual hours from Harvest and writes them back into the daily report markdown.

## Step 7: Report results

After all entries are created, show a final summary:
- How many entries were created
- Any that failed and why
- Any log entries that were skipped (excluded projects, no project match, etc.)
- **Enrichment summary** (from Step 2.5): how many raw events were dropped as ignored noise, how many sessions were summarized vs. dropped as throwaway, and whether GitLab activity was pulled (or skipped because `glab` was unavailable). Surfacing this keeps the denoising honest — the user can see nothing billable was silently discarded.

## Roadmap

Known follow-ups, not yet implemented:

- **`**Tickets:**` line backfill.** When the user supplies a ticket via the inline prompt in Step 3, write a `**Tickets:** #NNN` line back into the source markdown so the file becomes self-describing for next time. Out of scope until the parser side is proven.
- **`--backsync` mode.** Pull every Harvest entry for the past N days and write actual hours back into the matching daily report entry as a `**Hours:**` line, so the daily report mirrors Harvest at any point. Depends on the per-project-per-day entry shape being stable (already true) and the sidecar (already in place).
- **Variance persistence.** Extend the sidecar (or add `~/daily_reports/meta/estimates.json`) so each ticket carries `{estimate_hours, estimate_source, actual_hours, variance, computed_at}` over time, giving longitudinal accuracy data instead of point-in-time snapshots.

## Appendix: Legacy Markdown format

Dates logged **before the JSONL cutover** are Markdown files (`~/daily_reports/{YYYY-MM-DD-Day}.md`) instead of `.jsonl`. When the range includes such a date, parse it into work items as follows, then feed those items into Step 3 like any other:

Each file contains entries under `###` headers. The project identifier appears in one of these forms:
- `**Project**: project/name` or `**Project:** project/name`
- `### HH:MM — project/name` (project in the header itself)
- `Project: project/name` (plain text, no bold)
- Freeform mention like `- sideproject / api` at the end

For tickets, prefer a `**Tickets:** #NNN` (or `#NNN, #MMM`) line in the entry body — it is authoritative, equivalent to a work item's `tickets[]`. Otherwise regex-scan the entry body for `#NNN`. The `###` header title (minus the timestamp and project) becomes the item's summary bullet.

This appendix is read-only history; nothing new is written in Markdown.
