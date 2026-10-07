#!/usr/bin/env bash
#
# scripts/setup-worktree.sh -- create and provision a worktree.
#
# Spec under test:
#
#   setup-worktree.sh <id>          # mode 1: `git worktree add`, then provision
#   setup-worktree.sh --provision   # mode 2: provision the worktree at $PWD
#
# Harness: stub-driven and hermetic. No DDEV, no network, and no real
# worktree of THIS repo.
#
# Why a throwaway git repo + a COPY of the script, rather than running the real
# script with WORKTREE_ROOT pointed at a sandbox: the script does
# `git worktree add -b "$id"` against `git rev-parse --show-toplevel`, so
# running it in place would create real branches and real worktree
# registrations in the developer's checkout. A scratch repo makes every case
# disposable.
#
# `ddev` is stubbed on PATH. With DDEV_LOG set, the stub appends each
# invocation's argv to that log (one call per line, \x1f between args).
#
# Run from anywhere:
#   bash tests/setup-worktree-agent.test.sh
#
# Requires: bash, git. Exit 0 = green.

set -uo pipefail

# Derived from BASH_SOURCE, not `git rev-parse --show-toplevel` -- this suite
# must run from any cwd and must not require a git repo.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_REL="scripts/setup-worktree.sh"
SCRIPT="$SKILL_DIR/$SCRIPT_REL"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ihwt-XXXXXX")" || {
  echo "FATAL: mktemp failed to create a sandbox dir" >&2
  exit 1
}
# Resolve away macOS's /var -> /private/var symlink so string comparisons
# against paths the engine reports back agree with what this harness built.
# Bail loudly on a hollowed-out SANDBOX ("" or "/") rather than ever letting
# the EXIT trap's `rm -rf` act on the wrong directory.
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || {
  echo "FATAL: mktemp produced an unusable sandbox dir: '$SANDBOX'" >&2
  exit 1
}
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
case "$SANDBOX" in
  "" | / )
    echo "FATAL: sandbox path normalised to '$SANDBOX' -- refusing to continue" >&2
    exit 1
    ;;
esac

sandbox_looks_safe() {
  # Only ever delete a directory whose basename matches the mktemp template.
  [ -n "$SANDBOX" ] || return 1
  [ "$SANDBOX" != "/" ] || return 1
  [ -d "$SANDBOX" ] || return 1
  case "$(basename -- "$SANDBOX")" in
    ihwt-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) return 0 ;;
    *) return 1 ;;
  esac
}
trap 'sandbox_looks_safe && rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
note() { printf 'note %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  shift
  local line
  while IFS= read -r line; do printf '       %s\n' "$line"; done <<< "${*:-}"
}

if [ ! -f "$SCRIPT" ]; then
  echo "FATAL: $SCRIPT_REL not found under $SKILL_DIR" >&2
  exit 1
fi

# Env vars a developer's own shell might export that would change what the
# engine does. Scrubbed (`env -u`) from every case before its own settings.
SCRUB=(-u PROVISION_HOOK -u MAIN_REPO_OVERRIDE -u WORKTREE_ROOT -u BASE_BRANCH -u DB_DUMP)

# ---------------------------------------------------------------------------
# Stub PATH. ddev is a no-op; `ddev mysql -Nse 'SHOW TABLES'` prints nothing so
# the script takes the import branch (and then skips it: DB_DUMP points at a
# path that does not exist).
# ---------------------------------------------------------------------------
STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/ddev" <<'STUB'
#!/usr/bin/env bash
# Record argv when DDEV_LOG is set (cases care about the exact sequence of
# ddev calls).
if [ -n "${DDEV_LOG:-}" ]; then
  {
    __sep=''
    for a in "$@"; do
      printf '%s%s' "$__sep" "$a"
      __sep=$'\x1f'
    done
    printf '\n'
  } >> "$DDEV_LOG"
fi
case "${1:-} ${2:-}" in
  "mysql -Nse")
    # DDEV_MYSQL_EXIT lets a case simulate `ddev mysql` itself failing
    # (unreachable DB, container down, etc.) -- distinct from a query that
    # succeeds but returns no rows. A failing query prints nothing on stdout
    # either way, matching real `ddev mysql`'s behaviour on a hard failure.
    if [ -n "${DDEV_MYSQL_EXIT:-}" ] && [ "${DDEV_MYSQL_EXIT:-0}" != "0" ]; then
      printf '%s' "${DDEV_MYSQL_STDERR:-ddev mysql: could not connect to db}" >&2
      exit "$DDEV_MYSQL_EXIT"
    fi
    # DDEV_SHOW_TABLES unset/empty -> prints nothing -> empty database.
    printf '%s' "${DDEV_SHOW_TABLES:-}"
    exit 0
    ;;
  "drush deploy")
    # DDEV_DRUSH_DEPLOY_EXIT lets a case simulate `ddev drush deploy` itself
    # failing (a stale dump failing an update hook, etc.) -- independent of
    # DDEV_EXIT, which would also break `ddev start`/`ddev composer install`
    # earlier in the same run and confound these cases.
    if [ -n "${DDEV_DRUSH_DEPLOY_EXIT:-}" ] && [ "${DDEV_DRUSH_DEPLOY_EXIT:-0}" != "0" ]; then
      printf '%s' "${DDEV_DRUSH_DEPLOY_STDERR:-ddev drush deploy: update failed}" >&2
      exit "$DDEV_DRUSH_DEPLOY_EXIT"
    fi
    exit 0
    ;;
esac
exit "${DDEV_EXIT:-0}"
STUB

chmod +x "$STUB_BIN/ddev"

# ---------------------------------------------------------------------------
# One disposable git repo + script copy per case.
# ---------------------------------------------------------------------------
CASE_N=0
RC=0
OUT=""
ERR=""
CASE_DIR=""

run_case() {
  # run_case <name> [ENV=VAL ...] -- [script args ...]
  local name="$1"; shift  # label only, never part of a path
  local envs=() args=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  args=("$@")

  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/case$CASE_N"  # neutral name: it lands in stdout paths
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  git -C "$dir/acme-site" add README.md composer.json >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t \
    commit -q -m init >/dev/null 2>&1 || return 1
  cp "$SCRIPT" "$dir/acme-site/setup-worktree.sh" || return 1
  # Optional per-case .env. Unset means the repo has no .env at all, which is
  # its own branch of the resolution.
  [ -n "${CASE_DOTENV-}" ] && printf '%s\n' "$CASE_DOTENV" > "$dir/acme-site/.env"
  printf "%s\n" "$name" > "$dir/CASE"

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"
  ERR="$dir/stderr"

  # Every case gets a non-existent-dump DB_DUMP by default, so an unrelated
  # case never accidentally triggers a real import. A case that needs DB_DUMP
  # genuinely UNSET (to reach the main-checkout .env fallback -- see AC3)
  # sets CASE_UNSET_DB_DUMP=1.
  local db_dump_default=(DB_DUMP="$dir/no-such-dump.sql.gz")
  if [ "${CASE_UNSET_DB_DUMP-0}" = "1" ]; then
    db_dump_default=()
  fi

  (
    cd "$dir/acme-site" || exit 99
    env "${SCRUB[@]}" \
        PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$DDEV_LOG_FILE" \
        WORKTREE_ROOT="$dir/worktrees" \
        ${db_dump_default[@]+"${db_dump_default[@]}"} \
        BASE_BRANCH=trunk \
        ${envs[@]+"${envs[@]}"} \
        bash ./setup-worktree.sh ${args[@]+"${args[@]}"}
  ) > "$OUT" 2> "$ERR"
  RC=$?
  return 0
}

# ---------------------------------------------------------------------------
# run_provision_case: builds a main repo PLUS a worktree already checked out
# on a branch, copies the script into that worktree, and runs it with cwd =
# the worktree -- exactly the contract mode 2 (--provision) is specified
# against. PROV_WT_COUNT_BEFORE/AFTER let a case assert the script did not
# add a worktree itself.
#
# Positional pseudo-envs (consumed here, never passed to the script):
#   PROV_BRANCH=<b>   branch the worktree is checked out on (default 393)
#   PROV_GITHOOKS=1   create scripts/githooks/ in the worktree first
#   PROV_PLAIN=1      remove composer.json from the worktree (no DDEV signal)
# ---------------------------------------------------------------------------
run_provision_case() {
  # run_provision_case <name> [ENV=VAL ...] -- [script args ...]
  local name="$1"; shift
  local envs=() args=()
  local branch="393" githooks=0 plain=0
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      PROV_BRANCH=*) branch="${1#PROV_BRANCH=}" ;;
      PROV_GITHOOKS=*) githooks="${1#PROV_GITHOOKS=}" ;;
      PROV_PLAIN=*) plain="${1#PROV_PLAIN=}" ;;
      *) envs+=("$1") ;;
    esac
    shift
  done
  [ "${1:-}" = "--" ] && shift
  args=("$@")

  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/pcase$CASE_N"
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  git -C "$dir/acme-site" add README.md composer.json >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t \
    commit -q -m init >/dev/null 2>&1 || return 1

  local wt="$dir/wt"
  git -C "$dir/acme-site" worktree add -q -b "$branch" "$wt" trunk >/dev/null 2>&1 || return 1
  cp "$SCRIPT" "$wt/setup-worktree.sh" || return 1
  [ "$githooks" = "1" ] && mkdir -p "$wt/scripts/githooks"
  [ "$plain" = "1" ] && rm -f "$wt/composer.json"
  printf "%s\n" "$name" > "$dir/CASE"

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"
  ERR="$dir/stderr"
  PROV_WT="$wt"
  PROV_MAIN="$dir/acme-site"
  PROV_WT_COUNT_BEFORE="$(git -C "$dir/acme-site" worktree list | wc -l)"

  local db_dump_default=(DB_DUMP="$dir/no-such-dump.sql.gz")
  if [ "${CASE_UNSET_DB_DUMP-0}" = "1" ]; then
    db_dump_default=()
  fi

  (
    cd "$wt" || exit 99
    env "${SCRUB[@]}" \
        PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$DDEV_LOG_FILE" \
        ${db_dump_default[@]+"${db_dump_default[@]}"} \
        ${envs[@]+"${envs[@]}"} \
        bash ./setup-worktree.sh ${args[@]+"${args[@]}"}
  ) > "$OUT" 2> "$ERR"
  RC=$?
  PROV_WT_COUNT_AFTER="$(git -C "$dir/acme-site" worktree list | wc -l)"
  return 0
}

# --- assertions -------------------------------------------------------------
expect_rc0() { # expect_rc0 <label>
  if [ "$RC" -eq 0 ]; then
    pass "$1"
  else
    fail "$1" "exit status $RC
stderr: $(head -5 "$ERR")"
  fi
}

expect_script_warns() { # expect_script_warns <label> <extended regex>
  # The warning must come from the script itself (its own `setup-worktree:`
  # prefix), so stray tool noise on stderr cannot satisfy it.
  if grep -qiE "setup-worktree:.*($2)" "$ERR"; then
    pass "$1"
  else
    fail "$1" "no 'setup-worktree: ...' line on stderr matching /$2/:
$(cat "$ERR")"
  fi
}

expect_stdout_lacks() { # expect_stdout_lacks <label> <needle>
  if grep -qF -- "$2" "$OUT"; then
    fail "$1" "stdout leaked '$2':
$(cat "$OUT")"
  else
    pass "$1"
  fi
}

expect_stdout_has() { # expect_stdout_has <label> <needle>  (case-insensitive)
  if grep -qiF -- "$2" "$OUT"; then
    pass "$1"
  else
    fail "$1" "stdout did not mention '$2':
$(cat "$OUT")"
  fi
}

# ===========================================================================
# --- N. BASE_BRANCH resolution ---------------------------------------------
#
# The main checkout's .env is the project's declared base branch and the single
# source the create-worktree skill reads. The script must agree with the skill,
# or a worktree cut from a linked worktree inherits that worktree's ticket
# branch instead of the base -- which is what used to happen.
#
# Precedence: explicit BASE_BRANCH in the environment, then .env. No other
# fallback -- in particular NOT the branch checked out where the script runs
# (review round 1, must-fix 4): a caller often runs this from inside a linked
# worktree already sitting on its own ticket branch, and silently cutting a
# new worktree from whatever that happens to be is never what was meant.
# run_case always passes BASE_BRANCH=trunk, so the .env cases blank it; an
# explicitly empty value defers to .env.

cut_from() { sed -n 's/^setup-worktree: cutting [^ ]* from \(.*\)\.$/\1/p' "$OUT" | head -1; }

check_base() { # check_base <name> <expected-branch>
  local got; got="$(cut_from)"
  if [ "$got" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "expected to cut from '$2', cut from '$got'"
  fi
}

CASE_DOTENV='BASE_BRANCH=from-dotenv' run_case "N1" BASE_BRANCH= -- j1
check_base "N1: .env supplies BASE_BRANCH when the environment does not" "from-dotenv"

CASE_DOTENV='BASE_BRANCH=from-dotenv' run_case "N2" BASE_BRANCH=from-env -- j2
check_base "N2: an explicit BASE_BRANCH beats .env" "from-env"

CASE_DOTENV="BASE_BRANCH='quoted-branch'" run_case "N3" BASE_BRANCH= -- j3
check_base "N3: quotes around the .env value are stripped" "quoted-branch"

CASE_DOTENV='FOO=bar
BASE_BRANCH=real-branch
BAZ=qux' run_case "N4" BASE_BRANCH= -- j4
check_base "N4: other .env keys are ignored" "real-branch"

# No fallback left once BASE_BRANCH is unresolvable in the environment or
# .env, even though the sandbox's main repo IS a normal (non-detached)
# checkout on "trunk" here -- that checked-out branch must NOT be consulted
# any more (must-fix 4). AC5 separately pins the detached-HEAD case; these
# two pin the more common "no .env at all" / "empty .env value" cases,
# which used to silently succeed via the now-removed fallback.
check_refuses() { # check_refuses <name> <case-dir>
  if [ "$RC" -ne 0 ]; then
    pass "$1a: refuses with a non-zero exit"
  else
    fail "$1a: must refuse (non-zero exit), not fall back to the checked-out branch" "exit $RC"
  fi
  if [ ! -d "$2/worktrees" ] || [ -z "$(ls -A "$2/worktrees" 2>/dev/null)" ]; then
    pass "$1b: creates nothing"
  else
    fail "$1b: must create nothing" "$(ls "$2/worktrees" 2>/dev/null)"
  fi
}

run_case "N5" BASE_BRANCH= -- j5
check_refuses "N5" "$CASE_DIR"

CASE_DOTENV='BASE_BRANCH=' run_case "N6" BASE_BRANCH= -- j6
check_refuses "N6" "$CASE_DIR"

# The .env is read, never sourced: sourcing it would also import DB_DUMP and
# friends, and under `set -euo pipefail` an unrelated line could abort the run.
CASE_DOTENV='BASE_BRANCH=safe-branch
DB_DUMP=/nope/should-not-be-inherited.sql.gz' run_case "N7" BASE_BRANCH= -- j7
check_base "N7: .env is parsed, not sourced (BASE_BRANCH still resolves)" "safe-branch"
if grep -q 'should-not-be-inherited' "$OUT" "$ERR" 2>/dev/null; then
  fail "N8: .env must not be sourced" "DB_DUMP from .env leaked into the run."
else
  pass "N8: other .env settings are not inherited"
fi

CASE_DOTENV='BASE_BRANCH=announced' run_case "N9" BASE_BRANCH= -- j9
if grep -q 'BASE_BRANCH=announced from' "$OUT"; then
  pass "N9: the run says when BASE_BRANCH came from .env"
else
  fail "N9: reading .env must be announced" "stdout: $(cat "$OUT")"
fi

# A base branch that exists only on origin (no local branch yet). Given
# `git worktree add -b <id> <path> <base>`, git 2.54 DWIMs <base> into a new
# local branch and drops `-b <id>`, so the worktree landed on the base branch
# itself (ticket 206). The worktree must be on <id>, cut from origin's base,
# and must not track it.
CASE_N=$((CASE_N + 1))
n10_dir="$SANDBOX/case$CASE_N"
mkdir -p "$n10_dir"
if git init -q -b trunk "$n10_dir/origin" >/dev/null 2>&1 &&
  git -C "$n10_dir/origin" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m init >/dev/null 2>&1 &&
  git -C "$n10_dir/origin" branch develop >/dev/null 2>&1 &&
  git -C "$n10_dir/origin" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m trunk-only >/dev/null 2>&1 &&
  git clone -q "$n10_dir/origin" "$n10_dir/acme-site" >/dev/null 2>&1; then
  cp "$SCRIPT" "$n10_dir/acme-site/setup-worktree.sh"
  (
    cd "$n10_dir/acme-site" || exit 99
    env "${SCRUB[@]}" PATH="$STUB_BIN:$PATH" WORKTREE_ROOT="$n10_dir/worktrees" \
      BASE_BRANCH=develop bash ./setup-worktree.sh 206
  ) > "$n10_dir/stdout" 2> "$n10_dir/stderr"
  n10_rc=$?
  n10_wt="$n10_dir/worktrees/206"
  n10_branch="$(git -C "$n10_wt" symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [ "$n10_rc" -eq 0 ] && [ "$n10_branch" = "206" ]; then
    pass "N10a: a remote-only base branch still gives a worktree on branch <id>"
  else
    fail "N10a: a remote-only base branch still gives a worktree on branch <id>" \
      "exit $n10_rc, branch '$n10_branch'
$(cat "$n10_dir/stdout" "$n10_dir/stderr")"
  fi
  if [ "$(git -C "$n10_wt" rev-parse HEAD 2>/dev/null)" = "$(git -C "$n10_dir/origin" rev-parse develop)" ]; then
    pass "N10b: the worktree is cut from origin's base branch"
  else
    fail "N10b: the worktree is cut from origin's base branch" "HEAD differs from origin/develop"
  fi
  if git -C "$n10_dir/acme-site" show-ref --quiet --verify refs/heads/develop; then
    fail "N10c: no stray local base branch is created" "refs/heads/develop exists"
  else
    pass "N10c: no stray local base branch is created"
  fi
  if [ -z "$(git -C "$n10_dir/acme-site" config --get branch.206.merge)" ]; then
    pass "N10d: the new branch does not track the base branch"
  else
    fail "N10d: the new branch does not track the base branch" \
      "branch.206.merge=$(git -C "$n10_dir/acme-site" config --get branch.206.merge)"
  fi
else
  fail "N10: could not build the sandbox case" "git setup failed"
fi

# ===========================================================================
# O. The DDEV project name rule, shared by both modes and by retire-worktree.sh.
#
#   Sanitize the branch/id (lowercase, non-`a-z0-9-` to `-`, collapse runs,
#   strip leading/trailing `-`); if the leading segment is all digits, the
#   WHOLE digit run is the name part (no width cap); otherwise cap at the
#   first 3 hyphen-separated segments. Append `-<main-checkout-basename>`.
#   The <id> itself is used VERBATIM for the worktree dir and branch.
# ===========================================================================

# --- shared naming reference (the spec's rule, restated in bash) -----------
derive_ddev_name() { # derive_ddev_name <branch-or-id> -> expected DDEV name
  local raw="$1" lower sanitized first capped i
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  sanitized="$(printf '%s' "$lower" | sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-//; s/-$//')"
  local -a segs
  IFS='-' read -r -a segs <<< "$sanitized"
  first="${segs[0]:-}"
  if [[ "$first" =~ ^[0-9]+$ ]]; then
    printf '%s-acme-site' "$first"
    return
  fi
  capped="${segs[0]:-}"
  for i in 1 2; do
    [ -n "${segs[$i]:-}" ] && capped="$capped-${segs[$i]}"
  done
  printf '%s-acme-site' "$capped"
}

read_ddev_name() { # read_ddev_name <path/to/.ddev/config.local.yaml>
  sed -n 's/^name:[[:space:]]*//p' "$1" 2>/dev/null | head -1
}

# Harness self-check: the worked examples from the ticket, restated as a
# check on the reference helper itself, so a bug in derive_ddev_name can
# never masquerade as the script under test being correct.
naming_examples_ok=1
check_reference() { # check_reference <input> <expected>
  local got; got="$(derive_ddev_name "$1")"
  if [ "$got" != "$2" ]; then
    naming_examples_ok=0
    fail "O0[$1]: derive_ddev_name reference helper itself is wrong" "expected $2, got $got"
  fi
}
check_reference "393" "393-acme-site"
check_reference "289-numbered-steps-style" "289-acme-site"
check_reference "382-trunk-layout-backfill-skips-inline-blocks" "382-acme-site"
check_reference "386" "386-acme-site"
check_reference "field-toggles" "field-toggles-acme-site"
check_reference "wait-times-mobile-ordering-fix" "wait-times-mobile-acme-site"
check_reference "1000" "1000-acme-site"
check_reference "1024-shared-naming" "1024-acme-site"
check_reference "10000" "10000-acme-site"
[ "$naming_examples_ok" -eq 1 ] && pass "O0: derive_ddev_name reference helper matches every worked example in the ticket"

# ===========================================================================
# P. Mode 2 (--provision): provisions in place, creates no worktree/branch.
# ===========================================================================
if run_provision_case provision-basic PROV_BRANCH=393 -- --provision; then
  expect_rc0 "P0: --provision exits 0"

  if [ "$PROV_WT_COUNT_BEFORE" = "$PROV_WT_COUNT_AFTER" ]; then
    pass "P1: --provision does not add another git worktree (worktree count unchanged)"
  else
    fail "P1: --provision must not call \`git worktree add\`" \
"worktree count before: $PROV_WT_COUNT_BEFORE
worktree count after:  $PROV_WT_COUNT_AFTER"
  fi

  got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  if [ "$got_name" = "393-acme-site" ]; then
    pass "P4: --provision writes .ddev/config.local.yaml with the derived DDEV name"
  else
    fail "P4: wrong (or missing) DDEV name" \
"expected: 393-acme-site
got:      ${got_name:-<file missing>}"
  fi

  if grep -qF $'start\x1f' "$DDEV_LOG_FILE" 2>/dev/null || grep -qFx 'start' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "P5: --provision runs \`ddev start\`"
  else
    fail "P5: \`ddev start\` was not recorded" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  fi

  if grep -qE '^composer' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "P6: --provision runs \`ddev composer install\`"
  else
    fail "P6: \`ddev composer install\` was not recorded" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  fi

  if git -C "$PROV_WT" config --get core.hooksPath >/dev/null 2>&1; then
    fail "P7: --provision must not set core.hooksPath when there is no scripts/githooks" \
      "got: '$(git -C "$PROV_WT" config --get core.hooksPath)'"
  else
    pass "P7: --provision leaves core.hooksPath unset when there is no scripts/githooks"
  fi
else
  fail "P0-P7: could not build the provision-mode sandbox case" "git init/worktree/copy failed"
fi

if run_provision_case provision-githooks PROV_BRANCH=394 PROV_GITHOOKS=1 -- --provision; then
  expect_rc0 "P7a: --provision with scripts/githooks exits 0"
  hooks_path="$(git -C "$PROV_WT" config --get core.hooksPath 2>/dev/null)"
  if [ "$hooks_path" = "scripts/githooks" ]; then
    pass "P7b: --provision sets core.hooksPath to scripts/githooks when that directory exists"
  else
    fail "P7b: core.hooksPath was not set to scripts/githooks" "got: '${hooks_path:-<unset>}'"
  fi
else
  fail "P7a-b: could not build the provision-mode sandbox case" "git init/worktree/copy failed"
fi

# P7c-f: mode 2 gates its DDEV leg like mode 1 -- a worktree with neither
# .ddev/ nor composer.json is a plain worktree and a success.
if run_provision_case provision-plain PROV_BRANCH=395 PROV_PLAIN=1 -- --provision; then
  expect_rc0 "P7c: --provision on a worktree with no .ddev/ and no composer.json exits 0"
  if [ ! -s "$DDEV_LOG_FILE" ]; then
    pass "P7d: --provision skips the DDEV leg entirely -- no \`ddev\` call at all"
  else
    fail "P7d: the DDEV leg must not run without .ddev/ or composer.json" "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
  if [ ! -e "$PROV_WT/.ddev" ]; then
    pass "P7e: --provision writes no .ddev/ into a plain worktree"
  else
    fail "P7e: a plain worktree must not get a .ddev/ directory" "$(ls -A "$PROV_WT/.ddev")"
  fi
  if grep -qiE 'warn' "$ERR" 2>/dev/null; then
    fail "P7f: a plain worktree must not warn" "$(cat "$ERR")"
  else
    pass "P7f: a plain worktree produces no warning"
  fi
else
  fail "P7c-f: could not build the provision-mode sandbox case" "git init/worktree/copy failed"
fi

# ===========================================================================
# P8-P9: import only into an EMPTY database, in provision mode. Needs a real
# (fake-content) dump file, which run_provision_case can't place until the
# sandbox dir exists, so build the fixture by hand here.
# ===========================================================================
build_provision_with_dump() { # build_provision_with_dump <name> <branch> <show-tables-value> [<mysql-exit-code>]
  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/pdcase$CASE_N"
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site/db"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  git -C "$dir/acme-site" add README.md composer.json >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || return 1
  printf 'not a real dump, just needs to exist\n' > "$dir/acme-site/db/trunk.sql.gz"

  local wt="$dir/wt"
  git -C "$dir/acme-site" worktree add -q -b "$2" "$wt" trunk >/dev/null 2>&1 || return 1
  cp "$SCRIPT" "$wt/setup-worktree.sh" || return 1

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"; ERR="$dir/stderr"
  PROV_WT="$wt"; PROV_MAIN="$dir/acme-site"

  (
    cd "$wt" || exit 99
    # DB_DUMP is set explicitly here, mirroring what acme-site's real
    # shim always exports before delegating -- the engine itself carries no
    # project-specific dump filename (must-fix 2, worktree-promotion-spec
    # review round 1).
    env "${SCRUB[@]}" PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$DDEV_LOG_FILE" \
        DDEV_SHOW_TABLES="$3" \
        DDEV_MYSQL_EXIT="${4:-}" \
        DB_DUMP="db/trunk.sql.gz" \
        bash ./setup-worktree.sh --provision
  ) > "$OUT" 2> "$ERR"
  RC=$?
  return 0
}

if build_provision_with_dump provision-empty-db-imports 396 ""; then
  expect_rc0 "P9: an empty database with a real dump present exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "P10: an empty database DOES import the dump"
  else
    fail "P10: an empty database should have run \`ddev import-db\`" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  fi
else
  fail "P9-P10: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_provision_with_dump provision-populated-db-skips 397 $'existing_table\n'; then
  expect_rc0 "P11: an already-populated database with a dump present still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "P11: a populated database must NOT import the dump" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  else
    pass "P11: a populated database skips \`ddev import-db\` (retries stay safe)"
  fi
else
  fail "P11: could not build the sandbox case" "git init/worktree/copy failed"
fi

# ===========================================================================
# P17-P18: must-fix round 2 -- a worktree whose .ddev/config.local.yaml
# already names a DDEV project must not be silently rewritten under a
# different derived name. Live casualty this guards against: 0387-acme-site
# (approot .../387-delivery-type-styling, branch 387-delivery-type-styling),
# stranded because an earlier run wrote the OLD naming rule's name and a
# later provision run overwrote it with the new rule's name, orphaning the
# original project and its database. Builds the sandbox by hand (like
# build_provision_with_dump above) so a .ddev/config.local.yaml can be
# planted BEFORE the script under test ever runs.
# ===========================================================================
build_provision_with_existing_ddev_name() { # <case-name> <branch> <existing-name-or-empty>
  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/pecase$CASE_N"
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  git -C "$dir/acme-site" add README.md composer.json >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || return 1

  local wt="$dir/wt"
  git -C "$dir/acme-site" worktree add -q -b "$2" "$wt" trunk >/dev/null 2>&1 || return 1
  cp "$SCRIPT" "$wt/setup-worktree.sh" || return 1

  if [ -n "$3" ]; then
    mkdir -p "$wt/.ddev"
    printf 'name: %s\n' "$3" > "$wt/.ddev/config.local.yaml"
  fi

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"; ERR="$dir/stderr"
  PROV_WT="$wt"; PROV_MAIN="$dir/acme-site"

  (
    cd "$wt" || exit 99
    env "${SCRUB[@]}" \
        PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$DDEV_LOG_FILE" \
        DB_DUMP="$dir/no-such-dump.sql.gz" \
        bash ./setup-worktree.sh --provision
  ) > "$OUT" 2> "$ERR"
  RC=$?
  return 0
}

# P17: no pre-existing config.local.yaml -- ordinary first-time provision,
# must still write the derived name (same as P4, restated here so P18's
# "unchanged" comparison sits next to a matching-name baseline).
if build_provision_with_existing_ddev_name p17-no-existing 399 ""; then
  expect_rc0 "P17a: provision with no pre-existing config.local.yaml exits 0"
  got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  if [ "$got_name" = "399-acme-site" ]; then
    pass "P17b: provision writes the derived name when no config.local.yaml existed yet"
  else
    fail "P17b: wrong (or missing) DDEV name" "expected: 399-acme-site
got:      ${got_name:-<file missing>}"
  fi
else
  fail "P17: could not build the sandbox case" "git init/worktree/copy failed"
fi

# P18a-c: the SAME derived name is already on disk -- rewriting is a no-op,
# so it is fine either way; must still exit 0 and keep that name.
if build_provision_with_existing_ddev_name p18-matching 399 "399-acme-site"; then
  expect_rc0 "P18a: provision with a MATCHING pre-existing name exits 0"
  got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  if [ "$got_name" = "399-acme-site" ]; then
    pass "P18b: provision keeps the DDEV name when the existing name already matches the derived one"
  else
    fail "P18b: wrong (or missing) DDEV name" "expected: 399-acme-site
got:      ${got_name:-<file missing>}"
  fi
  if grep -qi 'WARNING' "$ERR" 2>/dev/null; then
    fail "P18c: a matching existing name must not warn" "stderr: $(cat "$ERR" 2>/dev/null)"
  else
    pass "P18c: a matching existing name does not warn"
  fi
else
  fail "P18a-c: could not build the sandbox case" "git init/worktree/copy failed"
fi

# P19a-d: a DIFFERENT pre-existing name is on disk (the 0387-acme-site
# scenario) -- must warn loudly (naming BOTH names), refuse to rewrite the
# file (warn-and-skip, not warn-and-rewrite: rewriting here and then calling
# \`ddev start\` below would strand the OLD project in this very run), and
# still exit 0 (a stale name is not itself fatal to the day's work).
if build_provision_with_existing_ddev_name p19-differing 387-delivery-type-styling "0387-acme-site"; then
  expect_rc0 "P19a: provision with a DIFFERING pre-existing name still exits 0"
  got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  if [ "$got_name" = "0387-acme-site" ]; then
    pass "P19b: provision does NOT rewrite config.local.yaml when the existing name differs from the derived one (warn-and-skip)"
  else
    fail "P19b: a differing existing name must be left alone, not overwritten" "expected: 0387-acme-site (unchanged)
got:      ${got_name:-<file missing>}"
  fi
  if grep -qi 'WARNING' "$ERR" 2>/dev/null && grep -qF '0387-acme-site' "$ERR" 2>/dev/null && grep -qF '387-acme-site' "$ERR" 2>/dev/null; then
    pass "P19c: stderr warns loudly, naming both the existing (0387-acme-site) and derived (387-acme-site) names"
  else
    fail "P19c: stderr must warn and name BOTH the existing and derived DDEV project names" "stderr: $(cat "$ERR" 2>/dev/null)"
  fi
  if grep -qF "$PROV_WT" "$ERR" 2>/dev/null; then
    pass "P19d: stderr warning names the approot so an operator knows which worktree to act on"
  else
    fail "P19d: stderr warning must name the approot ($PROV_WT)" "stderr: $(cat "$ERR" 2>/dev/null)"
  fi
else
  fail "P19a-d: could not build the sandbox case" "git init/worktree/copy failed"
fi

# ===========================================================================
# Q. Identifier A -- the shared DDEV-naming rule, worked examples from the
#    ticket, exercised through BOTH modes.
# ===========================================================================

# --- Q1: full mode -----------------------------------------------------
# id is used VERBATIM for the worktree dir and branch (Identifier B); only
# the DDEV project name is derived/capped (Identifier A).
while IFS='|' read -r q_id q_ddev; do
  [ -z "$q_id" ] && continue
  if run_case "naming-full-$q_id" -- "$q_id"; then
    expect_rc0 "Q1[$q_id]: full mode with id '$q_id' exits 0"
    if [ -d "$CASE_DIR/worktrees/$q_id" ]; then
      pass "Q1[$q_id]: the worktree directory keeps the id VERBATIM ($q_id, not capped)"
    else
      fail "Q1[$q_id]: expected worktree dir $CASE_DIR/worktrees/$q_id to exist" \
"$(ls "$CASE_DIR/worktrees" 2>/dev/null)"
    fi
    branch_name="$(git -C "$CASE_DIR/worktrees/$q_id" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    if [ "$branch_name" = "$q_id" ]; then
      pass "Q1[$q_id]: the branch also keeps the id VERBATIM"
    else
      fail "Q1[$q_id]: branch should be '$q_id'" "got: '$branch_name'"
    fi
    got_name="$(read_ddev_name "$CASE_DIR/worktrees/$q_id/.ddev/config.local.yaml")"
    if [ "$got_name" = "$q_ddev" ]; then
      pass "Q1[$q_id]: DDEV project name is derived/capped to '$q_ddev', not the raw id"
    else
      fail "Q1[$q_id]: wrong DDEV project name" "expected: $q_ddev
got:      ${got_name:-<file missing>}"
    fi
  else
    fail "Q1[$q_id]: could not build the sandbox case" "git init/commit/copy failed"
  fi
done <<'CASES'
393|393-acme-site
289-numbered-steps-style|289-acme-site
382-trunk-layout-backfill-skips-inline-blocks|382-acme-site
386|386-acme-site
field-toggles|field-toggles-acme-site
wait-times-mobile-ordering-fix|wait-times-mobile-acme-site
CASES

# --- Q2: wide ticket numbers must not be truncated the way the old
#     project-local setup script's 4-char rule did (10000 -> 1000 was a silently
#     wrong DDEV project pointing at a different ticket's database).
while IFS='|' read -r q_id q_ddev; do
  [ -z "$q_id" ] && continue
  if run_case "naming-wide-$q_id" -- "$q_id"; then
    got_name="$(read_ddev_name "$CASE_DIR/worktrees/$q_id/.ddev/config.local.yaml")"
    if [ "$got_name" = "$q_ddev" ]; then
      pass "Q2[$q_id]: a ticket number past 999 is NOT truncated to 4 chars ($q_ddev)"
    else
      fail "Q2[$q_id]: ticket numbers past 999 must not be truncated (regression: an older setup script took the first 4 chars, turning 10000 into 1000)" \
"expected: $q_ddev
got:      ${got_name:-<file missing>}"
    fi
  else
    fail "Q2[$q_id]: could not build the sandbox case" "git init/commit/copy failed"
  fi
done <<'CASES'
1000|1000-acme-site
1024-shared-naming|1024-acme-site
10000|10000-acme-site
CASES

# --- Q3: provision mode, the same worked examples, derived from the
#     worktree's checked-out branch instead of an <id> argument.
while IFS='|' read -r q_branch q_ddev; do
  [ -z "$q_branch" ] && continue
  if run_provision_case "naming-provision-$q_branch" "PROV_BRANCH=$q_branch" -- --provision; then
    got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
    if [ "$got_name" = "$q_ddev" ]; then
      pass "Q3[$q_branch]: provision mode derives the same DDEV name from the branch ($q_ddev)"
    else
      fail "Q3[$q_branch]: wrong DDEV name in provision mode" "expected: $q_ddev
got:      ${got_name:-<file missing>}"
    fi
  else
    fail "Q3[$q_branch]: could not build the provision sandbox case" "git init/worktree/copy failed"
  fi
done <<'CASES'
393|393-acme-site
289-numbered-steps-style|289-acme-site
382-trunk-layout-backfill-skips-inline-blocks|382-acme-site
10000|10000-acme-site
field-toggles|field-toggles-acme-site
CASES

# --- Q4: both modes agree for the SAME worktree. NOT itself the
#     0386-acme-site regression guard -- both calls below go through this
#     one file's ddev_project_name, so they can never disagree with each
#     other. retire-worktree.test.sh's R23/R24 pin scripts/retire-worktree.sh's
#     OWN copy of the rule (independently, against its own script), but that
#     is not a cross-script guard either: mutating one script's copy of
#     ddev_project_name leaves the other script's suite green. The
#     cross-script guard is tests/repo/worktree-naming-parity.test.sh, which
#     runs both copies over one shared input list (#394). This section
#     instead pins
#     that this file's two entry points (mode 1's <id> and mode 2's
#     checked-out branch) feed the SAME shared function, so a future change
#     that reads the derivation input differently in one mode than the other
#     shows up red here.
for q_id in 393 382-trunk-layout-backfill-skips-inline-blocks field-toggles; do
  full_name=""
  prov_name=""
  if run_case "agree-full-$q_id" -- "$q_id"; then
    full_name="$(read_ddev_name "$CASE_DIR/worktrees/$q_id/.ddev/config.local.yaml")"
  fi
  if run_provision_case "agree-provision-$q_id" "PROV_BRANCH=$q_id" -- --provision; then
    prov_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  fi
  if [ -n "$full_name" ] && [ "$full_name" = "$prov_name" ]; then
    pass "Q4[$q_id]: full mode and provision mode derive the IDENTICAL DDEV name ($full_name)"
  else
    fail "Q4[$q_id]: the two modes must never disagree on the DDEV name (this is the 0386-acme-site orphan bug)" \
"full mode:       '$full_name'
provision mode:  '$prov_name'"
  fi
done

# ===========================================================================
# Q5-Q6: the sanitizer must not depend on locale, and must never emit a bare
# "-acme-site" (ticket #393 round 2). Only reachable through provision
# mode's uncontrolled input (a checked-out branch name, or the worktree
# directory's basename for a detached worktree) -- mode 1's
# <id> is already regex-validated before it ever reaches ddev_project_name.
# ===========================================================================

# --- Q5: an accented branch name must sanitize the same way regardless of
#     the caller's locale. Under the default en_US.UTF-8 locale on this
#     machine, tr/sed's character classes treat 'é' as an already-lowercase
#     letter and pass it through -- LC_ALL=C must be pinned inside the
#     function itself so the result does not depend on what locale happened
#     to be exported when the hook ran.
if run_provision_case naming-locale "PROV_BRANCH=café-382" "LC_ALL=en_US.UTF-8" -- --provision; then
  expect_rc0 "Q5a: provision with an accented branch name under a UTF-8 locale exits 0"
  got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  if [ "$got_name" = "caf-382-acme-site" ]; then
    pass "Q5b: an accented branch (café-382) sanitizes to caf-382-acme-site even under a UTF-8 locale"
  else
    fail "Q5b: the sanitizer must pin LC_ALL=C, not inherit the caller's locale" \
"expected: caf-382-acme-site
got:      ${got_name:-<file missing>}"
  fi
else
  fail "Q5: could not build the sandbox case" "git init/worktree/copy failed"
fi

# --- Q6: an all-punctuation fallback input (the worktree directory's
#     basename, reached only when the worktree's HEAD is detached, so
#     symbolic-ref fails) must never sanitize down to nothing and print a
#     bare "-acme-site". composer.json is committed so mode 2's gated DDEV
#     leg (and so the naming/write step) actually runs.
build_provision_detached() { # <case-name> <worktree-dir-basename>
  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/qdcase$CASE_N"
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  git -C "$dir/acme-site" add README.md composer.json >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || return 1
  local sha; sha="$(git -C "$dir/acme-site" rev-parse HEAD)"

  local wt="$dir/$2"
  git -C "$dir/acme-site" worktree add -q --detach "$wt" "$sha" >/dev/null 2>&1 || return 1
  cp "$SCRIPT" "$wt/setup-worktree.sh" || return 1

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"; ERR="$dir/stderr"
  PROV_WT="$wt"; PROV_MAIN="$dir/acme-site"

  (
    cd "$wt" || exit 99
    env "${SCRUB[@]}" \
        PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$DDEV_LOG_FILE" \
        DB_DUMP="$dir/no-such-dump.sql.gz" \
        bash ./setup-worktree.sh --provision
  ) > "$OUT" 2> "$ERR"
  RC=$?
  return 0
}

if build_provision_detached naming-fallback '!!!'; then
  expect_rc0 "Q6a: provision on a detached worktree with an all-punctuation directory name exits 0"
  got_name="$(read_ddev_name "$PROV_WT/.ddev/config.local.yaml")"
  if [ -n "$got_name" ] && [ "$got_name" != "-acme-site" ]; then
    pass "Q6b: an all-punctuation fallback name never sanitizes to a bare '-acme-site' (got: $got_name)"
  else
    fail "Q6b: an all-punctuation fallback name must fall back to a non-empty segment, not a bare '-acme-site'" \
"got: ${got_name:-<file missing>}"
  fi
else
  fail "Q6: could not build the detached-worktree sandbox case" "git init/worktree/copy failed"
fi

# ===========================================================================
# X. Ticket #394 (item C): `if ddev mysql -Nse 'SHOW TABLES' | grep -q .`
#    (both call sites -- provision mode and full mode) reads
#    a FAILING `ddev mysql` (unreachable DB, container down) the same as an
#    EMPTY one: `grep -q .` is false either way, so the script concludes
#    "empty" and imports over it. Required behaviour: a failing `ddev mysql`
#    is an ERROR -- report it on stderr and exit non-zero WITHOUT importing.
#    An empty (but successfully queried) database still imports; an already
#    populated one still skips the import and prints the existing message.
# ===========================================================================

if build_provision_with_dump db-check-fails-provision 402 "" 1; then
  if [ "$RC" -ne 0 ]; then
    pass "X1: provision mode: a failing \`ddev mysql\` exits non-zero (never silently treated as 'empty')"
  else
    fail "X1: provision mode: a failing \`ddev mysql\` must not exit 0" "stdout: $(cat "$OUT")
stderr: $(cat "$ERR")"
  fi
  if grep -qiE 'setup-worktree:.*(could not (query|check|reach)|failed to (query|check)|database).*' "$ERR"; then
    pass "X2: provision mode: the failure is reported on stderr as a query/check failure, not read as 'empty'"
  else
    fail "X2: provision mode: stderr does not name the \`ddev mysql\` failure" "stderr: $(cat "$ERR")"
  fi
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "X3: provision mode: a failing \`ddev mysql\` must NOT be followed by \`ddev import-db\`" \
      "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  else
    pass "X3: provision mode: \`ddev import-db\` never runs after a failing \`ddev mysql\`"
  fi
else
  fail "X1-X3: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_provision_with_dump db-check-empty-provision 403 ""; then
  expect_rc0 "X4: provision mode: a successful, empty \`ddev mysql\` still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "X5: provision mode: a successful empty query DOES import the dump"
  else
    fail "X5: provision mode: an empty database should have run \`ddev import-db\`" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  fi
else
  fail "X4-X5: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_provision_with_dump db-check-populated-provision 404 $'existing_table\n'; then
  expect_rc0 "X6: provision mode: a populated database still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "X7: provision mode: a populated database must NOT import the dump" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  else
    pass "X7: provision mode: a populated database skips \`ddev import-db\`"
  fi
  expect_stdout_has "X8: provision mode: the existing 'already populated' message still prints" "already populated"
else
  fail "X6-X8: could not build the sandbox case" "git init/worktree/copy failed"
fi

# --- X9-X16: the SAME three scenarios, but through Mode 1 (full: <id>, the
#     script's own `git worktree add`), covering the SECOND call site
#     (own_provision_mode1). DB_DUMP is a real (fake-content) file inside the scratch
#     main repo so the "no dump" branch is never what decides these cases.
build_full_with_dump() { # build_full_with_dump <name> <id> <show-tables-value> [<mysql-exit-code>]
  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/fdcase$CASE_N"
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site/db"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  git -C "$dir/acme-site" add README.md composer.json >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1 || return 1
  printf 'not a real dump, just needs to exist\n' > "$dir/acme-site/db/trunk.sql.gz"
  cp "$SCRIPT" "$dir/acme-site/setup-worktree.sh" || return 1

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"; ERR="$dir/stderr"
  FULL_WT="$dir/worktrees/$2"

  (
    cd "$dir/acme-site" || exit 99
    env "${SCRUB[@]}" \
        PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$DDEV_LOG_FILE" \
        DDEV_SHOW_TABLES="$3" \
        DDEV_MYSQL_EXIT="${4:-}" \
        WORKTREE_ROOT="$dir/worktrees" \
        DB_DUMP="db/trunk.sql.gz" \
        BASE_BRANCH=trunk \
        bash ./setup-worktree.sh "$2"
  ) > "$OUT" 2> "$ERR"
  RC=$?
  return 0
}

if build_full_with_dump db-check-fails-full wt-x1 "" 1; then
  if [ "$RC" -ne 0 ]; then
    pass "X9: full mode: a failing \`ddev mysql\` exits non-zero (never silently treated as 'empty')"
  else
    fail "X9: full mode: a failing \`ddev mysql\` must not exit 0" "stdout: $(cat "$OUT")
stderr: $(cat "$ERR")"
  fi
  if grep -qiE 'setup-worktree:.*(could not (query|check|reach)|failed to (query|check)|database).*' "$ERR"; then
    pass "X10: full mode: the failure is reported on stderr as a query/check failure, not read as 'empty'"
  else
    fail "X10: full mode: stderr does not name the \`ddev mysql\` failure" "stderr: $(cat "$ERR")"
  fi
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "X11: full mode: a failing \`ddev mysql\` must NOT be followed by \`ddev import-db\`" \
      "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  else
    pass "X11: full mode: \`ddev import-db\` never runs after a failing \`ddev mysql\`"
  fi
else
  fail "X9-X11: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_full_with_dump db-check-empty-full wt-x2 ""; then
  expect_rc0 "X12: full mode: a successful, empty \`ddev mysql\` still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "X13: full mode: a successful empty query DOES import the dump"
  else
    fail "X13: full mode: an empty database should have run \`ddev import-db\`" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  fi
else
  fail "X12-X13: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_full_with_dump db-check-populated-full wt-x3 $'existing_table\n'; then
  expect_rc0 "X14: full mode: a populated database still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "X15: full mode: a populated database must NOT import the dump" "$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  else
    pass "X15: full mode: a populated database skips \`ddev import-db\`"
  fi
  expect_stdout_has "X16: full mode: the existing 'already populated' message still prints" "already populated"
else
  fail "X14-X16: could not build the sandbox case" "git init/worktree/copy failed"
fi

# ===========================================================================
# C. Mode 1 creates the checkout with `git worktree add`, then provisions it.
# ===========================================================================
if run_case c-create DDEV_SHOW_TABLES="" -- c1; then
  expect_rc0 "C1: mode 1 exits 0"
  if [ -d "$CASE_DIR/worktrees/c1" ] && git -C "$CASE_DIR/worktrees/c1" rev-parse HEAD >/dev/null 2>&1; then
    pass "C2: mode 1 creates the checkout with \`git worktree add\`"
  else
    fail "C2: mode 1 must create the checkout itself" "no worktree at $CASE_DIR/worktrees/c1"
  fi
  if grep -qE '^start' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "C3: mode 1 provisions DDEV after the checkout exists"
  else
    fail "C3: mode 1 must run the provision hook (or its own provisioning) after the checkout exists" "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
  expect_stdout_has "C4: mode 1 prints the ready line naming the worktree" "c1 ready at $CASE_DIR/worktrees/c1"
else
  fail "C: could not build the sandbox case" "git init failed"
fi

if run_case c-usage -- ; then
  if [ "$RC" -ne 0 ] && grep -q 'usage:' "$ERR"; then
    pass "C5: no <id> and no --provision prints usage and exits non-zero"
  else
    fail "C5: a bare invocation must print usage and exit non-zero" "exit $RC; stderr: $(cat "$ERR")"
  fi
  if [ ! -e "$CASE_DIR/worktrees" ]; then
    pass "C6: a bare invocation creates nothing"
  else
    fail "C6: a bare invocation must create nothing" "$(ls -A "$CASE_DIR/worktrees")"
  fi
else
  fail "C5-C6: could not build the sandbox case" "git init failed"
fi

# ===========================================================================
# AB. Provision hook resolution (worktree-promotion-spec.md):
#     PROVISION_HOOK env, then PROVISION_HOOK in the main checkout's .env,
#     then the conventional <worktree>/scripts/setup-worktree.sh, then the
#     engine's OWN --provision mode when none of those exists on disk.
#     Recursion guard: the engine's own --provision mode must NEVER call the
#     hook (only the three create legs do), or a hook that shells back into
#     the engine's --provision mode would recurse forever.
# ===========================================================================

# --- AB1: PROVISION_HOOK in the environment wins over everything. ----------
hook_dir="$SANDBOX/case$((CASE_N + 1))"
mkdir -p "$hook_dir"
HOOK_LOG_AB1="$hook_dir/hook.log"; : > "$HOOK_LOG_AB1"
cat > "$hook_dir/hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'ran:%s:%s\n' "$PWD" "$*" >> "$HOOK_LOG_TARGET"
HOOK
chmod +x "$hook_dir/hook.sh"

if run_case ab1-provision-hook-env DDEV_SHOW_TABLES="" \
     "PROVISION_HOOK=$hook_dir/hook.sh" "HOOK_LOG_TARGET=$HOOK_LOG_AB1" -- ab1; then
  if grep -qF -- "--provision" "$HOOK_LOG_AB1" 2>/dev/null; then
    pass "AB1a: PROVISION_HOOK (env) is invoked with --provision"
  else
    fail "AB1a: PROVISION_HOOK (env) must be invoked with --provision" "$(cat "$HOOK_LOG_AB1" 2>/dev/null)"
  fi
  if grep -qF "ran:$CASE_DIR/worktrees/ab1:" "$HOOK_LOG_AB1" 2>/dev/null; then
    pass "AB1b: PROVISION_HOOK runs with cwd set to the new worktree"
  else
    fail "AB1b: PROVISION_HOOK must run with cwd = the new worktree" "$(cat "$HOOK_LOG_AB1" 2>/dev/null)"
  fi
  if [ ! -s "$DDEV_LOG_FILE" ]; then
    pass "AB1c: with an external PROVISION_HOOK, the engine does not ALSO run its own DDEV provisioning"
  else
    fail "AB1c: the engine must delegate provisioning to PROVISION_HOOK, not also run its own" "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
else
  fail "AB1: could not build the sandbox case" "git init failed"
fi

# --- AB2: PROVISION_HOOK in the main checkout's .env, when not set in the
#     environment. ------------------------------------------------------------
hook_dir2="$SANDBOX/case$((CASE_N + 1))"
mkdir -p "$hook_dir2"
HOOK_LOG_AB2="$hook_dir2/hook.log"; : > "$HOOK_LOG_AB2"
cat > "$hook_dir2/hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'ran:%s:%s\n' "$PWD" "$*" >> "$HOOK_LOG_TARGET"
HOOK
chmod +x "$hook_dir2/hook.sh"

CASE_DOTENV="PROVISION_HOOK=$hook_dir2/hook.sh"
if run_case ab2-provision-hook-dotenv DDEV_SHOW_TABLES="" \
     "HOOK_LOG_TARGET=$HOOK_LOG_AB2" -- ab2; then
  if grep -qF "ran:$CASE_DIR/worktrees/ab2:--provision" "$HOOK_LOG_AB2" 2>/dev/null; then
    pass "AB2: PROVISION_HOOK from the main checkout's .env is used when unset in the environment"
  else
    fail "AB2: PROVISION_HOOK from .env must be resolved and invoked" "$(cat "$HOOK_LOG_AB2" 2>/dev/null)"
  fi
else
  fail "AB2: could not build the sandbox case" "git init failed"
fi
unset CASE_DOTENV

# --- AB3: the conventional <worktree>/scripts/setup-worktree.sh, committed
#     into the branch content itself, when neither env nor .env set
#     PROVISION_HOOK. -------------------------------------------------------
ab3_dir="$SANDBOX/ab3"
mkdir -p "$ab3_dir/repo/scripts"
git init -q -b trunk "$ab3_dir/repo" >/dev/null 2>&1
printf 'seed\n' > "$ab3_dir/repo/README.md"
cat > "$ab3_dir/repo/scripts/setup-worktree.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'ran:%s:%s\n' "$PWD" "$*" >> "$HOOK_LOG_TARGET"
HOOK
chmod +x "$ab3_dir/repo/scripts/setup-worktree.sh"
git -C "$ab3_dir/repo" add README.md scripts/setup-worktree.sh >/dev/null 2>&1
git -C "$ab3_dir/repo" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
cp "$SCRIPT" "$ab3_dir/repo/setup-worktree-engine.sh"
AB3_HOOK_LOG="$ab3_dir/hook.log"; : > "$AB3_HOOK_LOG"
(
  cd "$ab3_dir/repo" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      HOOK_LOG_TARGET="$AB3_HOOK_LOG" \
      WORKTREE_ROOT="$ab3_dir/worktrees" \
      DB_DUMP="$ab3_dir/no-such-dump.sql.gz" \
      BASE_BRANCH=trunk \
      DDEV_SHOW_TABLES="" \
      bash ./setup-worktree-engine.sh ab3
) > "$ab3_dir/stdout" 2> "$ab3_dir/stderr"

if grep -qF "ran:$ab3_dir/worktrees/ab3:--provision" "$AB3_HOOK_LOG" 2>/dev/null; then
  pass "AB3: the conventional <worktree>/scripts/setup-worktree.sh runs when no env/.env PROVISION_HOOK is set"
else
  fail "AB3: the conventional hook path must be tried before falling back to the engine's own provisioning" \
"$(cat "$AB3_HOOK_LOG" 2>/dev/null)
stderr: $(cat "$ab3_dir/stderr" 2>/dev/null)"
fi

# --- AB4: no hook anywhere on disk -> the engine runs its OWN --provision
#     provisioning directly. Already exercised by C3 above; pinned again
#     explicitly here so this requirement has its own named case. -----------
if run_case ab4-no-hook-anywhere DDEV_SHOW_TABLES="" -- ab4; then
  if grep -qE '^start' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "AB4: with no PROVISION_HOOK/.env/conventional hook, the engine provisions directly"
  else
    fail "AB4: the engine must run its own --provision logic when no hook exists on disk" "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
else
  fail "AB4: could not build the sandbox case" "git init failed"
fi

# --- AB4b: a PROVISION_HOOK set in the environment but pointing at a path
#     that doesn't exist falls through to the engine's own provisioning,
#     rather than hard-failing trying to exec a missing file (review round
#     1: resolve_provision_hook used to trust env/.env with no on-disk
#     check). ------------------------------------------------------------
if run_case ab4b-stale-provision-hook DDEV_SHOW_TABLES="" \
    PROVISION_HOOK="$SANDBOX/does-not-exist-anywhere.sh" -- ab4b; then
  expect_rc0 "AB4b-1: a stale PROVISION_HOOK does not abort the run"
  if grep -qE '^start' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "AB4b-2: a stale PROVISION_HOOK falls through to the engine's own --provision logic"
  else
    fail "AB4b-2: must fall through to the engine's own provisioning" "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
else
  fail "AB4b: could not build the sandbox case" "git init failed"
fi

# --- AB5: recursion guard -- the engine's OWN --provision mode must NEVER
#     call the provision hook, even when PROVISION_HOOK is set in the
#     environment. Only the three create legs call it. ----------------------
hook_dir5="$SANDBOX/case$((CASE_N + 1))"
mkdir -p "$hook_dir5"
HOOK_LOG_AB5="$hook_dir5/hook.log"; : > "$HOOK_LOG_AB5"
cat > "$hook_dir5/hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'ran:%s:%s\n' "$PWD" "$*" >> "$HOOK_LOG_TARGET"
HOOK
chmod +x "$hook_dir5/hook.sh"

if run_provision_case ab5-provision-mode-no-recursion \
     "PROVISION_HOOK=$hook_dir5/hook.sh" "HOOK_LOG_TARGET=$HOOK_LOG_AB5" -- --provision; then
  if [ ! -s "$HOOK_LOG_AB5" ]; then
    pass "AB5: --provision mode never calls PROVISION_HOOK, even when one is set (recursion guard)"
  else
    fail "AB5: --provision mode must never invoke the provision hook" "$(cat "$HOOK_LOG_AB5" 2>/dev/null)"
  fi
else
  fail "AB5: could not build the provision-mode sandbox case" "git init/worktree failed"
fi

# ===========================================================================
# AC. Remaining genericization (worktree-promotion-spec.md item 5): the
#     WORKTREE_ROOT default, DB_DUMP precedence (incl. the no-dump-skips-import
#     case), BASE_BRANCH unresolvable -> refuse non-zero creating nothing, and
#     the conditional
#     legs (no .ddev/, no composer.json, no scripts/githooks) -- including
#     the spec's done-criterion 5: a project with NONE of those four things
#     provisions successfully.
# ===========================================================================

# --- AC1: WORKTREE_ROOT default is $HOME/Projects/worktrees/<main-checkout
#     basename>, not a hardcoded .../acme-site. Uses a fake $HOME so this
#     never touches the real one. -------------------------------------------
ac1_dir="$SANDBOX/ac1"
mkdir -p "$ac1_dir/some-other-checkout" "$ac1_dir/fake-home"
git init -q -b trunk "$ac1_dir/some-other-checkout" >/dev/null 2>&1
printf 'seed\n' > "$ac1_dir/some-other-checkout/README.md"
git -C "$ac1_dir/some-other-checkout" add README.md >/dev/null 2>&1
git -C "$ac1_dir/some-other-checkout" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
cp "$SCRIPT" "$ac1_dir/some-other-checkout/setup-worktree.sh"
(
  cd "$ac1_dir/some-other-checkout" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      HOME="$ac1_dir/fake-home" \
      DB_DUMP="$ac1_dir/no-such-dump.sql.gz" \
      BASE_BRANCH=trunk \
      DDEV_SHOW_TABLES="" \
      bash ./setup-worktree.sh ac1
) > "$ac1_dir/stdout" 2> "$ac1_dir/stderr"

if [ -d "$ac1_dir/fake-home/Projects/worktrees/some-other-checkout/ac1" ]; then
  pass "AC1: WORKTREE_ROOT default is \$HOME/Projects/worktrees/<main-checkout-basename>, not a hardcoded acme-site path"
else
  fail "AC1: WORKTREE_ROOT must default to \$HOME/Projects/worktrees/<main-checkout-basename>" \
"expected a worktree under $ac1_dir/fake-home/Projects/worktrees/some-other-checkout/ac1
stdout: $(cat "$ac1_dir/stdout" 2>/dev/null)
stderr: $(cat "$ac1_dir/stderr" 2>/dev/null)"
fi

# --- AC2: DB_DUMP precedence -- environment wins, then the main checkout's
#     .env, then no default at all (no db/trunk.sql.gz literal in the engine).
#     No dump resolved anywhere -> skip the import, exit 0. ------------------
if run_case ac2-db-dump-env-wins DB_DUMP="does-not-exist-either.sql.gz" -- ac2; then
  expect_rc0 "AC2a: an unresolvable DB_DUMP still exits 0 (skips the import)"
  expect_stdout_lacks "AC2b: no import is attempted when DB_DUMP resolves to a path that doesn't exist" "import-db"
else
  fail "AC2: could not build the sandbox case" "git init failed"
fi

CASE_DOTENV=$'BASE_BRANCH=trunk\nDB_DUMP=from-dotenv.sql.gz'
CASE_UNSET_DB_DUMP=1
if run_case ac3-db-dump-dotenv -- ac3; then
  unset CASE_UNSET_DB_DUMP
  if grep -qiF 'from-dotenv.sql.gz' "$OUT" "$ERR" 2>/dev/null; then
    pass "AC3: DB_DUMP from the main checkout's .env is used when unset in the environment"
  else
    fail "AC3: DB_DUMP must be resolvable from the main checkout's .env" \
"stdout: $(cat "$OUT")
stderr: $(cat "$ERR")"
  fi
else
  unset CASE_UNSET_DB_DUMP
  fail "AC3: could not build the sandbox case" "git init failed"
fi
unset CASE_DOTENV

# --- AC4: the deprecated IH_DB_DUMP alias is GONE -- setting only IH_DB_DUMP
#     (a real, importable dump) with DB_DUMP genuinely unset must NOT trigger
#     an import; DB_DUMP is the only supported name now. Exercised on
#     provision mode, which is where IH_DB_DUMP used to live. ---------------
ac4_real_dump="$SANDBOX/ac4-real-dump.sql.gz"
printf 'not a real dump, just needs to exist\n' > "$ac4_real_dump"
CASE_UNSET_DB_DUMP=1
if run_provision_case ac4-ih-db-dump-alias-ignored DDEV_SHOW_TABLES="" IH_DB_DUMP="$ac4_real_dump" -- --provision; then
  unset CASE_UNSET_DB_DUMP
  expect_rc0 "AC4a: provision mode still exits 0 when only the deprecated IH_DB_DUMP is set"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "AC4b: the deprecated IH_DB_DUMP alias must be ignored now that DB_DUMP is unset" \
"$(cat "$DDEV_LOG_FILE" 2>/dev/null | tr '\037' '|')"
  else
    pass "AC4b: the deprecated IH_DB_DUMP alias is ignored (DB_DUMP is the only supported name)"
  fi
else
  unset CASE_UNSET_DB_DUMP
  fail "AC4: could not build the provision-mode sandbox case" "git init/worktree failed"
fi


# --- AC5: BASE_BRANCH unresolvable anywhere (no env, no .env, no
#     hardcoded base-branch literal left in the engine) -> refuse, exit
#     non-zero, create NOTHING (not even the worktree directory). ----------
ac5_dir="$SANDBOX/ac5"
mkdir -p "$ac5_dir/acme-site"
git init -q "$ac5_dir/acme-site" >/dev/null 2>&1
# Detached-ish: a repo whose HEAD is not a normal branch checkout, so the old
# `git symbolic-ref` fallback also has nothing to give -- this is the only
# way to reach "truly unresolvable" now that the hardcoded base-branch
# literal is gone from the engine.
printf 'seed\n' > "$ac5_dir/acme-site/README.md"
git -C "$ac5_dir/acme-site" add README.md >/dev/null 2>&1
git -C "$ac5_dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
git -C "$ac5_dir/acme-site" checkout -q --detach >/dev/null 2>&1
cp "$SCRIPT" "$ac5_dir/acme-site/setup-worktree.sh"
(
  cd "$ac5_dir/acme-site" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      WORKTREE_ROOT="$ac5_dir/worktrees" \
      DB_DUMP="$ac5_dir/no-such-dump.sql.gz" \
      bash ./setup-worktree.sh ac5
) > "$ac5_dir/stdout" 2> "$ac5_dir/stderr"
ac5_rc=$?

if [ "$ac5_rc" -ne 0 ]; then
  pass "AC5a: an unresolvable BASE_BRANCH refuses with a non-zero exit"
else
  fail "AC5a: an unresolvable BASE_BRANCH must refuse (non-zero exit), not fall back to a literal" "exit $ac5_rc"
fi
if [ ! -e "$ac5_dir/worktrees/ac5" ]; then
  pass "AC5b: an unresolvable BASE_BRANCH creates nothing"
else
  fail "AC5b: an unresolvable BASE_BRANCH must create nothing" "$ac5_dir/worktrees/ac5 exists"
fi

# --- AC6: the DDEV leg only runs when <worktree>/.ddev/ exists. No .ddev/
#     is a plain worktree and a SUCCESS, not a warning. ---------------------
ac6_dir="$SANDBOX/ac6"
mkdir -p "$ac6_dir/acme-site"
git init -q -b trunk "$ac6_dir/acme-site" >/dev/null 2>&1
printf 'seed\n' > "$ac6_dir/acme-site/README.md"
git -C "$ac6_dir/acme-site" add README.md >/dev/null 2>&1
git -C "$ac6_dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
cp "$SCRIPT" "$ac6_dir/acme-site/setup-worktree.sh"
AC6_DDEV_LOG="$ac6_dir/ddev.log"; : > "$AC6_DDEV_LOG"
(
  cd "$ac6_dir/acme-site" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      DDEV_LOG="$AC6_DDEV_LOG" \
      WORKTREE_ROOT="$ac6_dir/worktrees" \
      DB_DUMP="$ac6_dir/no-such-dump.sql.gz" \
      BASE_BRANCH=trunk \
      bash ./setup-worktree.sh ac6
) > "$ac6_dir/stdout" 2> "$ac6_dir/stderr"
ac6_rc=$?

# NOTE: this repo has no `.ddev/` in its committed tree (unlike run_case's
# fixture, which always seeds README.md + composer.json but no .ddev/
# either -- confirmed here explicitly since this is the property under
# test).
if [ "$ac6_rc" -eq 0 ]; then
  pass "AC6a: a worktree with no .ddev/ still exits 0"
else
  fail "AC6a: no .ddev/ must be a success, not a failure" \
"exit $ac6_rc
stdout: $(cat "$ac6_dir/stdout")
stderr: $(cat "$ac6_dir/stderr")"
fi
if [ ! -s "$AC6_DDEV_LOG" ]; then
  pass "AC6b: no .ddev/ skips the DDEV leg entirely -- no \`ddev\` call at all"
else
  fail "AC6b: the DDEV leg must not run when the worktree has no .ddev/" "$(tr '\037' '|' < "$AC6_DDEV_LOG")"
fi
if grep -qiE 'warn' "$ac6_dir/stderr" 2>/dev/null; then
  fail "AC6c: no .ddev/ must not print a warning -- it is a plain worktree, not a degraded one" "$(cat "$ac6_dir/stderr")"
else
  pass "AC6c: no .ddev/ produces no warning"
fi

# --- AC7 (spec done-criterion 5): a project with NONE of .ddev/,
#     composer.json, scripts/githooks, or a shim provisions successfully. ---
ac7_dir="$SANDBOX/ac7"
mkdir -p "$ac7_dir/acme-site"
git init -q -b trunk "$ac7_dir/acme-site" >/dev/null 2>&1
printf 'seed\n' > "$ac7_dir/acme-site/README.md"
git -C "$ac7_dir/acme-site" add README.md >/dev/null 2>&1
git -C "$ac7_dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
cp "$SCRIPT" "$ac7_dir/acme-site/setup-worktree.sh"
(
  cd "$ac7_dir/acme-site" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      WORKTREE_ROOT="$ac7_dir/worktrees" \
      DB_DUMP="$ac7_dir/no-such-dump.sql.gz" \
      BASE_BRANCH=trunk \
      bash ./setup-worktree.sh ac7
) > "$ac7_dir/stdout" 2> "$ac7_dir/stderr"
ac7_rc=$?

if [ "$ac7_rc" -eq 0 ]; then
  pass "AC7: DONE CRITERION 5 -- a project with no shim, no .ddev/, no composer.json and no scripts/githooks provisions successfully"
else
  fail "AC7: a project with none of .ddev/, composer.json, scripts/githooks or a shim must still provision successfully" \
"exit $ac7_rc
stdout: $(cat "$ac7_dir/stdout")
stderr: $(cat "$ac7_dir/stderr")"
fi
if [ -d "$ac7_dir/worktrees/ac7" ] && git -C "$ac7_dir/worktrees/ac7" rev-parse HEAD >/dev/null 2>&1; then
  pass "AC7b: the worktree itself was created despite the missing optional pieces"
else
  fail "AC7b: the worktree must still be created" "no worktree at $ac7_dir/worktrees/ac7"
fi

# --- AC8: `ddev composer install` only runs when the worktree has a
#     composer.json (unlike run_case's fixture, which always seeds one). ----
ac8_dir="$SANDBOX/ac8"
mkdir -p "$ac8_dir/acme-site/.ddev"
git init -q -b trunk "$ac8_dir/acme-site" >/dev/null 2>&1
printf 'seed\n' > "$ac8_dir/acme-site/README.md"
printf 'name: seed\n' > "$ac8_dir/acme-site/.ddev/config.yaml"
git -C "$ac8_dir/acme-site" add README.md .ddev/config.yaml >/dev/null 2>&1
git -C "$ac8_dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
cp "$SCRIPT" "$ac8_dir/acme-site/setup-worktree.sh"
AC8_DDEV_LOG="$ac8_dir/ddev.log"; : > "$AC8_DDEV_LOG"
(
  cd "$ac8_dir/acme-site" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      DDEV_LOG="$AC8_DDEV_LOG" \
      DDEV_SHOW_TABLES="" \
      WORKTREE_ROOT="$ac8_dir/worktrees" \
      DB_DUMP="$ac8_dir/no-such-dump.sql.gz" \
      BASE_BRANCH=trunk \
      bash ./setup-worktree.sh ac8
) > "$ac8_dir/stdout" 2> "$ac8_dir/stderr"
ac8_rc=$?

if [ "$ac8_rc" -eq 0 ]; then
  pass "AC8a: a worktree with .ddev/ but no composer.json still exits 0"
else
  fail "AC8a: no composer.json must not fail the run" "exit $ac8_rc; stderr: $(cat "$ac8_dir/stderr")"
fi
if grep -qE '^composer' "$AC8_DDEV_LOG" 2>/dev/null; then
  fail "AC8b: \`ddev composer install\` must not run when there is no composer.json" "$(tr '\037' '|' < "$AC8_DDEV_LOG")"
else
  pass "AC8b: \`ddev composer install\` is skipped when there is no composer.json"
fi
if grep -qE '^start' "$AC8_DDEV_LOG" 2>/dev/null; then
  pass "AC8c: the rest of the DDEV leg (\`ddev start\`) still runs since .ddev/ exists"
else
  fail "AC8c: \`ddev start\` should still run when .ddev/ exists, even with no composer.json" "$(tr '\037' '|' < "$AC8_DDEV_LOG")"
fi

# --- AC9: `git config core.hooksPath scripts/githooks` only runs when
#     <worktree>/scripts/githooks exists. ------------------------------------
ac9_dir="$SANDBOX/ac9"
mkdir -p "$ac9_dir/acme-site"
git init -q -b trunk "$ac9_dir/acme-site" >/dev/null 2>&1
printf 'seed\n' > "$ac9_dir/acme-site/README.md"
git -C "$ac9_dir/acme-site" add README.md >/dev/null 2>&1
git -C "$ac9_dir/acme-site" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
cp "$SCRIPT" "$ac9_dir/acme-site/setup-worktree.sh"
(
  cd "$ac9_dir/acme-site" || exit 99
  env "${SCRUB[@]}" \
      PATH="$STUB_BIN:$PATH" \
      WORKTREE_ROOT="$ac9_dir/worktrees" \
      DB_DUMP="$ac9_dir/no-such-dump.sql.gz" \
      BASE_BRANCH=trunk \
      bash ./setup-worktree.sh ac9
) > "$ac9_dir/stdout" 2> "$ac9_dir/stderr"
ac9_rc=$?

if [ "$ac9_rc" -eq 0 ]; then
  pass "AC9a: a worktree with no scripts/githooks still exits 0"
else
  fail "AC9a: no scripts/githooks must not fail the run" "exit $ac9_rc; stderr: $(cat "$ac9_dir/stderr")"
fi
if git -C "$ac9_dir/worktrees/ac9" config --get core.hooksPath >/dev/null 2>&1; then
  fail "AC9b: core.hooksPath must not be set when the worktree has no scripts/githooks directory" \
"$(git -C "$ac9_dir/worktrees/ac9" config --get core.hooksPath 2>/dev/null)"
else
  pass "AC9b: core.hooksPath is left unset when there is no scripts/githooks directory"
fi

# ===========================================================================
# Y. After a FRESH `ddev import-db`, a Drupal site must run
#    `ddev drush deploy` (updatedb + config:import + cache-rebuild + deploy
#    hooks) so the checked-out code and the just-imported DB agree. Applies
#    to BOTH provisioning legs: run_provision (mode 2, --provision) and
#    own_provision_mode1 (mode 1, hook-absent path).
#
#    Rules under test:
#      - only fires in the branch where `ddev import-db` itself ran -- not
#        on an already-populated DB, not when there is no dump, not when
#        `ddev mysql` failed (Y1-Y2 provision / Y9-Y10 full mode: populated
#        skips; Y3/Y11: no dump skips; Y4/Y12: failing \`ddev mysql\` skips)
#      - only when .ddev/config.yaml's `type:` starts with `drupal`, quoted
#        or not, with or without a version suffix (Y1/Y9 drupal, Y7/Y15
#        quoted "drupal10")
#      - any other `type:` (Y5/Y13, `type: php`) or NO .ddev/config.yaml at
#        all (Y6/Y14) must never call drush, even on a fresh import
#      - ordering: `import-db` then `drush deploy` in the ddev call log
#        (Y1b/Y9b)
#      - a failing `ddev drush deploy` warns on stderr naming the failure
#        and the re-run command (`ddev drush deploy`), but the run still
#        exits 0 (Y8/Y16)
#      - success prints a stdout line mentioning "drush deploy" (Y1c/Y9c)
#
#    New stub knob: DDEV_DRUSH_DEPLOY_EXIT (see the ddev stub above) makes
#    `ddev drush deploy` itself exit non-zero, independent of DDEV_EXIT
#    (which would also break the earlier `ddev start`/`ddev composer
#    install` calls in the same run and confound these cases).
# ===========================================================================

build_y_case() {
  # build_y_case <name> <mode: provision|full> <id-or-branch> \
  #   <ddev-config-yaml-type-line-or-EMPTY-for-no-config.yaml> \
  #   <dump: yes|no> <show-tables-value> [<mysql-exit>] [<drush-deploy-exit>]
  #
  # Builds a throwaway main repo (+ a worktree already checked out, for the
  # provision leg) carrying an optional .ddev/config.yaml and an optional
  # fake dump file, then runs the script exactly the way P8-P11/X1-X16 do
  # for the two provisioning call sites, with the DDEV_DRUSH_DEPLOY_EXIT
  # knob layered on top. Sets DDEV_LOG_FILE/OUT/ERR/RC/CASE_DIR
  # the same way every other builder in this suite does.
  local name="$1" mode="$2" idbr="$3" ddevtype="$4" dump="$5" showtables="$6"
  local mysqlexit="${7:-}" drushexit="${8:-}"

  CASE_N=$((CASE_N + 1))
  local dir="$SANDBOX/ycase$CASE_N"
  CASE_DIR="$dir"
  mkdir -p "$dir/acme-site"
  git init -q -b trunk "$dir/acme-site" >/dev/null 2>&1 || return 1
  printf 'seed\n' > "$dir/acme-site/README.md"
  printf 'seed\n' > "$dir/acme-site/composer.json"
  if [ -n "$ddevtype" ]; then
    mkdir -p "$dir/acme-site/.ddev"
    printf '%s\n' "$ddevtype" > "$dir/acme-site/.ddev/config.yaml"
  fi
  if [ "$dump" = "yes" ]; then
    mkdir -p "$dir/acme-site/db"
    printf 'not a real dump, just needs to exist\n' > "$dir/acme-site/db/trunk.sql.gz"
  fi
  git -C "$dir/acme-site" add -A >/dev/null 2>&1 || return 1
  git -C "$dir/acme-site" -c user.email=t@t -c user.name=t \
    commit -q -m init >/dev/null 2>&1 || return 1

  DDEV_LOG_FILE="$dir/ddev.log"; : > "$DDEV_LOG_FILE"
  OUT="$dir/stdout"; ERR="$dir/stderr"

  local dbdump_env=(DB_DUMP="$dir/no-such-dump.sql.gz")
  [ "$dump" = "yes" ] && dbdump_env=(DB_DUMP="db/trunk.sql.gz")

  if [ "$mode" = "provision" ]; then
    local wt="$dir/wt"
    git -C "$dir/acme-site" worktree add -q -b "$idbr" "$wt" trunk >/dev/null 2>&1 || return 1
    cp "$SCRIPT" "$wt/setup-worktree.sh" || return 1
    PROV_WT="$wt"; PROV_MAIN="$dir/acme-site"
    (
      cd "$wt" || exit 99
      env "${SCRUB[@]}" PATH="$STUB_BIN:$PATH" \
          DDEV_LOG="$DDEV_LOG_FILE" \
          DDEV_SHOW_TABLES="$showtables" \
          DDEV_MYSQL_EXIT="$mysqlexit" \
          DDEV_DRUSH_DEPLOY_EXIT="$drushexit" \
          "${dbdump_env[@]}" \
          bash ./setup-worktree.sh --provision
    ) > "$OUT" 2> "$ERR"
  else
    cp "$SCRIPT" "$dir/acme-site/setup-worktree.sh" || return 1
    FULL_WT="$dir/worktrees/$idbr"
    (
      cd "$dir/acme-site" || exit 99
      env "${SCRUB[@]}" \
          PATH="$STUB_BIN:$PATH" \
          DDEV_LOG="$DDEV_LOG_FILE" \
          DDEV_SHOW_TABLES="$showtables" \
          DDEV_MYSQL_EXIT="$mysqlexit" \
          DDEV_DRUSH_DEPLOY_EXIT="$drushexit" \
          WORKTREE_ROOT="$dir/worktrees" \
          "${dbdump_env[@]}" \
          BASE_BRANCH=trunk \
          bash ./setup-worktree.sh "$idbr"
    ) > "$OUT" 2> "$ERR"
  fi
  RC=$?
  return 0
}

y_import_line() { grep -nE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null | head -1 | cut -d: -f1; }
y_drush_line() { grep -nE '^drush' "$DDEV_LOG_FILE" 2>/dev/null | head -1 | cut -d: -f1; }

y_expect_no_drush() { # y_expect_no_drush <label>
  if grep -qE '^drush' "$DDEV_LOG_FILE" 2>/dev/null; then
    fail "$1" "\`ddev drush deploy\` must not have run: $(tr '\037' '|' < "$DDEV_LOG_FILE")"
  else
    pass "$1"
  fi
}

y_expect_drush_after_import() { # y_expect_drush_after_import <label>
  local il dl
  il="$(y_import_line)"; dl="$(y_drush_line)"
  if [ -z "$dl" ]; then
    fail "$1" "\`ddev drush deploy\` never ran: $(tr '\037' '|' < "$DDEV_LOG_FILE")"
  elif [ -z "$il" ]; then
    fail "$1" "\`ddev drush deploy\` ran but \`ddev import-db\` never did: $(tr '\037' '|' < "$DDEV_LOG_FILE")"
  elif [ "$il" -lt "$dl" ]; then
    pass "$1"
  else
    fail "$1" "\`ddev drush deploy\` must run AFTER \`ddev import-db\`, not before/instead: $(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
}

# --- Y1-Y8: provision mode (mode 2, run_provision) --------------------------

if build_y_case y-fresh-drupal-provision provision 500 "type: drupal" yes ""; then
  expect_rc0 "Y1a: Drupal type + empty DB + dump present exits 0"
  y_expect_drush_after_import "Y1b: provision mode: \`ddev drush deploy\` runs, after \`ddev import-db\`"
  expect_stdout_has "Y1c: provision mode: success output mentions drush deploy" "drush deploy"
else
  fail "Y1: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-populated-drupal-provision provision 501 "type: drupal" yes $'existing_table\n'; then
  expect_rc0 "Y2a: Drupal type + already-populated DB still exits 0"
  y_expect_no_drush "Y2b: provision mode: a populated DB (no fresh import) must NOT run \`ddev drush deploy\`"
else
  fail "Y2: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-no-dump-drupal-provision provision 502 "type: drupal" no ""; then
  expect_rc0 "Y3a: Drupal type + no dump present still exits 0"
  y_expect_no_drush "Y3b: provision mode: no dump (no fresh import) must NOT run \`ddev drush deploy\`"
else
  fail "Y3: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-mysql-fails-drupal-provision provision 503 "type: drupal" yes "" 1; then
  y_expect_no_drush "Y4: provision mode: a failing \`ddev mysql\` (no fresh import) must NOT run \`ddev drush deploy\`"
else
  fail "Y4: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-nondrupal-fresh-provision provision 504 "type: php" yes ""; then
  expect_rc0 "Y5a: non-Drupal type + fresh import still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "Y5b: provision mode: non-Drupal type still imports the dump"
  else
    fail "Y5b: provision mode: an empty database should have run \`ddev import-db\` regardless of type" \
      "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
  y_expect_no_drush "Y5c: provision mode: non-Drupal type (\`type: php\`) must NOT run \`ddev drush deploy\`, even on a fresh import"
else
  fail "Y5: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-no-config-fresh-provision provision 505 "" yes ""; then
  expect_rc0 "Y6a: no .ddev/config.yaml at all + fresh import still exits 0"
  y_expect_no_drush "Y6b: provision mode: no .ddev/config.yaml means no Drupal-type signal -- must NOT run \`ddev drush deploy\`"
else
  fail "Y6: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-quoted-type-fresh-provision provision 506 'type: "drupal10"' yes ""; then
  expect_rc0 "Y7a: quoted, versioned Drupal type (drupal10) + fresh import still exits 0"
  y_expect_drush_after_import "Y7b: provision mode: \`type: \"drupal10\"\` is still detected as Drupal -- \`ddev drush deploy\` runs after \`ddev import-db\`"
else
  fail "Y7: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-drush-fails-provision provision 507 "type: drupal" yes "" "" 1; then
  expect_rc0 "Y8a: provision mode: a failing \`ddev drush deploy\` is a WARNING, not a run failure -- still exits 0"
  expect_script_warns "Y8b: provision mode: the drush-deploy failure is named on stderr, with the re-run command" \
    "drush deploy"
  expect_stdout_has "Y8c: provision mode: provisioning still finishes (the 'ready' line still prints) despite the drush-deploy failure" \
    "ready"
else
  fail "Y8: could not build the sandbox case" "git init/worktree/copy failed"
fi

# --- Y9-Y16: the SAME eight scenarios, through Mode 1 (full: <id>, the
#     script's own `git worktree add`), covering own_provision_mode1. -------

if build_y_case y-fresh-drupal-full full wt-y9 "type: drupal" yes ""; then
  expect_rc0 "Y9a: full mode: Drupal type + empty DB + dump present exits 0"
  y_expect_drush_after_import "Y9b: full mode: \`ddev drush deploy\` runs, after \`ddev import-db\`"
  expect_stdout_has "Y9c: full mode: success output mentions drush deploy" "drush deploy"
else
  fail "Y9: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-populated-drupal-full full wt-y10 "type: drupal" yes $'existing_table\n'; then
  expect_rc0 "Y10a: full mode: Drupal type + already-populated DB still exits 0"
  y_expect_no_drush "Y10b: full mode: a populated DB (no fresh import) must NOT run \`ddev drush deploy\`"
else
  fail "Y10: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-no-dump-drupal-full full wt-y11 "type: drupal" no ""; then
  expect_rc0 "Y11a: full mode: no dump present still exits 0"
  y_expect_no_drush "Y11b: full mode: no dump (no fresh import) must NOT run \`ddev drush deploy\`"
else
  fail "Y11: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-mysql-fails-drupal-full full wt-y12 "type: drupal" yes "" 1; then
  y_expect_no_drush "Y12: full mode: a failing \`ddev mysql\` (no fresh import) must NOT run \`ddev drush deploy\`"
else
  fail "Y12: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-nondrupal-fresh-full full wt-y13 "type: php" yes ""; then
  expect_rc0 "Y13a: full mode: non-Drupal type + fresh import still exits 0"
  if grep -qE '^import-db' "$DDEV_LOG_FILE" 2>/dev/null; then
    pass "Y13b: full mode: non-Drupal type still imports the dump"
  else
    fail "Y13b: full mode: an empty database should have run \`ddev import-db\` regardless of type" \
      "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
  fi
  y_expect_no_drush "Y13c: full mode: non-Drupal type (\`type: php\`) must NOT run \`ddev drush deploy\`, even on a fresh import"
else
  fail "Y13: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-no-config-fresh-full full wt-y14 "" yes ""; then
  expect_rc0 "Y14a: full mode: no .ddev/config.yaml at all + fresh import still exits 0"
  y_expect_no_drush "Y14b: full mode: no .ddev/config.yaml means no Drupal-type signal -- must NOT run \`ddev drush deploy\`"
else
  fail "Y14: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-quoted-type-fresh-full full wt-y15 'type: "drupal10"' yes ""; then
  expect_rc0 "Y15a: full mode: quoted, versioned Drupal type (drupal10) + fresh import still exits 0"
  y_expect_drush_after_import "Y15b: full mode: \`type: \"drupal10\"\` is still detected as Drupal -- \`ddev drush deploy\` runs after \`ddev import-db\`"
else
  fail "Y15: could not build the sandbox case" "git init/copy failed"
fi

if build_y_case y-drush-fails-full full wt-y16 "type: drupal" yes "" "" 1; then
  expect_rc0 "Y16a: full mode: a failing \`ddev drush deploy\` is a WARNING, not a run failure -- still exits 0"
  expect_script_warns "Y16b: full mode: the drush-deploy failure is named on stderr, with the re-run command" \
    "drush deploy"
  expect_stdout_has "Y16c: full mode: provisioning still finishes (the 'ready'/completion line still prints) despite the drush-deploy failure" \
    "ready"
else
  fail "Y16: could not build the sandbox case" "git init/copy failed"
fi

# --- Y17-Y18: `drupal6`/`drupal7` must NOT count as Drupal for this purpose
#     -- their `drush` has no `deploy` command. `drupal*` alone (the
#     pre-fix pattern) would wrongly match these. ----------------------------

if build_y_case y-drupal7-fresh-provision provision 508 "type: drupal7" yes ""; then
  expect_rc0 "Y17a: provision mode: drupal7 type + fresh import still exits 0"
  y_expect_no_drush "Y17b: provision mode: \`type: drupal7\` must NOT run \`ddev drush deploy\` -- drupal7's drush has no \`deploy\` command"
else
  fail "Y17: could not build the sandbox case" "git init/worktree/copy failed"
fi

if build_y_case y-drupal7-fresh-full full wt-y18 "type: drupal7" yes ""; then
  expect_rc0 "Y18a: full mode: drupal7 type + fresh import still exits 0"
  y_expect_no_drush "Y18b: full mode: \`type: drupal7\` must NOT run \`ddev drush deploy\` -- drupal7's drush has no \`deploy\` command"
else
  fail "Y18: could not build the sandbox case" "git init/copy failed"
fi

# --- Y19: RELATIVE WORKTREE_ROOT must not defeat Drupal detection. ----------
#
# own_provision_mode1 receives $wt (built from $WORKTREE_ROOT/$id), `cd`s
# into it, and THEN must detect Drupal-ness and run `drush deploy`. If
# $WORKTREE_ROOT is a RELATIVE path and the detection/deploy call sites
# re-use that same relative $wt string AFTER the `cd`, it resolves against
# the NEW cwd (the worktree itself, since the cd already landed there)
# instead of where it pointed before the cd -- silently skipping
# `ddev drush deploy` on an otherwise-qualifying Drupal site. This case pins
# a relative WORKTREE_ROOT (relative to the main repo, where the script
# starts and where `git worktree add` runs) all the way through to a
# fresh-import Drupal site still getting `ddev drush deploy`.

y19_dir="$SANDBOX/ycase-relative"
mkdir -p "$y19_dir/acme-site"
if git init -q -b trunk "$y19_dir/acme-site" >/dev/null 2>&1; then
  mkdir -p "$y19_dir/acme-site/.ddev" "$y19_dir/acme-site/db"
  printf 'type: drupal\n' > "$y19_dir/acme-site/.ddev/config.yaml"
  printf 'seed\n' > "$y19_dir/acme-site/README.md"
  printf 'seed\n' > "$y19_dir/acme-site/composer.json"
  printf 'not a real dump, just needs to exist\n' > "$y19_dir/acme-site/db/trunk.sql.gz"
  git -C "$y19_dir/acme-site" add -A >/dev/null 2>&1
  git -C "$y19_dir/acme-site" -c user.email=t@t -c user.name=t \
    commit -q -m init >/dev/null 2>&1
  cp "$SCRIPT" "$y19_dir/acme-site/setup-worktree.sh"

  Y19_LOG="$y19_dir/ddev.log"; : > "$Y19_LOG"
  Y19_OUT="$y19_dir/stdout"

  (
    cd "$y19_dir/acme-site" || exit 99
    env "${SCRUB[@]}" \
        PATH="$STUB_BIN:$PATH" \
        DDEV_LOG="$Y19_LOG" \
        DDEV_SHOW_TABLES="" \
        WORKTREE_ROOT="relative-worktrees" \
        DB_DUMP="db/trunk.sql.gz" \
        BASE_BRANCH=trunk \
        bash ./setup-worktree.sh wt-y19
  ) > "$Y19_OUT" 2>&1
  Y19_RC=$?

  if [ "$Y19_RC" -ne 0 ]; then
    fail "Y19a: full mode: a RELATIVE WORKTREE_ROOT still exits 0" "$(cat "$Y19_OUT")"
  else
    pass "Y19a: full mode: a RELATIVE WORKTREE_ROOT still exits 0"
  fi
  if grep -qE '^drush' "$Y19_LOG" 2>/dev/null; then
    pass "Y19b: full mode: a RELATIVE WORKTREE_ROOT does not defeat Drupal detection -- \`ddev drush deploy\` still runs after a fresh import"
  else
    fail "Y19b: full mode: a RELATIVE WORKTREE_ROOT does not defeat Drupal detection -- \`ddev drush deploy\` still runs after a fresh import" \
      "$(tr '\037' '|' < "$Y19_LOG")"
  fi
else
  fail "Y19: could not build the sandbox case" "git init failed"
fi

# ===========================================================================
# --- R. A branch that exists only on origin --------------------------------
#
# `<id>` naming a branch that lives on origin but not locally must check that
# branch out, tracking origin -- not cut a fresh `<id>` from BASE_BRANCH,
# which would silently hand the caller the wrong code under the right name.
# ===========================================================================
r1_dir="$SANDBOX/r1"
mkdir -p "$r1_dir"
if git init -q --bare -b trunk "$r1_dir/origin.git" >/dev/null 2>&1 &&
   git init -q -b trunk "$r1_dir/acme-site" >/dev/null 2>&1; then
  (
    cd "$r1_dir/acme-site" || exit 99
    printf 'seed\n' > README.md
    git add README.md
    git -c user.email=t@t -c user.name=t commit -q -m init
    git remote add origin "$r1_dir/origin.git"
    git push -q origin trunk
    git switch -q -c feature-x
    printf 'feature\n' > feature.txt
    git add feature.txt
    git -c user.email=t@t -c user.name=t commit -q -m feature
    git push -q origin feature-x
    git switch -q trunk
    git branch -q -D feature-x
  ) >/dev/null 2>&1
  r1_remote_sha="$(git -C "$r1_dir/acme-site" rev-parse origin/feature-x)"
  cp "$SCRIPT" "$r1_dir/acme-site/setup-worktree.sh"
  (
    cd "$r1_dir/acme-site" || exit 99
    env "${SCRUB[@]}" PATH="$STUB_BIN:$PATH" \
        WORKTREE_ROOT="$r1_dir/worktrees" BASE_BRANCH=trunk \
        bash ./setup-worktree.sh feature-x
  ) > "$r1_dir/out" 2>&1
  r1_rc=$?
  r1_wt="$r1_dir/worktrees/feature-x"
  if [ "$r1_rc" -eq 0 ] && [ "$(git -C "$r1_wt" rev-parse HEAD 2>/dev/null)" = "$r1_remote_sha" ]; then
    pass "R1a: an origin-only branch is checked out at origin's commit, not cut from BASE_BRANCH"
  else
    fail "R1a: an origin-only branch is checked out at origin's commit, not cut from BASE_BRANCH" \
      "rc=$r1_rc head=$(git -C "$r1_wt" rev-parse HEAD 2>/dev/null) want=$r1_remote_sha
$(cat "$r1_dir/out")"
  fi
  if [ "$(git -C "$r1_wt" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" = "origin/feature-x" ]; then
    pass "R1b: the checked-out branch tracks origin/<id>"
  else
    fail "R1b: the checked-out branch tracks origin/<id>" \
      "upstream=$(git -C "$r1_wt" rev-parse --abbrev-ref '@{upstream}' 2>&1)"
  fi
  # Cleanup (orca-retire-merged) reads this to tell "merged" from "never
  # worked on"; an existing branch is where the two look alike.
  r1_start="$(cat "$(git -C "$r1_wt" rev-parse --absolute-git-dir 2>/dev/null)/worktree-start-sha" 2>/dev/null)"
  if [ -n "$r1_start" ] && [ "$r1_start" = "$r1_remote_sha" ]; then
    pass "R1c: the worktree's start commit is recorded in its git dir"
  else
    fail "R1c: the worktree's start commit is recorded in its git dir" \
      "recorded='$r1_start' want=$r1_remote_sha"
  fi
else
  fail "R1: could not build the sandbox case" "git init failed"
fi

# ===========================================================================
# --- D. --no-db: provision without touching the database -------------------
#
# A caller that wants the worktree and DDEV up but the database left alone
# (a fresh dump is still being made, say) passes --no-db. DDEV still starts
# and config.local.yaml is still written; no SHOW TABLES, no import, no
# drush deploy -- even with a real dump configured.
# ===========================================================================
expect_no_db_calls() { # expect_no_db_calls <label>
  if grep -qE '^(mysql|import-db|drush)' "$DDEV_LOG_FILE"; then
    fail "$1" "database calls ran: $(tr '\037' '|' < "$DDEV_LOG_FILE")"
  else
    pass "$1"
  fi
}

d_dump="$SANDBOX/d-real-dump.sql.gz"
printf 'not a real dump\n' > "$d_dump"

run_case "D1" DB_DUMP="$d_dump" -- wt-d1 --no-db
expect_rc0 "D1a: full mode with --no-db exits 0"
expect_no_db_calls "D1b: full mode with --no-db makes no database calls, even with a dump present"
if grep -qE '^start' "$DDEV_LOG_FILE"; then
  pass "D1c: full mode with --no-db still starts DDEV"
else
  fail "D1c: full mode with --no-db still starts DDEV" "$(tr '\037' '|' < "$DDEV_LOG_FILE")"
fi
if [ -f "$CASE_DIR/worktrees/wt-d1/.ddev/config.local.yaml" ]; then
  pass "D1d: full mode with --no-db still writes .ddev/config.local.yaml"
else
  fail "D1d: full mode with --no-db still writes .ddev/config.local.yaml" "missing"
fi
expect_stdout_has "D1e: full mode with --no-db says it skipped the database" "--no-db"

run_provision_case "D2" DB_DUMP="$d_dump" -- --provision --no-db
expect_rc0 "D2a: --provision --no-db exits 0"
expect_no_db_calls "D2b: --provision --no-db makes no database calls, even with a dump present"

d3_hook="$SANDBOX/d3-hook.sh"
d3_args="$SANDBOX/d3-args"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n' "$d3_args" > "$d3_hook"
chmod +x "$d3_hook"
run_case "D3" PROVISION_HOOK="$d3_hook" -- wt-d3 --no-db
if [ "$(cat "$d3_args" 2>/dev/null)" = "--provision --no-db" ]; then
  pass "D3: full mode passes --no-db on to the project's provision hook"
else
  fail "D3: full mode passes --no-db on to the project's provision hook" \
    "hook got: '$(cat "$d3_args" 2>/dev/null)'"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
