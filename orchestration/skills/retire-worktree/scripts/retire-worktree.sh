#!/usr/bin/env bash
set -uo pipefail

# Generic worktree-teardown engine (worktree-promotion-spec.md). This is the
# GLOBAL, project-agnostic half of a base/override pair -- see this skill's
# SKILL.md and create-worktree/SKILL.md for the two-layer model. A project
# with no shim at all still works: WORKTREE_ROOT defaults to the main
# checkout's own basename, and RETIRE_HOOK is entirely optional.
#
# Retire a finished worktree: close its Herdr workspace, delete its DDEV
# project (or hand that to a project's RETIRE_HOOK, if one resolves), remove
# the worktree, and delete its local branch. The Herdr close is the engine's
# own best-effort step and always runs (outside --ddev-only), hook or not, so
# a manual retire never leaves a Herdr tab pointing at a deleted folder.
# `orch` closes a ticket's Herdr workspace itself before calling this engine;
# the engine then finds no workspace and says so, which is harmless.
#
# Usage: retire-worktree.sh <id> [--force] [--ddev-only]
#
# <id> is the worktree directory name. Run it from anywhere inside the main
# checkout. Flags may appear in any order after <id>.
#
# --force skips the uncommitted-work check (step 2) and lets git discard it
# anyway.
#
# --ddev-only skips the Herdr step (step 3) entirely -- it never calls
# herdr -- runs steps 1, 2 and 4 (worktree lookup, retire-hook resolution,
# the uncommitted-work check, then the DDEV delete or the retire hook) and
# stops with exit 0, leaving the worktree checkout and its branch in place
# for the caller's platform to remove (e.g. `orca worktree rm`). Combinable
# with --force; without it a dirty worktree still refuses with exit 2.
#
# Every step below is destructive and none of it is recoverable outside git's
# own reflog, so the order matters.
#
# This script deliberately does NOT check whether the branch has landed
# anywhere -- direct invocation trusts the caller on merge state. The one
# real gate for "has this branch landed" is reap-worktrees.sh's
# branch_has_landed.
#
# The optional project retire hook (PROVISION_HOOK's counterpart on the
# teardown side): RETIRE_HOOK in the environment, then RETIRE_HOOK in the
# main checkout's .env, then the conventional
# <worktree>/scripts/retire-worktree.sh. When one resolves, it runs with cwd
# set to the still-existing worktree, BEFORE the worktree is removed, and
# REPLACES this engine's own DDEV-delete step (step 4) only. The Herdr
# close (step 3) runs before it from the engine itself either way, and the
# git-level teardown (step 5: `git worktree remove` plus the branch delete)
# always runs from the engine itself, since only it has the main checkout's
# context once the worktree directory is gone. A project with no retire hook
# anywhere is not required to have one -- the engine's own step 4 runs.
#
# Self-workspace deferral: if the resolved Herdr workspace id equals
# $HERDR_WORKSPACE_ID (the agent is retiring the worktree it is running
# in), closing it in step 3 would kill the agent's own pane -- and this
# script with it -- before steps 4-6 ever run. In that case the close is
# deferred to the very last action in the script, after the step 6 report;
# steps 4 (ddev), 5 (git worktree remove + branch delete) and 6 run first.
# A different or unset $HERDR_WORKSPACE_ID closes in step 3 as before. The
# deferred close is best-effort, same as the undeferred one.
#
# Exit codes: 1 = usage/refusal (bad args, missing/escaping path), 2 = dirty
# worktree without --force, 3 = re-entered from its own retire hook (see
# below), 4 = the git worktree removal itself failed.
#
# Re-entry guard: the conventional <worktree>/scripts/retire-worktree.sh hook
# is frequently a thin delegate shim that execs straight back into this
# engine. When this engine invokes a resolved hook it exports
# RETIRE_WORKTREE_IN_HOOK=1 into the hook's environment; if this engine ever
# sees that variable already set, it knows it has been re-entered from its
# own hook rather than invoked directly, refuses immediately (exit 3), and
# touches nothing. The OUTER invocation captures the hook's exit code: 0
# means the hook genuinely handled step 4 (DDEV delete); any nonzero exit
# (including 3, from a delegate shim) means it did not, so the engine warns
# on stderr (naming the hook and its exit code) and falls through to run its
# own step 4, and the final report names the real DDEV project rather than
# "(handled by ...)".

if [ "${RETIRE_WORKTREE_IN_HOOK-}" = "1" ]; then
  echo "retire-worktree: re-entered from its own retire hook (the hook is a delegate shim back to this engine); refusing." >&2
  exit 3
fi

id="${1:-}"
force=0
ddev_only=0
shift || true
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    --ddev-only) ddev_only=1 ;;
  esac
done

if [ -z "$id" ]; then
  echo "usage: $(basename "$0") <id> [--force] [--ddev-only]" >&2
  exit 1
fi

if ! [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "retire-worktree: id must be lowercase letters, digits and hyphens: $id" >&2
  exit 1
fi

# --- Shared DDEV project name rule (ticket #393, generalized by the
#     worktree-promotion-spec) -- see setup-worktree.sh's copy of this
#     function for the full rule commentary. Must stay byte-identical to
#     that copy; see tests/worktree-naming-parity.test.sh. ------------------
ddev_project_name() {
  local raw="$1" main_basename="$2"

  _dpn_sanitize() { # <input> -> lowercased, sanitized, hyphen-collapsed
    local lower
    lower="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    printf '%s' "$lower" | LC_ALL=C sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-//; s/-$//'
  }

  local sanitized first id_part i
  sanitized="$(_dpn_sanitize "$raw")"
  local -a segs
  IFS='-' read -r -a segs <<< "$sanitized"
  first="${segs[0]:-}"
  if [[ "$first" =~ ^[0-9]+$ ]]; then
    id_part="$first"
  else
    id_part="${segs[0]:-}"
    for i in 1 2; do
      [ -n "${segs[$i]:-}" ] && id_part="$id_part-${segs[$i]}"
    done
    [ -z "$id_part" ] && id_part="worktree"
  fi

  local bsanitized basename_part j
  bsanitized="$(_dpn_sanitize "$main_basename")"
  local -a bsegs
  IFS='-' read -r -a bsegs <<< "$bsanitized"
  basename_part="${bsegs[0]:-}"
  for j in 1 2; do
    [ -n "${bsegs[$j]:-}" ] && basename_part="$basename_part-${bsegs[$j]}"
  done
  [ -z "$basename_part" ] && basename_part="worktree"

  printf '%s-%s' "$id_part" "$basename_part"
}

read_dotenv_var() { # read_dotenv_var <repo> <VAR> -> value or empty
  local repo="$1" var="$2"
  [ -f "$repo/.env" ] || return 0
  sed -n "s/^[[:space:]]*${var}[[:space:]]*=[[:space:]]*//p" "$repo/.env" |
    tail -n 1 |
    tr -d '\r' |
    sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

main_repo="$(git rev-parse --show-toplevel)"
main_basename="$(basename "$main_repo")"

# Locate the worktree by asking git: <id> must be the directory name of a
# linked worktree of THIS repo, wherever it lives on disk. The first entry
# in `git worktree list` is the main checkout and is never a candidate.
worktree=""
first=1
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      wt_path="${line#worktree }"
      if [ "$first" -eq 1 ]; then
        first=0
      elif [ "$(basename "$wt_path")" = "$id" ]; then
        worktree="$wt_path"
        break
      fi
      ;;
  esac
done < <(git -C "$main_repo" worktree list --porcelain 2>/dev/null)

if [ -z "$worktree" ]; then
  echo "retire-worktree: no worktree named '$id' in this repo (see git worktree list)." >&2
  exit 1
fi

if [ ! -e "$worktree" ]; then
  echo "retire-worktree: $worktree does not exist." >&2
  exit 1
fi

branch="$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""

# --- Resolve the optional project retire hook -------------------------------
#
# Resolved BEFORE the dirty check: the conventional
# <worktree>/scripts/retire-worktree.sh may itself be a freshly-added,
# not-yet-committed file (e.g. a worktree being retired right after adding
# the hook), and its own untracked presence must not be what makes the
# worktree look dirty and block retirement.
resolve_retire_hook() { # -> prints path, rc0 if found
  local val
  if [ -n "${RETIRE_HOOK-}" ]; then
    printf '%s' "$RETIRE_HOOK"
    return 0
  fi
  val="$(read_dotenv_var "$main_repo" RETIRE_HOOK)"
  if [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  if [ -f "$worktree/scripts/retire-worktree.sh" ]; then
    printf '%s' "$worktree/scripts/retire-worktree.sh"
    return 0
  fi
  return 1
}

retire_hook=""
retire_hook="$(resolve_retire_hook)" || retire_hook=""

# --- Step 2: uncommitted work -----------------------------------------------
if dirty="$(git -C "$worktree" status --porcelain --untracked-files=all 2>&1)"; then
  status_failed=0
else
  status_failed=$?
  echo "retire-worktree: git status failed in $worktree (exit $status_failed); treating as dirty for safety." >&2
  : "${dirty:=git status exited $status_failed with no output}"
fi

# The conventional hook, when it is the SOURCE of the resolved hook (not an
# env/.env override pointing outside the worktree), is engine plumbing, not
# work-in-progress -- its own untracked/modified status must not block
# retirement, the same way .ddev/config.local.yaml (gitignored) never does.
if [ -n "$retire_hook" ] && [ "$retire_hook" = "$worktree/scripts/retire-worktree.sh" ]; then
  dirty="$(printf '%s\n' "$dirty" | grep -vE '^.. scripts/retire-worktree\.sh$' || true)"
fi

if [ -n "$dirty" ] && [ "$force" -ne 1 ]; then
  echo "retire-worktree: $worktree has uncommitted work; refusing without --force:" >&2
  printf '%s\n' "$dirty" >&2
  exit 2
fi

echo "retire-worktree: retiring $id at $worktree."

# --- Step 3: close the Herdr workspace, BEFORE the DDEV step / retire hook
#     and BEFORE the worktree is removed. Always the engine's own job (a
#     retire hook does not replace it); skipped entirely under --ddev-only.
#     UNLESS the resolved workspace is the caller's own (workspace_id ==
#     $HERDR_WORKSPACE_ID, non-empty): closing it here would kill the
#     agent's own pane -- and this script with it -- before steps 4-6 ever
#     run. In that case defer_own_close is set and the actual close is
#     pushed to the very last action in the script, after step 6. ----------
workspace_id=""
defer_own_close=0
if [ "$ddev_only" -ne 1 ]; then
  if command -v herdr >/dev/null 2>&1; then
    wt_json="$(herdr worktree list 2>/dev/null)" || wt_json=""
    if [ -n "$wt_json" ]; then
      workspace_id="$(printf '%s' "$wt_json" | jq -r --arg p "$worktree" \
        '(.result.worktrees // [])[] | select(.path==$p) | .open_workspace_id' 2>/dev/null | sed -n '1p')"
    fi

    if [ -z "${workspace_id:-}" ]; then
      ws_json="$(herdr workspace list 2>/dev/null)" || ws_json=""
      if [ -n "$ws_json" ]; then
        workspace_id="$(printf '%s' "$ws_json" | jq -r --arg p "$worktree" \
          '(.result.workspaces // [])[] | select(.worktree.checkout_path==$p) | .workspace_id' 2>/dev/null | sed -n '1p')"
      fi
    fi

    if [ -n "${workspace_id:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ "$workspace_id" = "${HERDR_WORKSPACE_ID:-}" ]; then
      defer_own_close=1
      echo "retire-worktree: $workspace_id is the caller's own workspace; deferring its close until after teardown (defer)."
    elif [ -n "${workspace_id:-}" ]; then
      if herdr workspace close "$workspace_id" >/dev/null 2>&1; then
        echo "retire-worktree: herdr workspace $workspace_id closed."
      else
        echo "retire-worktree: failed to close herdr workspace $workspace_id; continuing." >&2
      fi
    else
      echo "retire-worktree: no herdr workspace found for $worktree."
    fi
  else
    echo "retire-worktree: herdr not on PATH, skipping workspace close."
  fi
fi

# --- Step 4: delete the DDEV project, from inside the still-existing
#     worktree. Factored into a function so it can run either as the
#     engine's default behaviour, or as the fallback when a resolved retire
#     hook did not actually handle it (nonzero exit, e.g. a delegate shim
#     ignored via the re-entry guard above). Sets ddev_project. --------------
run_own_teardown() {
  ddev_project=""
  if [ -f "$worktree/.ddev/config.local.yaml" ]; then
    ddev_project="$(
      sed -n 's/^name:[[:space:]]*//p' "$worktree/.ddev/config.local.yaml" |
        tail -n 1 |
        tr -d '\r' |
        sed -e "s/^['\"]//" -e "s/['\"]\$//"
    )"
  fi
  ddev_project="${ddev_project:-$(ddev_project_name "$id" "$main_basename")}"
  if command -v ddev >/dev/null 2>&1; then
    if [ -d "$worktree/.ddev" ]; then
      if ( cd "$worktree" && ddev delete -yO ) >/dev/null 2>&1; then
        echo "retire-worktree: DDEV project $ddev_project deleted."
      else
        echo "retire-worktree: failed to delete DDEV project $ddev_project; continuing." >&2
      fi
    else
      echo "retire-worktree: no .ddev directory in $worktree, skipping DDEV delete."
    fi
  else
    echo "retire-worktree: ddev not on PATH, skipping DDEV delete."
  fi
}

if [ -n "$retire_hook" ]; then
  echo "retire-worktree: delegating DDEV teardown to $retire_hook."
  ( cd "$worktree" && RETIRE_WORKTREE_IN_HOOK=1 "$retire_hook" )
  hook_rc=$?
  if [ "$hook_rc" -eq 0 ]; then
    ddev_project="(handled by $retire_hook)"
  else
    echo "retire-worktree: retire hook $retire_hook did not handle teardown (exit $hook_rc); running the engine's own DDEV step." >&2
    run_own_teardown
  fi
else
  run_own_teardown
fi

if [ "$ddev_only" -eq 1 ]; then
  echo "retire-worktree: --ddev-only: left the worktree and branch in place."
  echo "retire-worktree:   DDEV project: $ddev_project"
  echo "retire-worktree:   path: $worktree"
  exit 0
fi

# --- Step 5: remove the worktree and branch, from the main checkout --------
if ! git -C "$main_repo" worktree remove --force "$worktree"; then
  echo "retire-worktree: git worktree remove failed for $worktree; branch left untouched." >&2
  if [ "$defer_own_close" -eq 1 ]; then
    echo "retire-worktree: herdr workspace $workspace_id (the caller's own) was left open — its close was deferred until after teardown, which did not complete. Fix the removal failure above, then re-run retire-worktree.sh to finish the teardown and close it." >&2
  fi
  exit 4
fi

if [ -n "$branch" ] && git -C "$main_repo" show-ref --quiet --verify "refs/heads/$branch"; then
  git -C "$main_repo" branch -D "$branch"
  branch_report="$branch (deleted)"
elif [ -n "$branch" ]; then
  branch_report="$branch (no local branch to delete)"
else
  branch_report="none (detached worktree)"
fi

# --- Step 6: final report ----------------------------------------------------
echo "retire-worktree: done."
if [ "$defer_own_close" -eq 1 ]; then
  echo "retire-worktree:   workspace: $workspace_id (closed last: caller's own workspace)"
elif [ -n "$workspace_id" ]; then
  echo "retire-worktree:   workspace: $workspace_id"
else
  echo "retire-worktree:   workspace: none closed"
fi
echo "retire-worktree:   DDEV project: $ddev_project"
echo "retire-worktree:   path: $worktree"
echo "retire-worktree:   branch: $branch_report"

# --- Deferred step 3: close the caller's own Herdr workspace, now that
#     everything else (ddev delete, git worktree remove, branch delete, the
#     final report) has already run. Best-effort: a failure warns on
#     stderr but must not change this script's own exit code. ---------------
if [ "$defer_own_close" -eq 1 ]; then
  if ! herdr workspace close "$workspace_id" >/dev/null 2>&1; then
    echo "retire-worktree: failed to close herdr workspace $workspace_id (deferred close); continuing." >&2
  fi
fi
