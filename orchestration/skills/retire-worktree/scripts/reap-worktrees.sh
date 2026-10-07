#!/usr/bin/env bash
set -uo pipefail

# Generic worktree-reaping engine (worktree-promotion-spec.md). Reap
# worktrees whose branch has already landed on the base branch. See
# retire-worktree.sh (this same directory) and create-worktree/SKILL.md for
# the two-layer base/override model this belongs to.
#
# Usage: reap-worktrees.sh [--dry-run]
#
# Enumerates every worktree under WORKTREE_ROOT, decides whether each one's
# branch has landed on $REMOTE/$BASE_BRANCH, and hands anything that has
# landed to the sibling retire-worktree.sh (without --force, so a dirty
# worktree survives and is reported as skipped instead of being torn down).
#
# --dry-run prints what would be retired and exits, without calling
# retire-worktree.sh at all.
#
# Exit codes: 0 = ran to completion (some worktrees may have been skipped --
# unmerged, dirty, or otherwise not eligible -- that is routine, not an
# error); non-zero only for a hard error: 1 = fetch failed, or the expected
# base ref does not exist after it. Also non-zero if retire-worktree.sh, for
# anything it was asked to retire, exits with anything other than 0 (retired)
# or 2 (dirty, refused on purpose -- routine).

# --- Configuration ----------------------------------------------------------

BASE_BRANCH_ENV="${BASE_BRANCH-}"
REMOTE="${REMOTE:-origin}"

WORKTREE_ROOT_ENV="${WORKTREE_ROOT-}"

# -----------------------------------------------------------------------------

# --- Small .env reader (never sourced -- same shape as the copy in
#     retire-worktree.sh and create-worktree's setup-worktree.sh). ----------
read_dotenv_var() { # read_dotenv_var <repo> <VAR> -> value or empty
  local repo="$1" var="$2"
  [ -f "$repo/.env" ] || return 0
  sed -n "s/^[[:space:]]*${var}[[:space:]]*=[[:space:]]*//p" "$repo/.env" |
    tail -n 1 |
    tr -d '\r' |
    sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

dry_run=0
for a in "$@"; do
  [ "$a" = "--dry-run" ] && dry_run=1
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
retire_script="$script_dir/retire-worktree.sh"

main_repo="$(git rev-parse --show-toplevel)"
main_basename="$(basename "$main_repo")"

WORKTREE_ROOT="${WORKTREE_ROOT_ENV:-$HOME/Projects/worktrees/$main_basename}"

# --- Resolve BASE_BRANCH: environment, then the main checkout's .env. No
#     other fallback -- this was previously a bare project-specific base
#     branch literal, the one project-specific default this engine carried
#     (review round 1, must-fix 1). Worse than the create engine's old
#     checked-out-branch fallback: reap is the only engine that never read
#     .env at all, so a project based on any other base branch that also
#     happens to have a stale origin ref matching that literal would have
#     its unlanded worktrees reaped against the WRONG base, silently.
#     Refusing when neither resolves is the same
#     rule create-worktree/setup-worktree.sh uses for its own BASE_BRANCH. --
if [ -n "$BASE_BRANCH_ENV" ]; then
  BASE_BRANCH="$BASE_BRANCH_ENV"
else
  base_branch_dotenv="$(read_dotenv_var "$main_repo" BASE_BRANCH)"
  if [ -n "$base_branch_dotenv" ]; then
    BASE_BRANCH="$base_branch_dotenv"
    echo "reap-worktrees: BASE_BRANCH=$BASE_BRANCH from $main_repo/.env."
  else
    echo "reap-worktrees: BASE_BRANCH is not set in the environment or in $main_repo/.env; refusing to guess. Set BASE_BRANCH and try again." >&2
    exit 1
  fi
fi

# --- Step 1: fetch first, fail loudly --------------------------------------
if ! git -C "$main_repo" fetch --quiet "$REMOTE" "$BASE_BRANCH"; then
  echo "reap-worktrees: git fetch $REMOTE $BASE_BRANCH failed; refusing to reap anything." >&2
  exit 1
fi

base_ref="$REMOTE/$BASE_BRANCH"

if ! git -C "$main_repo" rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null 2>&1; then
  echo "reap-worktrees: $base_ref does not exist after fetching $REMOTE $BASE_BRANCH; refusing to reap anything." >&2
  exit 1
fi

# --- Step 3 helper: has <branch> landed on <base_ref>? ----------------------
branch_has_landed() {
  local branch="$1" base="$2"

  if git -C "$main_repo" merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
    return 0
  fi

  local cherry_out cherry_status
  cherry_out="$(git -C "$main_repo" cherry "$base" "$branch" 2>/dev/null)"
  cherry_status=$?
  if [ "$cherry_status" -eq 0 ] && ! printf '%s\n' "$cherry_out" | grep -q '^+'; then
    return 0
  fi

  local mb combined_diff combined_id
  mb="$(git -C "$main_repo" merge-base "$base" "$branch" 2>/dev/null)" || return 1
  combined_diff="$(git -C "$main_repo" diff --binary "$mb" "$branch" 2>/dev/null)"
  if [ -z "$combined_diff" ]; then
    return 0
  fi
  combined_id="$(printf '%s\n' "$combined_diff" | git -C "$main_repo" patch-id --stable 2>/dev/null | awk '{print $1}')"
  if [ -z "$combined_id" ]; then
    return 1
  fi

  local commit
  while read -r commit; do
    [ -z "$commit" ] && continue
    local commit_id
    commit_id="$(git -C "$main_repo" show --binary "$commit" 2>/dev/null | git -C "$main_repo" patch-id --stable 2>/dev/null | awk '{print $1}')"
    if [ -n "$commit_id" ] && [ "$commit_id" = "$combined_id" ]; then
      return 0
    fi
  done < <(git -C "$main_repo" log --format=%H "$mb..$base" 2>/dev/null)

  return 1
}

# --- Step 2: enumerate worktrees --------------------------------------------
wtroot_real="$(cd "$WORKTREE_ROOT" 2>/dev/null && pwd -P)" || wtroot_real=""

any_skipped=0
to_retire=()

wt_path=""
wt_branch=""
wt_detached=0

process_worktree() {
  local path="$1" branch="$2" detached="$3"

  [ -z "$path" ] && return

  if [ "$path" = "$main_repo" ]; then
    return
  fi

  if [ "$detached" -eq 1 ]; then
    echo "reap-worktrees: skipping $path (detached HEAD)."
    any_skipped=1
    return
  fi

  local path_real
  path_real="$(cd "$path" 2>/dev/null && pwd -P)" || path_real=""
  if [ -z "$wtroot_real" ]; then
    echo "reap-worktrees: skipping $path (WORKTREE_ROOT does not exist)."
    any_skipped=1
    return
  fi
  case "$path_real" in
    "$wtroot_real"/*) : ;;
    *)
      echo "reap-worktrees: skipping $path (outside WORKTREE_ROOT)."
      any_skipped=1
      return
      ;;
  esac

  if [ "$branch" = "$BASE_BRANCH" ]; then
    echo "reap-worktrees: skipping $path (this is the $BASE_BRANCH worktree)."
    any_skipped=1
    return
  fi

  local id
  id="$(basename "$path")"

  if branch_has_landed "$branch" "$base_ref"; then
    to_retire+=("$id")
  else
    echo "reap-worktrees: skipping $id (branch '$branch' has not landed on $base_ref)."
    any_skipped=1
  fi
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      if [ -n "$wt_path" ]; then
        process_worktree "$wt_path" "$wt_branch" "$wt_detached"
      fi
      wt_path="${line#worktree }"
      wt_branch=""
      wt_detached=0
      ;;
    "branch "*)
      wt_branch="${line#branch refs/heads/}"
      ;;
    "detached")
      wt_detached=1
      ;;
  esac
done < <(git -C "$main_repo" worktree list --porcelain)

if [ -n "$wt_path" ]; then
  process_worktree "$wt_path" "$wt_branch" "$wt_detached"
fi

# --- Steps 4-6: retire (or report) what landed ------------------------------

if [ "${#to_retire[@]}" -eq 0 ]; then
  echo "reap-worktrees: nothing to retire."
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  echo "reap-worktrees: --dry-run, would retire:"
  for id in "${to_retire[@]}"; do
    echo "reap-worktrees:   $id"
  done
  exit 0
fi

hard_error=0

for id in "${to_retire[@]}"; do
  echo "reap-worktrees: retiring $id."
  WORKTREE_ROOT="$WORKTREE_ROOT" "$retire_script" "$id"
  retire_status=$?
  case "$retire_status" in
    0)
      echo "reap-worktrees: retired $id."
      ;;
    2)
      echo "reap-worktrees: skipping $id (retire-worktree.sh refused: dirty worktree, uncommitted work)." >&2
      any_skipped=1
      ;;
    4)
      echo "reap-worktrees: HARD ERROR retiring $id (retire-worktree.sh could not remove the worktree)." >&2
      hard_error=1
      ;;
    *)
      echo "reap-worktrees: skipping $id (retire-worktree.sh exited $retire_status, unknown error)." >&2
      hard_error=1
      ;;
  esac
done

if [ "$hard_error" -eq 1 ]; then
  exit 1
fi

exit 0
