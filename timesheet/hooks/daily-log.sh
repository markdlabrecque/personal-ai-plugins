#!/bin/bash
# Commit-capture hook: appends ONE JSON event per newly-seen commit (a single
# line each) to ~/daily_reports/{YYYY-MM-DD-Day}.jsonl.
#
# This is the single, unified commit-capture path. It is invoked from two
# triggers, both of which dedupe on the commit SHA so the overlap is harmless:
#   1. Claude Code PostToolUse hook (hooks.json) — fires when Claude commits.
#   2. A git-native post-commit shim, if one is installed — fires on every
#      commit, including manual ones. The shim just calls this script.
#
# WHY THIS SWEEPS INSTEAD OF READING ONE HEAD
#
# The obvious implementation — `git log -1` in the process's cwd — is wrong for
# any repo laid out as a bare dir plus sibling worktrees:
#
#   project/.bare                     <- cwd resolves HERE
#   project/work/repo/main
#   project/work/repo/some-branch     <- the commit actually landed HERE
#
# Claude Code runs hooks in the session's project directory, and a `cd` inside
# the Bash tool call does not leak out to the hook. So cwd lands on the bare
# parent, `git log -1` returns the bare repo's HEAD (some unrelated branch tip),
# and the SHA dedupe below then silently drops the event because that older SHA
# was already logged. The commit vanishes with no error.
#
# Instead: collect every plausible directory (the payload cwd, plus any `cd` or
# `git -C` target named in the command), expand each to ALL worktrees of its
# repo, and log any worktree HEAD that is recent and not yet recorded. Only one
# commit per worktree is ever considered, so a rebase adds one line, not fifty.
#
# This also means over-triggering is SAFE: a command that merely mentions
# "commit" costs one cheap sweep that finds nothing new. hooks.json matches
# loosely on purpose (`git … commit` with any flags between), because a missed
# commit is unrecoverable while a redundant sweep is free.
#
# JSONL (one event per line) is used instead of Markdown so concurrent writers
# (this hook, the session Stop hook, and the `worklog` CLI) can each append
# atomically without interleaving — a single write() under PIPE_BUF (4 KB) with
# O_APPEND is atomic on POSIX, whereas a multi-line Markdown entry is not.
#
# Requires `jq` (already a dependency of the timesheet plugin). jq builds the
# JSON so commit messages with quotes/backslashes/unicode are escaped correctly.
#
# Env:
#   DAILY_REPORTS_DIR         override the report directory (default ~/daily_reports)
#   DAILY_LOG_WINDOW_SECONDS  how recent a commit must be to be logged (default 600)

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0   # no jq → silently skip, never block a commit

# --- Inputs ---------------------------------------------------------------
# PostToolUse sends a JSON payload; the git-native shim sends nothing. Both are
# fine — an unparseable or empty payload just falls back to the current dir.
payload=$(cat 2>/dev/null || true)

cmd=""
cwd=""
if [ -n "$payload" ]; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[ -n "$cwd" ] || cwd="$PWD"

window="${DAILY_LOG_WINDOW_SECONDS:-600}"

# --- Candidate directories ------------------------------------------------
candidates=""

add_candidate() {
  local d="${1:-}"
  [ -n "$d" ] || return 0
  # Strip one layer of surrounding quotes and expand a leading ~.
  d="${d%\"}"; d="${d#\"}"
  d="${d%\'}"; d="${d#\'}"
  case "$d" in
    "~") d="$HOME" ;;
    "~/"*) d="$HOME/${d#\~/}" ;;
  esac
  [ -d "$d" ] || return 0
  candidates="${candidates}${d}"$'\n'
}

# Walk the command as whitespace-separated tokens and pick up the argument
# after `cd` and after `git -C`. Done in pure bash rather than with a regex:
# BSD and GNU grep/sed diverge on word boundaries and lazy quantifiers, and
# this hook must behave identically on both.
if [ -n "$cmd" ]; then
  set -f                      # no globbing while we split on whitespace
  prev=""; prev2=""
  for tok in $cmd; do
    case "$prev" in
      cd) add_candidate "$tok" ;;
      -C) [ "$prev2" = "git" ] && add_candidate "$tok" ;;
    esac
    prev2="$prev"; prev="$tok"
  done
  set +f
fi

add_candidate "$cwd"

[ -n "$candidates" ] || exit 0

# --- Expand candidates to worktrees ---------------------------------------
# Every candidate contributes all worktrees of its repo, so a commit in a
# sibling worktree is found from the bare parent (or from any other worktree).
worktrees=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  git -C "$dir" rev-parse --git-common-dir >/dev/null 2>&1 || continue
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    worktrees="${worktrees}${wt}"$'\n'
  done <<EOF
$(git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
EOF
done <<EOF
$candidates
EOF

# Deduplicate; a repo reached from several candidates is still one sweep.
worktrees=$(printf '%s\n' "$worktrees" | awk 'NF && !seen[$0]++')
[ -n "$worktrees" ] || exit 0

# --- Report file ----------------------------------------------------------
report_dir="${DAILY_REPORTS_DIR:-$HOME/daily_reports}"
report_file="${report_dir}/$(date "+%Y-%m-%d-%A").jsonl"
mkdir -p "$report_dir"

now=$(date "+%s")
ts=$(date "+%Y-%m-%dT%H:%M:%S%z")   # ISO 8601 with offset; %z is BSD+GNU safe

# --- Log each worktree's HEAD, if new and recent ---------------------------
while IFS= read -r wt; do
  [ -n "$wt" ] || continue

  # A bare repo has no working HEAD of its own worth attributing; its branches
  # are covered by the worktrees checked out from it.
  [ "$(git -C "$wt" rev-parse --is-bare-repository 2>/dev/null || echo true)" = "false" ] || continue

  commit_sha=$(git -C "$wt" log -1 --format="%h" 2>/dev/null) || continue
  [ -n "$commit_sha" ] || continue

  # Already recorded today? Matches the JSON field form to avoid false positives.
  if [ -f "$report_file" ] && grep -qF "\"sha\":\"$commit_sha\"" "$report_file" 2>/dev/null; then
    continue
  fi

  # Only recent commits. Without this, the first sweep in a repo would log the
  # tip of every worktree regardless of age — months of history as "today".
  commit_epoch=$(git -C "$wt" log -1 --format="%ct" 2>/dev/null) || continue
  age=$(( now - commit_epoch ))
  [ "$age" -le "$window" ] && [ "$age" -ge -60 ] || continue

  commit_msg=$(git -C "$wt" log -1 --format="%s" 2>/dev/null) || continue

  # repo: "<owner>/<repo>" parsed from origin's URL (host + trailing .git stripped);
  # falls back to the worktree directory name when there is no remote.
  remote_url=$(git -C "$wt" config --get remote.origin.url 2>/dev/null || true)
  if [ -n "$remote_url" ]; then
    repo=$(printf '%s' "$remote_url" | sed -E 's#\.git/?$##; s#/$##; s#^.*[:/]([^:/]+/[^/]+)$#\1#')
  else
    repo=$(basename "$wt")
  fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="unknown"

  # Ticket references (#NNN) from the subject, in source order, de-duped.
  tickets_json=$(printf '%s\n' "$commit_msg" \
    | { grep -oE '#[0-9]+' || true; } \
    | awk '!seen[$0]++' \
    | jq -R . | jq -sc .)
  [ -n "$tickets_json" ] || tickets_json='[]'

  jq -cn \
    --arg ts "$ts" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg sha "$commit_sha" \
    --arg summary "$commit_msg" \
    --argjson tickets "$tickets_json" \
    '{ts:$ts, source:"commit", repo:$repo, branch:$branch, tickets:$tickets, sha:$sha, summary:$summary}' \
    >> "$report_file"
done <<EOF
$worktrees
EOF
