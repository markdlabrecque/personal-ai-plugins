#!/bin/bash
# Session-capture hook: on SessionEnd, appends ONE JSON event (a single line)
# to ~/daily_reports/{YYYY-MM-DD-Day}.jsonl recording that a Claude Code session
# happened, where, and a pointer to its transcript.
#
# Deliberately "dumb": it does NOT summarize the session. It records cwd, the
# git repo/branch (if cwd is a repo), the transcript path, the session id, and
# the duration — and leaves "summary": null. The timesheet skill's enrichment
# step fills the real summary later by reading the transcript with the model.
# This keeps capture cheap and pushes all judgment to summarize-time.
#
# Registered in hooks.json under "SessionEnd" (fires once per session).
# Reads the SessionEnd JSON payload on stdin: session_id, transcript_path, cwd,
# reason, session_duration_seconds.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0   # no jq → skip; never disrupt session exit

payload=$(cat)
[ -n "$payload" ] || exit 0

session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
reason=$(printf '%s' "$payload" | jq -r '.reason // empty')
duration=$(printf '%s' "$payload" | jq -r '.session_duration_seconds // 0')

# Nothing identifiable → not a real SessionEnd payload; skip rather than log junk.
if [ -z "$session_id" ] && [ -z "$transcript" ] && [ -z "$cwd" ]; then
  exit 0
fi

# Derive repo/branch from cwd if it is inside a git work tree.
repo=""; branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  remote_url=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$remote_url" ]; then
    repo=$(printf '%s' "$remote_url" | sed -E 's#\.git/?$##; s#/$##; s#^.*[:/]([^:/]+/[^/]+)$#\1#')
  else
    repo=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null) || repo=""
  fi
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
date_file=$(date "+%Y-%m-%d-%A")
report_dir="${DAILY_REPORTS_DIR:-$HOME/daily_reports}"
report_file="${report_dir}/${date_file}.jsonl"
mkdir -p "$report_dir"

# Dedup on session_id so a re-fire never double-writes the same session.
if [ -n "$session_id" ] && [ -f "$report_file" ] \
   && grep -qF "\"session_id\":\"$session_id\"" "$report_file" 2>/dev/null; then
  exit 0
fi

jq -cn \
  --arg ts "$ts" \
  --arg repo "$repo" \
  --arg branch "$branch" \
  --arg cwd "$cwd" \
  --arg transcript "$transcript" \
  --arg session_id "$session_id" \
  --arg reason "$reason" \
  --argjson duration_s "${duration:-0}" \
  '{ts:$ts, source:"session", cwd:$cwd, repo:$repo, branch:$branch,
    transcript:$transcript, session_id:$session_id, reason:$reason,
    duration_s:$duration_s, tickets:[], summary:null}' \
  >> "$report_file"
