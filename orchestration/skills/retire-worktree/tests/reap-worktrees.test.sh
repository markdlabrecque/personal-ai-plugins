#!/usr/bin/env bash
#
# Ticket: worktree teardown — scripts/reap-worktrees.sh [--dry-run]
#
# Spec under test:
#
#   BASE_BRANCH default "trunk", REMOTE default "origin", WORKTREE_ROOT as in
#   scripts/retire-worktree.sh.
#
#   1. `git fetch --quiet $REMOTE $BASE_BRANCH` FIRST. A failed fetch exits
#      non-zero with an explanatory message and reaps NOTHING — a stale
#      remote ref would silently make everything look unmerged.
#   2. Enumerate worktrees via `git worktree list --porcelain`. Skip the main
#      checkout, any detached HEAD, anything not under $WORKTREE_ROOT, and
#      the base branch's own worktree.
#   3. "Has this branch landed on $REMOTE/$BASE_BRANCH?" — three tiers, in
#      order:
#        a. ancestor: `git merge-base --is-ancestor <branch> <base>`.
#        b. patch-equivalent: `git cherry <base> <branch>` prints no `+` line.
#        c. squash: the branch's COMBINED diff
#           (`git diff --binary $(git merge-base <base> <branch>) <branch> |
#           git patch-id --stable`) matches the patch id of some commit
#           already on <base> (in `<merge-base>..<base>`).
#        An empty combined diff also counts as landed.
#   4. Landed -> call `scripts/retire-worktree.sh <id>` WITHOUT --force. A
#      dirty worktree therefore survives and is reported as skipped.
#   5. Not landed -> skip, say why.
#   6. --dry-run prints exactly what it would retire and exits 0 without
#      calling the retire script at all.
#   7. Exit 0 when some worktrees were skipped; non-zero only on a hard
#      error such as the failed fetch.
#
# The safety property that matters most: an unmerged branch must NEVER be
# reaped. Every scenario below is built to make that failure mode as easy to
# trigger as possible if the tiers are implemented wrong, in particular the
# squash tier (3c), which is the one tier b (3b) provably cannot catch for a
# multi-commit squash — that claim itself is asserted, not just assumed.
#
# Harness rationale — hermetic, no network, no real DDEV, no herdr server:
#   * A throwaway bare "remote" repo plus a clone ("main") built under
#     mktemp -d. `git fetch`/`worktree`/`merge`/`cherry-pick`/`patch-id`
#     never leave this sandbox.
#   * `scripts/retire-worktree.sh` — the sibling script this one calls — is
#     REPLACED by a stub (not the real script) so this file tests reap's own
#     decision-making (which branches it calls retire for, with what flags,
#     and how it reports outcomes) independently of retire's own behaviour,
#     which has its own dedicated test file. The stub performs only the one
#     piece of retire's documented contract this file's dirty-worktree
#     scenario needs (a porcelain dirty check gating --force), matching
#     retire-worktree.test.sh's R4/R5 so the two files agree on behaviour.
#   * The stub is installed at $MAIN/scripts/retire-worktree.sh — the most
#     natural on-disk resolution (sibling of reap-worktrees.sh inside the
#     scripts/ dir of the checkout reap is run from), and reap-worktrees.sh
#     itself is copied to that same location so the layout matches
#     production (scripts/reap-worktrees.sh + scripts/retire-worktree.sh in
#     one directory) regardless of exactly how reap resolves its sibling.
#   * The stub logs `<id>\x1f<0-or-1 for --force>` per call so assertions
#     check exactly which ids were (and were not) retired, and with what
#     flag.
#
# Run from the repo root:
#   bash tests/repo/reap-worktrees.test.sh
#
# Requires: bash, git, jq. Exit 0 = green.

set -uo pipefail

# Derived from BASH_SOURCE, not `git rev-parse --show-toplevel` -- this suite
# must run from any cwd and must not require a git repo.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_SRC="$SKILL_DIR/scripts/reap-worktrees.sh"
RETIRE_SCRIPT_SRC="$SKILL_DIR/scripts/retire-worktree.sh"

SANDBOX_BASE="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ih-reap-XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX_BASE"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The sandbox itself is the project root (an empty .orch); each run names its
# own main checkout through MAIN_CHECKOUT. The engine runs from a copy, so
# point it at the real resolver.
export ORCH_PROJECTS_DIR="$(dirname "$SANDBOX_BASE")"
export ORCH_PROJECT_LIB="$(cd "$SKILL_DIR/../.." && pwd -P)/scripts/orch-project.sh"
unset PROJECT_NAME MAIN_CHECKOUT BASE_BRANCH WORKTREE_ROOT
: > "$SANDBOX_BASE/.orch"

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

if [ ! -f "$SCRIPT_SRC" ]; then
  note "scripts/reap-worktrees.sh does not exist yet — every case below is expected to fail red for that reason."
fi

# ---------------------------------------------------------------------------
# Minimal, curated PATH — see retire-worktree.test.sh for rationale. reap
# additionally needs `git patch-id`, which is part of git itself.
# ---------------------------------------------------------------------------
declare -A _dirs=()
for b in git bash jq mkdir cat mktemp rm sed grep awk tr dirname basename \
         realpath cut sort uniq wc cmp diff xargs sha1sum true false env \
         printf mv cp chmod pwd head; do
  p="$(command -v "$b" 2>/dev/null)" || continue
  _dirs["$(dirname "$p")"]=1
done
MINIMAL_PATH=""
for d in "${!_dirs[@]}"; do
  MINIMAL_PATH="${MINIMAL_PATH:+$MINIMAL_PATH:}$d"
done

# ---------------------------------------------------------------------------
# One fixture: a bare "remote", a "main" clone tracking it as origin/trunk, and
# a WORKTREE_ROOT. Every landing tier gets its own worktree so a single
# `git fetch` + one reap run exercises all of them together, exactly as
# reap's real enumeration loop would encounter them.
# ---------------------------------------------------------------------------
mk_commit() {
  # mk_commit <dir> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$4"
}

REMOTE_DIR="$SANDBOX_BASE/remote.git"
MAIN="$SANDBOX_BASE/main"
WTROOT="$SANDBOX_BASE/worktrees"
mkdir -p "$WTROOT"

FIXTURE_LOG="$SANDBOX_BASE/fixture-setup.log"
exec 8>&1 9>&2
exec >>"$FIXTURE_LOG" 2>&1

git init -q --bare "$REMOTE_DIR"
git clone -q "$REMOTE_DIR" "$MAIN"
(
  cd "$MAIN"
  git checkout -q -b trunk
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
  git push -q -u origin trunk
)

mk_worktree() {
  # mk_worktree <id> [<base-ref>=trunk]
  local id="$1" base="${2:-trunk}"
  git -C "$MAIN" worktree add -q -b "$id" "$WTROOT/$id" "$base" >/dev/null
}

# --- a. true merge commit --------------------------------------------------
mk_worktree merge-branch
mk_commit "$WTROOT/merge-branch" merge.txt "merge content" "merge-branch commit"
(cd "$MAIN" && git checkout -q trunk && git merge -q --no-ff merge-branch -m "merge merge-branch" && git push -q origin trunk)

# --- a. fast-forward --------------------------------------------------------
mk_worktree ff-branch
mk_commit "$WTROOT/ff-branch" ff.txt "ff content" "ff-branch commit"
(cd "$MAIN" && git checkout -q trunk && git merge -q --ff-only ff-branch && git push -q origin trunk)

# --- b. rebased / patch-equivalent -----------------------------------------
mk_worktree rebased-branch
mk_commit "$WTROOT/rebased-branch" rebased.txt "same patch content" "rebased-branch original commit"
(cd "$MAIN" && git checkout -q trunk && printf '%s\n' "same patch content" > rebased.txt && git add rebased.txt && git commit -q -m "rebased-branch landed via rebase" && git push -q origin trunk)

# --- c. squash-merged, MULTI-commit branch ----------------------------------
mk_worktree squash-branch
mk_commit "$WTROOT/squash-branch" sq-a.txt "squash content A" "squash-branch commit 1"
mk_commit "$WTROOT/squash-branch" sq-b.txt "squash content B" "squash-branch commit 2"
(cd "$MAIN" && git checkout -q trunk && git merge -q --squash squash-branch && git commit -q -m "squash-merge squash-branch" && git push -q origin trunk)

# --- genuinely unmerged branch with unique work -----------------------------
mk_worktree unmerged-branch
mk_commit "$WTROOT/unmerged-branch" unmerged.txt "never landed" "unmerged-branch commit"

# --- partly merged: one commit landed (cherry-picked), one did not ---------
mk_worktree partial-branch
mk_commit "$WTROOT/partial-branch" partial-a.txt "partial content A" "partial-branch commit 1 (will land)"
partial_c1="$(git -C "$WTROOT/partial-branch" rev-parse HEAD)"
mk_commit "$WTROOT/partial-branch" partial-b.txt "partial content B" "partial-branch commit 2 (never lands)"
(cd "$MAIN" && git checkout -q trunk && git cherry-pick "$partial_c1" && git push -q origin trunk)

# --- dirty but merged (landed, but --force is never passed, so the stub's
#     own dirty check must make it survive) ---------------------------------
mk_worktree dirty-merged-branch
mk_commit "$WTROOT/dirty-merged-branch" dirty.txt "dirty merged content" "dirty-merged-branch commit"
(cd "$MAIN" && git checkout -q trunk && git merge -q --no-ff dirty-merged-branch -m "merge dirty-merged-branch" && git push -q origin trunk)
echo "uncommitted" >> "$WTROOT/dirty-merged-branch/dirty.txt"

# --- detached HEAD worktree (landed commit, but detached -> must be
#     skipped by enumeration regardless of landed-ness) ---------------------
git -C "$MAIN" worktree add -q --detach "$WTROOT/detached-wt" trunk >/dev/null

# --- worktree outside WORKTREE_ROOT (landed, but outside root) -------------
mkdir -p "$SANDBOX_BASE/outside"
git -C "$MAIN" worktree add -q -b outside-branch "$SANDBOX_BASE/outside/outside-branch" trunk >/dev/null
mk_commit "$SANDBOX_BASE/outside/outside-branch" outside.txt "outside content" "outside-branch commit"
(cd "$MAIN" && git checkout -q trunk && git merge -q --no-ff outside-branch -m "merge outside-branch" && git push -q origin trunk)

git -C "$MAIN" checkout -q trunk

exec 1>&8 2>&9 8>&- 9>&-
note "fixture git setup output logged to $FIXTURE_LOG (kept only for the duration of this run)"

# ===========================================================================
# H1/H2: harness self-checks on the tier claims themselves, independent of
# reap-worktrees.sh. If these fail, the fixture itself is wrong and every
# result below is meaningless.
# ===========================================================================
if git -C "$MAIN" merge-base --is-ancestor merge-branch origin/trunk; then
  pass "H1a: merge-branch is a real ancestor of origin/trunk (tier a fixture is valid)"
else
  fail "H1a: merge-branch must be an ancestor of origin/trunk for this fixture to be meaningful"
fi
if git -C "$MAIN" merge-base --is-ancestor ff-branch origin/trunk; then
  pass "H1b: ff-branch is a real ancestor of origin/trunk (tier a fast-forward fixture is valid)"
else
  fail "H1b: ff-branch must be an ancestor of origin/trunk"
fi
if git -C "$MAIN" merge-base --is-ancestor rebased-branch origin/trunk; then
  fail "H2a: rebased-branch must NOT be an ancestor of origin/trunk (it must only be patch-equivalent, tier b)"
else
  pass "H2a: rebased-branch is genuinely not an ancestor (a real tier-b case, not accidentally tier a)"
fi
if git -C "$MAIN" cherry origin/trunk rebased-branch | grep -q '^+'; then
  fail "H2b: git cherry origin/trunk rebased-branch must show no '+' line (patch-equivalent)"
else
  pass "H2b: git cherry confirms rebased-branch is patch-equivalent to a commit on origin/trunk"
fi
if git -C "$MAIN" merge-base --is-ancestor squash-branch origin/trunk; then
  fail "H3a: squash-branch must NOT be an ancestor of origin/trunk (only reachable via tier c)"
else
  pass "H3a: squash-branch is genuinely not an ancestor (tier a correctly cannot catch a squash-merge)"
fi
if git -C "$MAIN" cherry origin/trunk squash-branch | grep -q '^+'; then
  pass "H3b: git cherry origin/trunk squash-branch DOES show '+' lines — tier b alone cannot catch this squash-merge, confirming the spec's claim"
else
  fail "H3b: expected tier b (git cherry) to fail on a multi-commit squash-merge, so that tier c is demonstrably necessary"
fi
squash_base_diff_id="$(git -C "$MAIN" diff --binary "$(git -C "$MAIN" merge-base origin/trunk squash-branch)" squash-branch | git -C "$MAIN" patch-id --stable | awk '{print $1}')"
squash_commit="$(git -C "$MAIN" log --format=%H origin/trunk | while read -r c; do
  if git -C "$MAIN" show "$c" | grep -q 'squash-merge squash-branch'; then echo "$c"; break; fi
done)"
squash_commit_diff_id="$(git -C "$MAIN" show --binary "$squash_commit" | git -C "$MAIN" patch-id --stable | awk '{print $1}')"
if [ -n "$squash_base_diff_id" ] && [ "$squash_base_diff_id" = "$squash_commit_diff_id" ]; then
  pass "H3c: squash-branch's combined diff patch-id matches the squash commit already on origin/trunk (tier c fixture is valid)"
else
  fail "H3c: expected the branch's combined diff patch-id to equal the squash commit's patch-id" \
"branch combined diff id: $squash_base_diff_id
squash commit id:        $squash_commit_diff_id"
fi
if git -C "$MAIN" merge-base --is-ancestor unmerged-branch origin/trunk; then
  fail "H4: unmerged-branch must NOT be an ancestor of origin/trunk (it must be genuinely unmerged)"
else
  pass "H4: unmerged-branch is genuinely unmerged (a real negative case)"
fi
if git -C "$MAIN" cherry origin/trunk partial-branch | grep -q '^+'; then
  pass "H5: git cherry origin/trunk partial-branch shows a '+' line for the commit that never landed (fixture is valid)"
else
  fail "H5: expected partial-branch's second commit to show as unmatched ('+') in git cherry"
fi

# ---------------------------------------------------------------------------
# Copy reap-worktrees.sh + install the retire-worktree.sh STUB, both under
# $MAIN/scripts/ — see file header for why.
# ---------------------------------------------------------------------------
mkdir -p "$MAIN/scripts"
cp "$SCRIPT_SRC" "$MAIN/scripts/reap-worktrees.sh" 2>/dev/null && chmod +x "$MAIN/scripts/reap-worktrees.sh"

RETIRE_LOG="$SANDBOX_BASE/retire.log"
cat > "$MAIN/scripts/retire-worktree.sh" <<'EOF'
#!/usr/bin/env bash
# Test stub standing in for scripts/retire-worktree.sh: logs "<id>\x1f<force>"
# and mimics only the one documented behaviour this fixture needs — a dirty
# worktree survives unless --force is passed.
id="${1:-}"; shift || true
force=0
for a in "$@"; do [ "$a" = "--force" ] && force=1; done
{ printf '%s\x1f%s\n' "$id" "$force"; } >> "${RETIRE_LOG:?RETIRE_LOG not set}"
wt="${WORKTREE_ROOT:?WORKTREE_ROOT not set}/$id"
if [ "$force" -eq 0 ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
  exit 2
fi
exit 0
EOF
chmod +x "$MAIN/scripts/retire-worktree.sh"

OUT=""
ERR=""
CODE=0
run_reap() {
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  ( cd "$MAIN" && MAIN_CHECKOUT="$MAIN" PATH="$MINIMAL_PATH" WORKTREE_ROOT="$WTROOT" RETIRE_LOG="$RETIRE_LOG" BASE_BRANCH=trunk \
      bash "$MAIN/scripts/reap-worktrees.sh" "$@" ) >"$outf" 2>"$errf"
  CODE=$?
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

retired() {
  # retired <id> [expected-force: 0|1]
  local id="$1" want_force="${2:-}"
  local line
  line="$(grep -F "$id"$'\x1f' "$RETIRE_LOG" 2>/dev/null | head -1)"
  [ -n "$line" ] || return 1
  if [ -n "$want_force" ]; then
    [ "${line#*$'\x1f'}" = "$want_force" ]
  fi
}

# ===========================================================================
# Run 1: normal reap over the whole fixture.
# ===========================================================================
: > "$RETIRE_LOG"
run_reap
if [ "$CODE" -eq 0 ]; then
  pass "reap exits 0 when it successfully processes a mix of landed/unmerged/skipped worktrees"
else
  fail "reap should exit 0 for a normal run with some skips" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi

# --- tier a: true merge and fast-forward -----------------------------------
if retired merge-branch 0; then
  pass "tier a (true merge commit): merge-branch is retired without --force"
else
  fail "tier a (true merge commit): merge-branch should be retired without --force" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi
if retired ff-branch 0; then
  pass "tier a (fast-forward): ff-branch is retired without --force"
else
  fail "tier a (fast-forward): ff-branch should be retired without --force" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi

# --- tier b: rebased / cherry-picked ----------------------------------------
if retired rebased-branch 0; then
  pass "tier b (rebase/cherry-pick, patch-equivalent): rebased-branch is retired without --force"
else
  fail "tier b: rebased-branch should be retired (patch-equivalent via git cherry)" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi

# --- tier c: squash-merged multi-commit branch ------------------------------
if retired squash-branch 0; then
  pass "tier c (squash-merge): squash-branch IS retired, even though tier b alone (H3b) cannot catch it"
else
  fail "tier c (squash-merge): squash-branch should be retired via the combined-diff patch-id tier" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi

# --- negatives: must never be reaped ----------------------------------------
if ! retired unmerged-branch; then
  pass "SAFETY: a genuinely unmerged branch with unique work is never retired"
else
  fail "SAFETY VIOLATION: unmerged-branch must never be retired" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi
if printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'unmerged-branch'; then
  pass "reap reports why unmerged-branch was skipped (mentions it by name)"
else
  fail "reap should say why unmerged-branch was skipped" "stdout: $OUT
stderr: $ERR"
fi

if ! retired partial-branch; then
  pass "SAFETY: a partly-merged branch (one landed commit, one that never landed) is never retired"
else
  fail "SAFETY VIOLATION: partial-branch must never be retired — one of its commits never landed" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi

# --- dirty merged worktree: reap calls retire WITHOUT --force, retire's own
#     dirty check makes it survive, and reap reports it as skipped rather
#     than forcing it through. ------------------------------------------------
if retired dirty-merged-branch 0; then
  pass "dirty-merged-branch: reap calls retire-worktree.sh WITHOUT --force even though it is landed"
else
  fail "dirty-merged-branch: reap should still attempt retire without --force" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi
if [ -d "$WTROOT/dirty-merged-branch" ]; then
  pass "dirty-merged-branch: the dirty worktree survives (retire refused it, reap did not force)"
else
  fail "dirty-merged-branch: a dirty worktree must survive being reaped"
fi
if printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'dirty-merged-branch'; then
  pass "reap reports dirty-merged-branch as skipped (mentions it by name)"
else
  fail "reap should report dirty-merged-branch as skipped" "stdout: $OUT
stderr: $ERR"
fi

# --- enumeration exclusions --------------------------------------------------
if ! grep -qF 'trunk'$'\x1f' "$RETIRE_LOG" 2>/dev/null; then
  pass "the main checkout / base branch's own worktree is never retired"
else
  fail "the base branch's own worktree must be skipped" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi
if ! retired detached-wt; then
  pass "a detached-HEAD worktree is skipped regardless of whether its commit landed"
else
  fail "a detached-HEAD worktree must never be retired" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi
if ! retired outside-branch; then
  pass "a worktree outside WORKTREE_ROOT is skipped even though its branch landed"
else
  fail "a worktree outside WORKTREE_ROOT must never be retired" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi

# ===========================================================================
# Run 2: --dry-run over the SAME fixture — calls the retire script for
# NOTHING (the retire stub is inert; nothing was actually removed by Run 1,
# since the stub only logs and does not delete worktrees or branches, so the
# fixture is still fully intact here).
# ===========================================================================
: > "$RETIRE_LOG"
run_reap --dry-run
if [ "$CODE" -eq 0 ]; then
  pass "--dry-run exits 0"
else
  fail "--dry-run should exit 0" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ ! -s "$RETIRE_LOG" ]; then
  pass "--dry-run calls scripts/retire-worktree.sh for nothing at all"
else
  fail "--dry-run must not call retire-worktree.sh" "retire log:
$(cat "$RETIRE_LOG" 2>/dev/null)"
fi
if printf '%s' "$OUT" | grep -q 'merge-branch'; then
  pass "--dry-run prints what it would retire (mentions merge-branch)"
else
  fail "--dry-run should print the ids it would retire" "stdout: $OUT"
fi

# ===========================================================================
# Failed fetch: exits non-zero, reaps nothing. A separate, smaller fixture
# whose origin is deliberately broken (points at a path that no longer
# exists) — no network involved, purely a local path.
# ===========================================================================
FF_REMOTE="$SANDBOX_BASE/ff-remote.git"
FF_MAIN="$SANDBOX_BASE/ff-main"
FF_WTROOT="$SANDBOX_BASE/ff-worktrees"
mkdir -p "$FF_WTROOT"
{
  git init -q --bare "$FF_REMOTE"
  git clone -q "$FF_REMOTE" "$FF_MAIN"
  (cd "$FF_MAIN" && git checkout -q -b trunk && echo seed > seed.txt && git add seed.txt && git commit -q -m seed && git push -q -u origin trunk)
  git -C "$FF_MAIN" worktree add -q -b ff-fetch-branch "$FF_WTROOT/ff-fetch-branch" trunk
} >>"$FIXTURE_LOG" 2>&1
rm -rf "$FF_REMOTE"

mkdir -p "$FF_MAIN/scripts"
cp "$SCRIPT_SRC" "$FF_MAIN/scripts/reap-worktrees.sh" 2>/dev/null && chmod +x "$FF_MAIN/scripts/reap-worktrees.sh"
FF_RETIRE_LOG="$SANDBOX_BASE/ff-retire.log"
cat > "$FF_MAIN/scripts/retire-worktree.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$FF_RETIRE_LOG"
exit 0
EOF
chmod +x "$FF_MAIN/scripts/retire-worktree.sh"

outf="$(mktemp)"; errf="$(mktemp)"
( cd "$FF_MAIN" && MAIN_CHECKOUT="$FF_MAIN" PATH="$MINIMAL_PATH" WORKTREE_ROOT="$FF_WTROOT" BASE_BRANCH=trunk bash "$FF_MAIN/scripts/reap-worktrees.sh" ) >"$outf" 2>"$errf"
FF_CODE=$?
FF_OUT="$(cat "$outf")"; FF_ERR="$(cat "$errf")"; rm -f "$outf" "$errf"

if [ "$FF_CODE" -ne 0 ]; then
  pass "a failed fetch exits non-zero"
else
  fail "a failed fetch must exit non-zero" "got exit $FF_CODE
stdout: $FF_OUT
stderr: $FF_ERR"
fi
if [ ! -s "$FF_RETIRE_LOG" ]; then
  pass "a failed fetch reaps nothing at all"
else
  fail "a failed fetch must not retire anything" "retire log: $(cat "$FF_RETIRE_LOG" 2>/dev/null)"
fi
if printf '%s\n%s' "$FF_OUT" "$FF_ERR" | grep -qi fetch; then
  pass "a failed fetch prints an explanatory message mentioning the fetch"
else
  fail "expected an explanatory message about the failed fetch" "stdout: $FF_OUT
stderr: $FF_ERR"
fi

# ===========================================================================
# SAFETY DEFECT 1 (reap-worktrees.sh:87): a missing base ref makes tier b
# judge every branch landed.
#
# `git fetch $REMOTE $BASE_BRANCH` EXITS 0 without ever creating
# refs/remotes/$REMOTE/$BASE_BRANCH when the remote has no fetch refspec that
# matches it (a single-branch clone, a mirror, a hand-edited
# remote.origin.fetch). Tier a (`merge-base --is-ancestor`) then fails
# silently under `2>/dev/null`. Tier b's `! <git cherry ...> | grep -q '^+'`
# cannot tell "no unmerged commits" from "git errored and printed nothing" —
# `git cherry <bad-ref> <branch>` prints nothing on stdout, so the `!`
# inverts a `grep` "no match" into "landed", and EVERY worktree looks landed.
#
# Fixture: a normal remote + clone, then the origin fetch refspec is
# deliberately narrowed so it can never map $BASE_BRANCH, and the
# already-existing refs/remotes/origin/trunk (created by the initial push) is
# removed — reproducing "the remote has no matching fetch refspec" exactly.
# ===========================================================================
NR_REMOTE="$SANDBOX_BASE/nr-remote.git"
NR_MAIN="$SANDBOX_BASE/nr-main"
NR_WTROOT="$SANDBOX_BASE/nr-worktrees"
mkdir -p "$NR_WTROOT"
{
  git init -q --bare "$NR_REMOTE"
  git clone -q "$NR_REMOTE" "$NR_MAIN"
  (cd "$NR_MAIN" && git checkout -q -b trunk && echo seed > seed.txt && git add seed.txt && git commit -q -m seed && git push -q -u origin trunk)
  # Narrow the fetch refspec so it can never map refs/heads/trunk, then remove
  # the origin/trunk ref the initial push already created, so the "missing
  # ref" condition is real and not just theoretical.
  git -C "$NR_MAIN" config --unset-all remote.origin.fetch
  git -C "$NR_MAIN" config remote.origin.fetch '+refs/heads/nonexistent-*:refs/remotes/origin/nonexistent-*'
  git -C "$NR_MAIN" update-ref -d refs/remotes/origin/trunk
  git -C "$NR_MAIN" worktree add -q -b nr-unmerged-branch "$NR_WTROOT/nr-unmerged-branch" trunk
} >>"$FIXTURE_LOG" 2>&1
mk_commit "$NR_WTROOT/nr-unmerged-branch" unique.txt "never landed anywhere" "nr-unmerged-branch: unique work"

# H6: harness self-check — the trigger condition is real: fetch reports
# success, yet the remote-tracking ref genuinely does not exist afterward.
# If this fails, the fixture doesn't reproduce the defect and the assertions
# below would be meaningless.
if git -C "$NR_MAIN" fetch --quiet origin trunk >>"$FIXTURE_LOG" 2>&1; then
  pass "H6a: git fetch origin trunk exits 0 (the trigger condition: a fetch that reports success)"
else
  fail "H6a: expected the fetch itself to exit 0 for this fixture to reproduce the defect"
fi
if git -C "$NR_MAIN" rev-parse --verify -q refs/remotes/origin/trunk >/dev/null 2>&1; then
  fail "H6b: refs/remotes/origin/trunk must NOT exist after that fetch for this fixture to be valid" \
"it does exist — the fixture failed to reproduce a fetch with no matching refspec"
else
  pass "H6b: refs/remotes/origin/trunk genuinely does not exist after a successful-looking fetch"
fi

mkdir -p "$NR_MAIN/scripts"
cp "$SCRIPT_SRC" "$NR_MAIN/scripts/reap-worktrees.sh" 2>/dev/null && chmod +x "$NR_MAIN/scripts/reap-worktrees.sh"
NR_RETIRE_LOG="$SANDBOX_BASE/nr-retire.log"
cat > "$NR_MAIN/scripts/retire-worktree.sh" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$NR_RETIRE_LOG"
exit 0
EOF
chmod +x "$NR_MAIN/scripts/retire-worktree.sh"

outf="$(mktemp)"; errf="$(mktemp)"
( cd "$NR_MAIN" && MAIN_CHECKOUT="$NR_MAIN" PATH="$MINIMAL_PATH" WORKTREE_ROOT="$NR_WTROOT" BASE_BRANCH=trunk bash "$NR_MAIN/scripts/reap-worktrees.sh" ) >"$outf" 2>"$errf"
NR_CODE=$?
NR_OUT="$(cat "$outf")"; NR_ERR="$(cat "$errf")"; rm -f "$outf" "$errf"

if [ "$NR_CODE" -ne 0 ]; then
  pass "SAFETY: a missing base ref (refs/remotes/origin/trunk) makes reap exit non-zero"
else
  fail "SAFETY VIOLATION: reap must refuse to run when refs/remotes/origin/trunk does not exist after fetch" \
"got exit $NR_CODE
stdout: $NR_OUT
stderr: $NR_ERR"
fi
if [ ! -s "$NR_RETIRE_LOG" ]; then
  pass "SAFETY: a missing base ref means nothing at all gets retired"
else
  fail "SAFETY VIOLATION: nothing should be retired when the base ref is missing" \
"retire log:
$(cat "$NR_RETIRE_LOG" 2>/dev/null)"
fi
if printf '%s\n%s' "$NR_OUT" "$NR_ERR" | grep -qF 'origin/trunk'; then
  pass "reap names the missing ref (origin/trunk) in its explanation"
else
  fail "reap should name the missing ref it could not find" "stdout: $NR_OUT
stderr: $NR_ERR"
fi

# ===========================================================================
# SAFETY DEFECT 2 (reap-worktrees.sh:167,217 into retire-worktree.sh:132-133):
# the reaper vets one branch and deletes another.
#
# `process_worktree` decides landed-ness using the worktree's REAL checked-out
# branch (from `git worktree list --porcelain`), but then queues and retires
# `basename "$path"` as the id. retire-worktree.sh deletes `refs/heads/$id` —
# the directory name, not the vetted branch. If a worktree directory's name
# happens to collide with some OTHER, unrelated local branch name, that
# unrelated branch gets destroyed instead, regardless of its own merge state.
#
# This must run the REAL retire-worktree.sh (not the suite's usual stub): a
# stub can't observe a wrong branch actually being deleted.
#
# Fixture: worktree directory "358" has branch "feature-x" checked out
# (genuinely landed — merged and pushed to origin/trunk). A separate, unrelated
# local branch is ALSO literally named "358" and holds a commit that exists
# nowhere else in the repository (not merged, no live worktree of its own).
# ===========================================================================
WB_REMOTE="$SANDBOX_BASE/wb-remote.git"
WB_MAIN="$SANDBOX_BASE/wb-main"
WB_WTROOT="$SANDBOX_BASE/wb-worktrees"
WB_TMP_358="$SANDBOX_BASE/wb-tmp-358"
mkdir -p "$WB_WTROOT"
{
  git init -q --bare "$WB_REMOTE"
  git clone -q "$WB_REMOTE" "$WB_MAIN"
  (cd "$WB_MAIN" && git checkout -q -b trunk && echo seed > seed.txt && git add seed.txt && git commit -q -m seed && git push -q -u origin trunk)

  # The worktree DIRECTORY is named "358", but the branch actually checked
  # out inside it is "feature-x" — the dir/branch mismatch the old
  # new_fixture()/mk_worktree() helpers (which always do `worktree add -b
  # "$id" "$WTROOT/$id"`) cannot express.
  git -C "$WB_MAIN" branch feature-x trunk
  git -C "$WB_MAIN" worktree add -q "$WB_WTROOT/358" feature-x
} >>"$FIXTURE_LOG" 2>&1
mk_commit "$WB_WTROOT/358" fx.txt "feature-x content" "feature-x: real work"
{
  (cd "$WB_MAIN" && git checkout -q trunk && git merge -q --no-ff feature-x -m "merge feature-x" && git push -q origin trunk)

  # The unrelated branch, ALSO literally named "358", holding unique,
  # unmerged work. Built via a throwaway worktree elsewhere so the branch
  # survives with no live worktree of its own — this is the branch
  # retire-worktree.sh's `refs/heads/$id` lookup will wrongly match.
  git -C "$WB_MAIN" worktree add -q "$WB_TMP_358" -b 358 trunk
} >>"$FIXTURE_LOG" 2>&1
mk_commit "$WB_TMP_358" only-on-358.txt "unique 358 content" "358: unique unmerged work"
WB_358_SHA="$(git -C "$WB_MAIN" rev-parse 358)"
git -C "$WB_MAIN" worktree remove --force "$WB_TMP_358" >>"$FIXTURE_LOG" 2>&1

# H7: harness self-check — the mismatch and the collision are both real.
# SANDBOX_BASE is canonicalised once at startup (pwd -P), so WB_WTROOT/358
# already matches what `git worktree list --porcelain` reports; no per-call
# resolution needed.
if [ "$(git -C "$WB_MAIN" worktree list --porcelain | awk -v p="$WB_WTROOT/358" '$0=="worktree "p{f=1;next} f&&/^branch /{print $2;exit}')" = "refs/heads/feature-x" ]; then
  pass "H7a: the worktree directory named '358' really does have 'feature-x' checked out (a genuine dir/branch mismatch)"
else
  fail "H7a: expected the '358' worktree directory to have branch feature-x checked out"
fi
if git -C "$WB_MAIN" show-ref --quiet --verify refs/heads/358 && [ "$(git -C "$WB_MAIN" rev-parse 358)" = "$WB_358_SHA" ]; then
  pass "H7b: the unrelated branch '358' exists with its unique commit, and has no live worktree"
else
  fail "H7b: expected an unrelated branch '358' with its own unique commit"
fi
if git -C "$WB_MAIN" merge-base --is-ancestor feature-x origin/trunk; then
  pass "H7c: feature-x (checked out inside the '358' directory) has genuinely landed on origin/trunk"
else
  fail "H7c: expected feature-x to be an ancestor of origin/trunk (a genuine landed case)"
fi
if ! git -C "$WB_MAIN" merge-base --is-ancestor 358 origin/trunk 2>/dev/null; then
  pass "H7d: the unrelated branch '358' has genuinely NOT landed on origin/trunk"
else
  fail "H7d: the unrelated branch '358' must not be an ancestor of origin/trunk (it must be a real negative)"
fi

mkdir -p "$WB_MAIN/scripts"
cp "$SCRIPT_SRC" "$WB_MAIN/scripts/reap-worktrees.sh" 2>/dev/null && chmod +x "$WB_MAIN/scripts/reap-worktrees.sh"
cp "$RETIRE_SCRIPT_SRC" "$WB_MAIN/scripts/retire-worktree.sh" 2>/dev/null && chmod +x "$WB_MAIN/scripts/retire-worktree.sh"

outf="$(mktemp)"; errf="$(mktemp)"
( cd "$WB_MAIN" && MAIN_CHECKOUT="$WB_MAIN" PATH="$MINIMAL_PATH" WORKTREE_ROOT="$WB_WTROOT" BASE_BRANCH=trunk bash "$WB_MAIN/scripts/reap-worktrees.sh" ) >"$outf" 2>"$errf"
WB_CODE=$?
WB_OUT="$(cat "$outf")"; WB_ERR="$(cat "$errf")"; rm -f "$outf" "$errf"

if git -C "$WB_MAIN" show-ref --quiet --verify refs/heads/358 && [ "$(git -C "$WB_MAIN" rev-parse 358 2>/dev/null)" = "$WB_358_SHA" ]; then
  pass "SAFETY: retiring the '358' worktree (branch feature-x) leaves the UNRELATED branch '358' and its unique commit intact"
else
  fail "SAFETY VIOLATION: the reaper vetted feature-x but deleted the unrelated branch '358' instead" \
"exit $WB_CODE
stdout: $WB_OUT
stderr: $WB_ERR"
fi

# ===========================================================================
# Round-2 must-fix (reap-worktrees.sh:250-255, still standing): every
# non-zero exit from retire-worktree.sh is collapsed into one generic
# message, "retire-worktree.sh refused, likely a dirty worktree", and
# `any_skipped`/the per-id exit code never affect reap's own exit status —
# reap always exits 0 regardless of what retire reported.
#
# With retire's exit-code contract now down to 2 (dirty — a routine, expected
# skip) and 4 (failed `git worktree remove` — a HARD error: the checkout is
# still on disk, unregistered or not, and the caller must not treat that as
# an ordinary skip), reap must report the two differently, and a 4 must not
# pass silently: it needs to surface in reap's own exit status.
#
# Each fixture below has exactly one already-landed worktree; only the
# retire STUB's forced exit code differs between them, isolating reap's
# handling of the exit code from retire's own (separately tested) reasons
# for returning it.
# ===========================================================================
build_landed_fixture() {
  # build_landed_fixture <prefix> -> sets FX_MAIN, FX_WTROOT, FX_ID
  local prefix="$1"
  local remote="$SANDBOX_BASE/$prefix-remote.git"
  FX_MAIN="$SANDBOX_BASE/$prefix-main"
  FX_WTROOT="$SANDBOX_BASE/$prefix-worktrees"
  FX_ID="$prefix-branch"
  mkdir -p "$FX_WTROOT"
  {
    git init -q --bare "$remote"
    git clone -q "$remote" "$FX_MAIN"
    (cd "$FX_MAIN" && git checkout -q -b trunk && echo seed > seed.txt && git add seed.txt && git commit -q -m seed && git push -q -u origin trunk)
    git -C "$FX_MAIN" worktree add -q -b "$FX_ID" "$FX_WTROOT/$FX_ID" trunk
  } >>"$FIXTURE_LOG" 2>&1
  mk_commit "$FX_WTROOT/$FX_ID" work.txt "$prefix content" "$FX_ID commit"
  {
    cd "$FX_MAIN" && git checkout -q trunk && git merge -q --no-ff "$FX_ID" -m "merge $FX_ID" && git push -q origin trunk
  } >>"$FIXTURE_LOG" 2>&1
}

run_reap_with_forced_retire_exit() {
  # run_reap_with_forced_retire_exit <main> <wtroot> <id> <forced-exit-code>
  local main="$1" wtroot="$2" id="$3" code="$4"
  mkdir -p "$main/scripts"
  cp "$SCRIPT_SRC" "$main/scripts/reap-worktrees.sh" 2>/dev/null && chmod +x "$main/scripts/reap-worktrees.sh"
  cat > "$main/scripts/retire-worktree.sh" <<EOF
#!/usr/bin/env bash
exit $code
EOF
  chmod +x "$main/scripts/retire-worktree.sh"
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  ( cd "$main" && MAIN_CHECKOUT="$main" PATH="$MINIMAL_PATH" WORKTREE_ROOT="$wtroot" BASE_BRANCH=trunk bash "$main/scripts/reap-worktrees.sh" ) >"$outf" 2>"$errf"
  CODE=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"; rm -f "$outf" "$errf"
}

# --- exit 2 (dirty): a routine, expected skip -------------------------------
build_landed_fixture code2
run_reap_with_forced_retire_exit "$FX_MAIN" "$FX_WTROOT" "$FX_ID" 2
if [ "$CODE" -eq 0 ]; then
  pass "reap exit 0: a retire exit of 2 (dirty) is a routine skip, not a hard error"
else
  fail "a retire exit of 2 (dirty) must stay a non-fatal skip" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'dirty'; then
  pass "reap's message for exit 2 correctly names it as a dirty-worktree skip"
else
  fail "reap should describe a retire exit of 2 as a dirty worktree" "stdout: $OUT
stderr: $ERR"
fi
CODE2_MSG="$OUT"$'\n'"$ERR"

# --- exit 4 (failed removal): a hard error, must not pass silently ---------
build_landed_fixture code4
run_reap_with_forced_retire_exit "$FX_MAIN" "$FX_WTROOT" "$FX_ID" 4
if [ "$CODE" -ne 0 ]; then
  pass "SAFETY: reap exits non-zero when retire-worktree.sh reports exit 4 (failed removal) — it must not pass silently"
else
  fail "SAFETY VIOLATION: a retire exit of 4 (checkout still on disk after a failed removal) must not leave reap exiting 0" \
"got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if ! printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'dirty'; then
  pass "reap's message for exit 4 does NOT mischaracterize it as a dirty worktree"
else
  fail "reap must not describe a retire exit of 4 (failed removal) as 'likely a dirty worktree'" "stdout: $OUT
stderr: $ERR"
fi
CODE4_MSG="$OUT"$'\n'"$ERR"

if [ "$(printf '%s' "$CODE2_MSG" | sed "s/code2-branch/ID/g")" != "$(printf '%s' "$CODE4_MSG" | sed "s/code4-branch/ID/g")" ]; then
  pass "reap reports exit 2 and exit 4 with genuinely different messages, not one generic string for both"
else
  fail "reap must report exit 2 (dirty) and exit 4 (failed removal) distinctly, not with the same generic wording" \
"exit-2 message: $CODE2_MSG
exit-4 message: $CODE4_MSG"
fi

# ===========================================================================
# Non-blocking should-fix, closed rather than shipped: reap's retire-call
# `case` falls to a routine-skip branch for anything that isn't 0, 2 or 4.
# The codes that can actually land there are 1 (bad id / vanished path),
# 126/127 (retire script missing or not executable) and 128+N (killed by a
# signal). retire-worktree.sh never deletes a branch until `git worktree
# remove` has succeeded, so none of these lose work by themselves — but a
# retire killed mid-teardown (e.g. SIGTERM between the DDEV delete and the
# worktree removal, exit 143) is currently logged as a routine skip while
# reap exits 0. A silently-successful-looking reap after something actually
# went wrong is the exact failure mode this feature has now produced twice
# (defects 1 and the exit-4 case above).
#
# Contract to pin: 0 and 2 are routine (reap may exit 0); everything else,
# INCLUDING 4 and anything >= 126, is a hard error that forces a non-zero
# reap exit and must be reported as an error, not as a routine skip or as
# "dirty".
# ===========================================================================
assert_hard_error_code() {
  # assert_hard_error_code <code> <label>
  local code="$1" label="$2"
  build_landed_fixture "code$code"
  run_reap_with_forced_retire_exit "$FX_MAIN" "$FX_WTROOT" "$FX_ID" "$code"

  if [ "$CODE" -ne 0 ]; then
    pass "SAFETY: reap exits non-zero when retire-worktree.sh exits $code ($label) — it must not pass silently"
  else
    fail "SAFETY VIOLATION: a retire exit of $code ($label) must not leave reap exiting 0" \
"got exit $CODE
stdout: $OUT
stderr: $ERR"
  fi
  if ! printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'dirty'; then
    pass "reap's message for exit $code ($label) does NOT mischaracterize it as a dirty worktree"
  else
    fail "reap must not describe a retire exit of $code ($label) as 'likely a dirty worktree'" "stdout: $OUT
stderr: $ERR"
  fi
  if printf '%s\n%s' "$OUT" "$ERR" | grep -qiE 'error|fail|unexpected|abnormal'; then
    pass "reap's message for exit $code ($label) is reported as an error, not a routine skip"
  else
    fail "reap must report exit $code ($label) as an error, not with routine-skip wording" "stdout: $OUT
stderr: $ERR"
  fi
}

# 127: the sibling retire-worktree.sh is missing or not executable.
assert_hard_error_code 127 "retire script missing/not executable"

# 143: killed mid-teardown (SIGTERM, 128+15). retire-worktree.sh never
# deletes a branch before `git worktree remove` succeeds, so this cannot by
# itself destroy work — but it must not be reported as if nothing happened.
assert_hard_error_code 143 "killed mid-teardown (SIGTERM)"

# REGRESSION GUARD: 2 stays the only non-zero code reap may still treat as
# routine — re-run it fresh (a new fixture, not the CODE2_MSG captured
# earlier) to confirm adding the 127/143 handling above hasn't widened the
# "hard error" net to also catch exit 2.
build_landed_fixture code2-again
run_reap_with_forced_retire_exit "$FX_MAIN" "$FX_WTROOT" "$FX_ID" 2
if [ "$CODE" -eq 0 ]; then
  pass "REGRESSION GUARD: exit 2 (dirty) still leaves reap exiting 0 after adding the >=126 / signal handling"
else
  fail "REGRESSION GUARD: exit 2 (dirty) must remain routine — it must not have been swept into the new hard-error handling" \
"got exit $CODE
stdout: $OUT
stderr: $ERR"
fi

# ===========================================================================
# RE. Default layout: WORKTREE_ROOT defaults to <project root>/code, which
#     also holds the main checkout. Run from the project root with only
#     BASE_BRANCH in .orch: the landed worktree is reaped, the main checkout
#     is never touched.
# ===========================================================================
RE_REMOTE_DIR="$SANDBOX_BASE/re-remote.git"
RE_PROJECTS="$SANDBOX_BASE/re-projects"
RE_ROOT="$RE_PROJECTS/re"
RE_WTROOT="$RE_ROOT/code"
RE_MAIN="$RE_WTROOT/some-other-checkout"
mkdir -p "$RE_WTROOT"
printf 'BASE_BRANCH=trunk\n' > "$RE_ROOT/.orch"

git init -q --bare "$RE_REMOTE_DIR" >/dev/null 2>&1
git clone -q "$RE_REMOTE_DIR" "$RE_MAIN" >/dev/null 2>&1
(
  cd "$RE_MAIN"
  git checkout -q -b trunk
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
  git push -q -u origin trunk
) >/dev/null 2>&1

git -C "$RE_MAIN" worktree add -q -b re-landed "$RE_WTROOT/re-landed" trunk >/dev/null 2>&1
mk_commit "$RE_WTROOT/re-landed" re.txt "re content" "re-landed commit"
(cd "$RE_MAIN" && git checkout -q trunk && git merge -q --no-ff re-landed -m "merge re-landed" && git push -q origin trunk) >/dev/null 2>&1

cp "$SCRIPT_SRC" "$RE_MAIN/scripts/reap-worktrees.sh" 2>/dev/null || mkdir -p "$RE_MAIN/scripts" 2>/dev/null
cp "$SCRIPT_SRC" "$RE_MAIN/scripts/reap-worktrees.sh" 2>/dev/null && chmod +x "$RE_MAIN/scripts/reap-worktrees.sh"
cp "$RETIRE_SCRIPT_SRC" "$RE_MAIN/scripts/retire-worktree.sh" 2>/dev/null && chmod +x "$RE_MAIN/scripts/retire-worktree.sh"

re_outf="$(mktemp)"; re_errf="$(mktemp)"
( cd "$RE_ROOT" && ORCH_PROJECTS_DIR="$RE_PROJECTS" PATH="$MINIMAL_PATH" \
    bash "$RE_MAIN/scripts/reap-worktrees.sh" ) >"$re_outf" 2>"$re_errf"
re_rc=$?

if [ "$re_rc" -eq 0 ] && [ ! -e "$RE_WTROOT/re-landed" ] && [ -d "$RE_MAIN/.git" ]; then
  pass "RE1: in the default layout a landed worktree in <root>/code is reaped and the main checkout beside it is kept"
else
  fail "RE1: default layout must reap <root>/code/re-landed and keep the main checkout" \
"exit $re_rc
stdout: $(cat "$re_outf")
stderr: $(cat "$re_errf")"
fi
rm -f "$re_outf" "$re_errf"

# ===========================================================================
# RB: BASE_BRANCH unresolvable anywhere (no env, no .env) -> refuse, exit
#     non-zero, reap nothing. Every other case in this suite passes
#     BASE_BRANCH=trunk explicitly, so this refusal path was previously
#     untested (review round 1, must-fix 1: the engine used to default this
#     to a bare "trunk" literal instead of refusing).
# ===========================================================================
RB_REMOTE_DIR="$SANDBOX_BASE/rb-remote.git"
RB_ROOT="$SANDBOX_BASE/rb"
RB_MAIN="$RB_ROOT/main"
RB_WTROOT="$RB_ROOT/worktrees"
mkdir -p "$RB_ROOT"

git init -q --bare "$RB_REMOTE_DIR" >/dev/null 2>&1
git clone -q "$RB_REMOTE_DIR" "$RB_MAIN" >/dev/null 2>&1
(
  cd "$RB_MAIN"
  git checkout -q -b trunk
  echo seed > seed.txt
  git add seed.txt
  git commit -q -m seed
  git push -q -u origin trunk
) >/dev/null 2>&1

mkdir -p "$RB_WTROOT"
git -C "$RB_MAIN" worktree add -q -b rb-landed "$RB_WTROOT/rb-landed" trunk >/dev/null 2>&1
mk_commit "$RB_WTROOT/rb-landed" rb.txt "rb content" "rb-landed commit"
(cd "$RB_MAIN" && git checkout -q trunk && git merge -q --no-ff rb-landed -m "merge rb-landed" && git push -q origin trunk) >/dev/null 2>&1

mkdir -p "$RB_MAIN/scripts"
cp "$SCRIPT_SRC" "$RB_MAIN/scripts/reap-worktrees.sh" && chmod +x "$RB_MAIN/scripts/reap-worktrees.sh"
cp "$RETIRE_SCRIPT_SRC" "$RB_MAIN/scripts/retire-worktree.sh" && chmod +x "$RB_MAIN/scripts/retire-worktree.sh"
# Deliberately no .env in $RB_MAIN.

rb_outf="$(mktemp)"; rb_errf="$(mktemp)"
( cd "$RB_MAIN" && env -u BASE_BRANCH MAIN_CHECKOUT="$RB_MAIN" PATH="$MINIMAL_PATH" WORKTREE_ROOT="$RB_WTROOT" \
    bash "$RB_MAIN/scripts/reap-worktrees.sh" ) >"$rb_outf" 2>"$rb_errf"
rb_rc=$?

if [ "$rb_rc" -ne 0 ]; then
  pass "RB1: an unresolvable BASE_BRANCH (no env, no .env) refuses with a non-zero exit"
else
  fail "RB1: an unresolvable BASE_BRANCH must refuse (non-zero exit), not fall back to a literal 'trunk'" "exit $rb_rc"
fi

if [ -e "$RB_WTROOT/rb-landed" ]; then
  pass "RB2: an unresolvable BASE_BRANCH reaps nothing (the landed worktree survives)"
else
  fail "RB2: an unresolvable BASE_BRANCH must reap nothing" "$RB_WTROOT/rb-landed is gone"
fi

if grep -qiF 'BASE_BRANCH' "$rb_errf" 2>/dev/null; then
  pass "RB3: the refusal names BASE_BRANCH on stderr"
else
  fail "RB3: expected the refusal to name BASE_BRANCH" "$(cat "$rb_errf")"
fi
rm -f "$rb_outf" "$rb_errf"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
