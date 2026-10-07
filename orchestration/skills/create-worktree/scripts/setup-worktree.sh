#!/usr/bin/env bash
set -euo pipefail

# Generic worktree-creation engine (worktree-promotion-spec.md): the GLOBAL,
# project-agnostic half of a base/override pair. A project's own
# scripts/setup-worktree.sh is a thin shim that sets project configuration
# and delegates here via WORKTREE_ENGINE or the default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/create-worktree/scripts/
# setup-worktree.sh path. See this skill's SKILL.md for the two-layer model,
# and the comments beside run_provision/resolve_provision_hook below for the
# provisioning details. This engine only creates and provisions a worktree
# (plain `git worktree add`); it never starts an agent session.
#
#   setup-worktree.sh <id> [--no-db]            # mode 1: create + provision
#   setup-worktree.sh --provision [--no-db]     # mode 2: provision only (cwd = worktree)
#
# --no-db provisions everything except the database: no SHOW TABLES, no
# import, no drush deploy. It is passed on to a project's provision hook.

# --- Configuration ----------------------------------------------------------

# Branch new worktrees are cut from, resolved after the main checkout is
# known (see the BASE_BRANCH block below). Precedence: an explicit
# BASE_BRANCH in the environment, then BASE_BRANCH in the main checkout's
# .env. Neither resolving is a hard refusal -- no literal fallback.
BASE_BRANCH_ENV="${BASE_BRANCH-}"

# Database dump to import. Relative paths resolve against the main checkout.
# No default here -- a project that wants one (e.g. a fixed path like
# db/trunk.sql.gz) sets it in its own shim or its main checkout's .env.
# Precedence: environment, then the main checkout's .env, then skip the
# import with a message.
DB_DUMP_ENV="${DB_DUMP-}"

# Where worktrees live. Defaults to the MAIN CHECKOUT'S OWN BASENAME, not a
# hardcoded project name, so a checkout literally named "acme-site" still
# gets worktrees under .../worktrees/acme-site (protects live DDEV project
# names), while any other project gets its own directory automatically.
WORKTREE_ROOT_ENV="${WORKTREE_ROOT-}"

# --no-db may appear anywhere in the arguments; strip it so the positional
# contract (<id> | --provision) is unchanged.
NO_DB=0
_args=()
for _a in "$@"; do
  case "$_a" in
    --no-db) NO_DB=1 ;;
    *) _args+=("$_a") ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

# ----------------------------------------------------------------------------

# --- Shared DDEV project name rule (ticket #393, generalized by the
#     worktree-promotion-spec) --------------------------------------------
#
# Duplicated (not sourced) in retire-worktree.sh's copy -- both scripts'
# test harnesses copy a single file into a throwaway sandbox, so a shared lib
# file would not travel with them. The two copies must never drift; see
# tests/worktree-naming-parity.test.sh.
#
# ddev_project_name <branch-or-id> <main-checkout-basename> -> DDEV project
# name. Both the id and the main-checkout basename are sanitized the same
# way (lowercase, non-`a-z0-9-` to `-`, collapse runs, strip leading/trailing
# `-`, cap at 3 hyphen-separated segments -- except the id's leading segment,
# which keeps its WHOLE digit run uncapped when it is all-digit, so ticket
# numbers never truncate). <main-checkout-basename> is REQUIRED -- no
# "acme-site" default lives here; a generic engine defaulting to one
# project's name is exactly the hardcoding this split exists to remove
# (worktree-promotion-spec.md done-criterion 3). Every call site in this
# engine resolves and passes the real basename explicitly.
#
# LC_ALL=C is pinned on the tr/sed pass -- under a UTF-8 locale, tr/sed's
# character classes treat accented letters as already-lowercase "letters"
# and pass them through unsanitized, which DDEV then rejects as an invalid
# project name.
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

# --- Small .env reader (never sourced -- a single sed pass so an unrelated
#     line in .env cannot abort the run under `set -euo pipefail`). ---------
read_dotenv_var() { # read_dotenv_var <repo> <VAR> -> value or empty
  local repo="$1" var="$2"
  [ -f "$repo/.env" ] || return 0
  sed -n "s/^[[:space:]]*${var}[[:space:]]*=[[:space:]]*//p" "$repo/.env" |
    tail -n 1 |
    tr -d '\r' |
    sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

# --- Drupal detection + post-fresh-import `drush deploy` (shared by both
#     provisioning legs) ------------------------------------------------------
#
# is_drupal_ddev <dir> -> rc0 if <dir>/.ddev/config.yaml's `type:` value
# (quotes stripped) is `drupal` (DDEV's modern generic type) or `drupal`
# followed by a version number >= 8 (drupal8, drupal9, drupal10, drupal11,
# and any future drupalNN). Deliberately excludes drupal6/drupal7: their
# `drush` has no `deploy` command, so running it there would just fail.
# Deliberately reads config.yaml only, never config.local.yaml -- the latter
# is where THIS script writes the DDEV project `name:`, not a project's
# actual type. A missing config.yaml is "not Drupal", not an error -- a
# no-match grep must not abort under `set -euo pipefail`, hence `|| true`
# throughout and no reliance on grep's exit code.
is_drupal_ddev() { # is_drupal_ddev <dir> -> rc0/rc1
  local dir="$1" cfg="$1/.ddev/config.yaml" type_line version
  [ -f "$cfg" ] || return 1
  type_line="$(LC_ALL=C sed -n 's/^type:[[:space:]]*//p' "$cfg" | tail -n 1 || true)"
  type_line="$(printf '%s' "$type_line" | LC_ALL=C sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
  [ -n "$type_line" ] || return 1
  case "$type_line" in
    drupal) return 0 ;;
    drupal[0-9]*)
      version="${type_line#drupal}"
      [ "$version" -ge 8 ] 2>/dev/null && return 0 || return 1
      ;;
    *) return 1 ;;
  esac
}

# run_drush_deploy <dir> -- called only right after a FRESH `ddev import-db`
# (never on an already-populated DB / no dump / failed `ddev mysql`) on a
# Drupal site, so the checked-out code and the just-imported DB agree
# (updatedb + config:import + cache-rebuild + deploy hooks). A failure here
# is a warning, not a run failure -- provisioning still finishes and still
# exits 0, but the failure is named on stderr with the exact re-run command
# so it isn't silently swallowed.
run_drush_deploy() { # run_drush_deploy <dir>
  local dir="$1"
  if (cd "$dir" && ddev drush deploy); then
    echo "setup-worktree: ddev drush deploy completed."
  else
    echo "setup-worktree: \`ddev drush deploy\` failed after the fresh import-db; the checked-out code and the database may now disagree. Re-run \`ddev drush deploy\` once the failure is understood." >&2
  fi
}

# --- Mode 2: provision only --------------------------------------------------
#
# Run with cwd = an existing worktree (a project shim's provision hook, or a
# human re-running provisioning by hand). Gated the same way as mode 1's own
# provisioning (own_provision_mode1 below): core.hooksPath only when
# scripts/githooks exists, the DDEV leg only when the worktree has a `.ddev/`
# directory or a `composer.json`, and `ddev composer install` only when
# composer.json exists. Neither DDEV signal present is a plain worktree and
# a success. Mode 2 never calls the provision hook (recursion guard: a hook
# that delegates back here with --provision must not loop).
run_provision() {
  local worktree main_repo dump branch name existing_name

  worktree="$PWD"
  main_repo="${MAIN_REPO_OVERRIDE:-}"

  if [ -z "$main_repo" ]; then
    main_repo="$(dirname "$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)")"
  fi

  # Dump resolution: environment (DB_DUMP), then the main checkout's .env,
  # then none at all -- same precedence as mode 1's DB_DUMP, and NO
  # project-specific literal path here. A project that wants one sets
  # DB_DUMP itself (its shim exports it before delegating, in either mode).
  dump="${DB_DUMP-}"
  if [ -z "$dump" ]; then
    dump="$(read_dotenv_var "$main_repo" DB_DUMP)"
  fi
  if [ -n "$dump" ]; then
    case "$dump" in
      /*) : ;;
      *) dump="$main_repo/$dump" ;;
    esac
  fi

  cd "$worktree"

  # Wire the pre-push hook (ticket #380). Writes to the SHARED .git/config,
  # so it applies to the whole checkout family.
  if [ -d scripts/githooks ]; then
    git config core.hooksPath scripts/githooks
  fi

  if [ ! -d .ddev ] && [ ! -f composer.json ]; then
    echo "setup-worktree: $worktree ready (no .ddev/ or composer.json; DDEV skipped)."
    return 0
  fi

  branch="$(git -C "$worktree" symbolic-ref --quiet --short HEAD || true)"
  branch="${branch:-$(basename "$worktree")}"

  name="$(ddev_project_name "$branch" "$(basename "$main_repo")")"

  # Guard against re-provisioning a worktree already registered under a
  # different name (an earlier naming-rule change, or a changed $branch
  # fallback) -- warn-and-skip, not warn-and-rewrite, so a re-run never
  # strands the OLD DDEV project and its database.
  existing_name=""
  if [ -f .ddev/config.local.yaml ]; then
    existing_name="$(sed -n 's/^name:[[:space:]]*//p' .ddev/config.local.yaml | tail -n 1 | tr -d '\r')"
  fi

  if [ -n "$existing_name" ] && [ "$existing_name" != "$name" ]; then
    echo "setup-worktree: WARNING: $worktree already has a DDEV project named '$existing_name', but the current naming rule derives '$name' from branch '$branch'. NOT rewriting .ddev/config.local.yaml -- doing so would strand '$existing_name' and its database. Run \`ddev delete -Oy $existing_name\` first if you want to move this worktree to '$name', then re-run." >&2
    name="$existing_name"
  else
    mkdir -p .ddev
    printf 'name: %s\n' "$name" > .ddev/config.local.yaml
  fi

  # Name the mode in the failure. Without this the only output is ddev's own
  # "no .ddev/config.yaml file was found ..." on stderr, which reads like a
  # broken worktree rather than what it usually is: a composer.json-only
  # project with no committed DDEV config.
  if ! ddev start; then
    echo "setup-worktree: --provision could not start DDEV in $worktree. Check that the project has a .ddev/config.yaml." >&2
    return 1
  fi

  if [ -f composer.json ]; then
    ddev composer install
  fi

  if [ "$NO_DB" = "1" ]; then
    echo "setup-worktree: --no-db given, leaving the database alone."
    echo "setup-worktree: $name ready."
    return 0
  fi

  local show_tables_out show_tables_rc
  set +e
  show_tables_out="$(ddev mysql -Nse 'SHOW TABLES' 2>&1)"
  show_tables_rc=$?
  set -e
  if [ "$show_tables_rc" -ne 0 ]; then
    echo "setup-worktree: could not query the database (\`ddev mysql\` exited $show_tables_rc), skipping import: $show_tables_out" >&2
    return 1
  elif [ -n "$show_tables_out" ]; then
    echo "setup-worktree: database already populated, skipping import."
  elif [ -f "$dump" ]; then
    ddev import-db --file="$dump"
    # $PWD, not $worktree: this function already `cd "$worktree"`d above.
    # $PWD is always absolute here.
    if is_drupal_ddev "$PWD"; then
      run_drush_deploy "$PWD"
    fi
  else
    echo "setup-worktree: no dump at ${dump:-<none>}, skipping import." >&2
  fi

  echo "setup-worktree: $name ready."
}

if [ "${1:-}" = "--provision" ]; then
  run_provision
  exit 0
fi

# --- Mode 1: full ------------------------------------------------------------

id="${1:-}"
if [ -z "$id" ]; then
  echo "usage: $(basename "$0") <id> | --provision" >&2
  exit 1
fi

if ! [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "setup-worktree: id must be lowercase letters, digits and hyphens: $id" >&2
  exit 1
fi

main_repo="$(git rev-parse --show-toplevel)"
main_basename="$(basename "$main_repo")"

WORKTREE_ROOT="${WORKTREE_ROOT_ENV:-$HOME/Projects/worktrees/$main_basename}"

# --- Resolve BASE_BRANCH: environment, then the main checkout's .env. No
#     other fallback -- deliberately NOT the branch checked out where this
#     script runs, even though that is resolvable. A caller often runs this
#     from inside a LINKED worktree already sitting on its own ticket branch
#     (e.g. running from a worktree, to spin up a second one), and
#     silently cutting a new worktree from whatever that branch happens to
#     be is never what was meant -- see AGENTS.md's "Base branch comes from
#     BASE_BRANCH ... every worktree branches off it" and both SKILL.mds. A
#     generic engine with no project config at all has no safe guess here
#     (unlike a checkout named after its project, whose old project-local
#     script had a specific base branch hardcoded directly behind it);
#     refusing and creating nothing beats guessing. ---
if [ -n "$BASE_BRANCH_ENV" ]; then
  BASE_BRANCH="$BASE_BRANCH_ENV"
else
  base_branch_dotenv="$(read_dotenv_var "$main_repo" BASE_BRANCH)"
  if [ -n "$base_branch_dotenv" ]; then
    BASE_BRANCH="$base_branch_dotenv"
    echo "setup-worktree: BASE_BRANCH=$BASE_BRANCH from $main_repo/.env."
  else
    echo "setup-worktree: BASE_BRANCH is not set in the environment or in $main_repo/.env; refusing to guess. Set BASE_BRANCH and try again." >&2
    exit 1
  fi
fi

# --- Resolve DB_DUMP (mode 1): environment, then the main checkout's .env,
#     then none at all -- no literal default in this engine. ----------------
if [ -n "$DB_DUMP_ENV" ]; then
  DUMP_MODE1="$DB_DUMP_ENV"
else
  DUMP_MODE1="$(read_dotenv_var "$main_repo" DB_DUMP)"
fi
if [ -n "$DUMP_MODE1" ]; then
  case "$DUMP_MODE1" in
    /*) : ;;
    *) DUMP_MODE1="$main_repo/$DUMP_MODE1" ;;
  esac
fi

worktree=""

# --- Mode 1's own (conditional) provisioning, used when no PROVISION_HOOK
#     resolves anywhere on disk. Every leg here is gated on what the new
#     worktree actually contains, per the spec's genericization table (mode
#     2 applies the same gates). ------------------------------------------
own_provision_mode1() {
  local wt="$1" main="$2" name

  if [ -d "$wt/scripts/githooks" ]; then
    git -C "$wt" config core.hooksPath scripts/githooks
  fi

  # Gated on EITHER signal, not `.ddev/` alone as the spec's prose reads
  # literally: a project whose worktree ships only `composer.json` (no
  # `.ddev/` committed -- the common case for a fresh worktree, since
  # `.ddev/config.local.yaml` is normally gitignored and only appears once
  # something has already provisioned it) still needs `ddev start` +
  # `ddev mysql`/import to run here, and that is what several pinned cases
  # (composer.json-only fixtures) exercise. `.ddev/` alone covers a project
  # that ships real DDEV config but no composer.json (AC8). Neither present
  # (AC6/AC7/AC9) is the one case that truly skips this whole leg.
  if [ -d "$wt/.ddev" ] || [ -f "$wt/composer.json" ]; then
    name="$(ddev_project_name "$id" "$(basename "$main")")"
    mkdir -p "$wt/.ddev"
    printf 'name: %s\n' "$name" > "$wt/.ddev/config.local.yaml"

    (
      cd "$wt" || exit 99
      ddev start

      if [ -f composer.json ]; then
        ddev composer install
      fi

      if [ "$NO_DB" = "1" ]; then
        echo "setup-worktree: --no-db given, leaving the database alone."
        exit 0
      fi

      show_tables_out=""
      show_tables_rc=0
      set +e
      show_tables_out="$(ddev mysql -Nse 'SHOW TABLES' 2>&1)"
      show_tables_rc=$?
      set -e
      if [ "$show_tables_rc" -ne 0 ]; then
        echo "setup-worktree: could not query the database (\`ddev mysql\` exited $show_tables_rc), skipping import: $show_tables_out" >&2
        echo "setup-worktree: once the database is reachable, re-run with --provision from inside the worktree." >&2
        exit 1
      elif [ -n "$show_tables_out" ]; then
        echo "setup-worktree: database already populated, skipping import."
      elif [ -n "${DUMP_MODE1:-}" ] && [ -f "${DUMP_MODE1:-/nonexistent}" ]; then
        ddev import-db --file="$DUMP_MODE1"
        # $PWD, not $wt: this subshell already `cd "$wt"`d above, and $wt
        # itself may be a RELATIVE path (a relative WORKTREE_ROOT), which
        # would otherwise be re-resolved against the now-current directory
        # (itself) instead of where it pointed when set. $PWD is always
        # absolute here.
        if is_drupal_ddev "$PWD"; then
          run_drush_deploy "$PWD"
        fi
      else
        echo "setup-worktree: no dump at ${DUMP_MODE1:-<none>}, skipping import." >&2
      fi
    )
  fi
}

# --- Provision hook resolution (mode 1 only; see the recursion note above
#     run_provision). -------------------------------------------------------
resolve_provision_hook() { # resolve_provision_hook <worktree> <main_repo> -> prints path, rc0 if found
  local wt="$1" main="$2" val
  # Every tier, including env/.env, requires the resolved path to actually
  # exist on disk before it's used -- the spec's own wording is "if none of
  # those exists on disk" (review round 1: this used to skip the check for
  # env/.env, so a STALE PROVISION_HOOK left over in .env from an earlier
  # setup hard-failed provisioning instead of falling through to the
  # engine's own mode-1 logic like the spec says it should).
  if [ -n "${PROVISION_HOOK-}" ] && [ -f "${PROVISION_HOOK-}" ]; then
    printf '%s' "$PROVISION_HOOK"
    return 0
  fi
  val="$(read_dotenv_var "$main" PROVISION_HOOK)"
  if [ -n "$val" ] && [ -f "$val" ]; then
    printf '%s' "$val"
    return 0
  fi
  if [ -f "$wt/scripts/setup-worktree.sh" ]; then
    printf '%s' "$wt/scripts/setup-worktree.sh"
    return 0
  fi
  return 1
}

provision_after_create() { # provision_after_create <worktree> <main_repo>
  local wt="$1" main="$2" hook
  if hook="$(resolve_provision_hook "$wt" "$main")"; then
    if [ "$NO_DB" = "1" ]; then
      ( cd "$wt" && "$hook" --provision --no-db )
    else
      ( cd "$wt" && "$hook" --provision )
    fi
  else
    own_provision_mode1 "$wt" "$main" || exit 1
  fi
}

# --- git worktree add ------------------------------------------------------
git_worktree_add() {
  git -C "$main_repo" fetch --quiet origin "$BASE_BRANCH" 2>/dev/null || true
  # Refresh origin/<id> too, so a branch pushed from elsewhere is seen.
  git -C "$main_repo" fetch --quiet origin "+refs/heads/$id:refs/remotes/origin/$id" 2>/dev/null || true
  if git -C "$main_repo" show-ref --quiet --verify "refs/heads/$id"; then
    echo "setup-worktree: branch $id exists, checking it out."
    git -C "$main_repo" worktree add "$worktree" "$id"
  elif git -C "$main_repo" show-ref --quiet --verify "refs/remotes/origin/$id"; then
    # An existing branch that only lives on origin: check it out tracking
    # origin rather than cutting a new $id from the base, which would give
    # the caller the wrong code under the right name.
    echo "setup-worktree: branch $id exists on origin, checking it out."
    git -C "$main_repo" worktree add --track -b "$id" "$worktree" "origin/$id"
  else
    echo "setup-worktree: cutting $id from $BASE_BRANCH."
    # A base that exists only as origin/<base>: git 2.54 DWIMs a bare <base>
    # into a new local <base> branch and drops `-b "$id"`, leaving the
    # worktree on the base branch itself. Name the remote-tracking ref so
    # `-b` holds, and --no-track so the ticket branch doesn't pull the base.
    local start="$BASE_BRANCH"
    if ! git -C "$main_repo" show-ref --quiet --verify "refs/heads/$BASE_BRANCH" &&
      git -C "$main_repo" show-ref --quiet --verify "refs/remotes/origin/$BASE_BRANCH"; then
      start="origin/$BASE_BRANCH"
    fi
    git -C "$main_repo" worktree add --no-track -b "$id" "$worktree" "$start"
  fi

  local got
  got="$(git -C "$worktree" symbolic-ref --quiet --short HEAD || true)"
  if [ "$got" != "$id" ]; then
    echo "setup-worktree: $worktree is on branch '${got:-<detached>}', not '$id'. Remove it with retire-worktree and try again." >&2
    exit 1
  fi

  # Record the commit the worktree starts at, in its private git dir, so
  # cleanup can tell "merged" from "never worked on": both have an empty
  # origin/<base>..HEAD log, and an existing branch (a long-lived
  # sal-develop) may already have merged MRs at this very commit.
  git -C "$worktree" rev-parse HEAD > "$(git -C "$worktree" rev-parse --absolute-git-dir)/worktree-start-sha"
}

precreate_check() {
  if [ -e "$worktree" ]; then
    echo "setup-worktree: $worktree already exists, pick another id." >&2
    exit 1
  fi
  mkdir -p "$WORKTREE_ROOT"
}

worktree="$WORKTREE_ROOT/$id"
precreate_check
git_worktree_add
provision_after_create "$worktree" "$main_repo"

echo "setup-worktree: $id ready at $worktree."
