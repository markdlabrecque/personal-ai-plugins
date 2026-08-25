#!/bin/bash
# Commit-capture hook: appends ONE JSON event (a single line) to
# ~/daily_reports/{YYYY-MM-DD-Day}.jsonl describing the just-made commit.
#
# This is the single, unified commit-capture path. It is invoked from two
# triggers, both of which dedupe on the commit SHA so the overlap is harmless:
#   1. Claude Code PostToolUse hook (hooks.json) — fires when Claude commits.
#   2. A git-native post-commit shim (~/.config/git/hooks/post-commit) — fires
#      on every commit, including manual ones. The shim just calls this script.
#
# JSONL (one event per line) is used instead of Markdown so concurrent writers
# (this hook, the session Stop hook, and the `worklog` CLI) can each append
# atomically without interleaving — a single write() under PIPE_BUF (4 KB) with
# O_APPEND is atomic on POSIX, whereas a multi-line Markdown entry is not.
#
# Requires `jq` (already a dependency of the timesheet plugin). jq builds the
# JSON so commit messages with quotes/backslashes/unicode are escaped correctly.

set -euo pipefail

# Consume stdin (PostToolUse sends a JSON payload we don't need; we read git).
cat > /dev/null

command -v jq >/dev/null 2>&1 || exit 0   # no jq → silently skip, never block a commit

# --- Commit details -------------------------------------------------------
commit_sha=$(git log -1 --format="%h" 2>/dev/null) || exit 0
commit_msg=$(git log -1 --format="%s" 2>/dev/null) || exit 0

# --- repo/branch ----------------------------------------------------------
# repo: "<owner>/<repo>" parsed from origin's URL (host + trailing .git stripped);
# falls back to the local worktree directory name when there is no remote.
remote_url=$(git config --get remote.origin.url 2>/dev/null || true)
if [ -n "$remote_url" ]; then
  repo=$(printf '%s' "$remote_url" | sed -E 's#\.git/?$##; s#/$##; s#^.*[:/]([^:/]+/[^/]+)$#\1#')
else
  repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null) || repo="unknown"
fi
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="unknown"

# --- timestamps / target file --------------------------------------------
ts=$(date "+%Y-%m-%dT%H:%M:%S%z")          # ISO 8601 with offset; %z is BSD+GNU safe
date_file=$(date "+%Y-%m-%d-%A")
report_dir="${DAILY_REPORTS_DIR:-$HOME/daily_reports}"
report_file="${report_dir}/${date_file}.jsonl"
mkdir -p "$report_dir"

# --- Deduplicate ----------------------------------------------------------
# Skip if this commit's SHA is already recorded today (handles the two-trigger
# overlap, and re-runs). Matches the JSON field form to avoid false positives.
if [ -f "$report_file" ] && grep -qF "\"sha\":\"$commit_sha\"" "$report_file" 2>/dev/null; then
  exit 0
fi

# --- Ticket references (#NNN) from the subject, in source order, de-duped ---
tickets_json=$(printf '%s\n' "$commit_msg" \
  | { grep -oE '#[0-9]+' || true; } \
  | awk '!seen[$0]++' \
  | jq -R . | jq -sc .)
[ -n "$tickets_json" ] || tickets_json='[]'

# --- Emit one JSON line (atomic append) -----------------------------------
jq -cn \
  --arg ts "$ts" \
  --arg repo "$repo" \
  --arg branch "$branch" \
  --arg sha "$commit_sha" \
  --arg summary "$commit_msg" \
  --argjson tickets "$tickets_json" \
  '{ts:$ts, source:"commit", repo:$repo, branch:$branch, tickets:$tickets, sha:$sha, summary:$summary}' \
  >> "$report_file"
