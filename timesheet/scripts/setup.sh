#!/usr/bin/env bash
# Scaffolds the shared config directory used by the `timesheet` and
# `value-estimates` plugins: ~/daily_reports/meta/projects.yml and
# ~/daily_reports/meta/local-context.md.
#
# Idempotent — never overwrites existing files. Run once after enabling the
# plugin. Edit the generated files to match your Harvest + GitLab setup.
set -euo pipefail

REPORTS_DIR="${DAILY_REPORTS_DIR:-$HOME/daily_reports}"
META_DIR="$REPORTS_DIR/meta"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$META_DIR"

PROJECTS_FILE="$META_DIR/projects.yml"
if [[ ! -f "$PROJECTS_FILE" ]]; then
  cat > "$PROJECTS_FILE" <<'YAML'
# Project map shared by the `timesheet` and `value-estimates` plugins.
#
# Each entry supports:
#   harvest:      Official Harvest project name (used to match the Harvest API).
#   gitlab:       GitLab project path (e.g. "group/subgroup/repo").
#   log_aliases:  Tokens used in daily report markdown to identify this project.
#   internal:     true on the single "daily admin" / fallback project.
#   admin_task:   Task name on the internal project (e.g. "General").
#   excluded:     true to silently skip this project (no Harvest entries created).
#
# Examples — replace with your own projects:

# - harvest: "Example Client Portal"
#   gitlab: "example/client-portal"
#   log_aliases: [portal, clientportal]

# - harvest: "[INT] Internal"
#   internal: true
#   admin_task: "General"
#   log_aliases: [admin, internal]

# - harvest: "Open-source contributions"
#   excluded: true
#   log_aliases: [oss]

# ---------------------------------------------------------------------------
# ignore: drop captured events entirely before they ever reach Harvest.
#
# A top-level list of glob patterns matched (case-insensitively) against the
# captured event's "repo" and "repo/branch" — useful for throwaway sandboxes,
# test/demo repos, and scratch branches that the commit hook records but that
# are never billable. The timesheet skill's enrichment step silently discards
# any event whose repo (or repo/branch) matches a pattern here.
#
# This differs from `excluded:` above: `excluded` skips a *known Harvest
# project*; `ignore` drops *raw noise* that isn't a project at all.
#
# ignore:
#   - "*-localgit-*"      # disposable local git sandboxes
#   - "acr-localgit-*"
#   - "*/scratch-*"       # scratch branches on any repo
YAML
  echo "Created $PROJECTS_FILE"
else
  echo "Exists, skipped: $PROJECTS_FILE"
fi

LOCAL_FILE="$META_DIR/local-context.md"
if [[ ! -f "$LOCAL_FILE" ]]; then
  cat > "$LOCAL_FILE" <<'MD'
# Local Context

Per-machine settings for the `timesheet` and `value-estimates` plugins.

- **Daily reports path:** `~/daily_reports/` (override by exporting `DAILY_REPORTS_DIR`)
MD
  echo "Created $LOCAL_FILE"
else
  echo "Exists, skipped: $LOCAL_FILE"
fi

# Install the `worklog` quick-capture CLI onto PATH (symlink, so plugin updates
# are picked up automatically). Prefer ~/.local/bin, fall back to ~/bin.
WORKLOG_SRC="$PLUGIN_ROOT/bin/worklog"
if [[ -f "$WORKLOG_SRC" ]]; then
  chmod +x "$WORKLOG_SRC" 2>/dev/null || true
  for bindir in "$HOME/.local/bin" "$HOME/bin"; do
    if [[ -d "$bindir" ]]; then
      ln -sf "$WORKLOG_SRC" "$bindir/worklog"
      echo "Linked worklog → $bindir/worklog"
      WORKLOG_LINKED=1
      break
    fi
  done
  if [[ -z "${WORKLOG_LINKED:-}" ]]; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$WORKLOG_SRC" "$HOME/.local/bin/worklog"
    echo "Linked worklog → $HOME/.local/bin/worklog (ensure it is on your PATH)"
  fi
fi

cat <<'INFO'

Next steps:
  1. Edit ~/daily_reports/meta/projects.yml — add your Harvest projects and any
     `ignore:` globs for throwaway/test repos you don't want logged.
  2. Export HARVEST_ACCOUNT_ID and HARVEST_TOKEN in your shell environment
     (see skills/timesheet/example.zshenv for a template).
  3. Optional: export GITLAB_HOST + GITLAB_TOKEN if you use the value-estimates plugin.
  4. Quick-capture non-commit work anytime with:  worklog "what you did"
INFO
