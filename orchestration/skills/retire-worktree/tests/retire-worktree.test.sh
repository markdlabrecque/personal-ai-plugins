#!/usr/bin/env bash
#
# Ticket: worktree teardown — scripts/retire-worktree.sh <id> [--force] [--ddev-only]
#
# Spec under test (see .claude/skills/retire-worktree/SKILL.md for the manual
# procedure this script must automate):
#
#   WORKTREE_ROOT env, default $HOME/Projects/worktrees/acme-site.
#   worktree = $WORKTREE_ROOT/<id>. Run from anywhere inside the main
#   checkout; main repo = `git rev-parse --show-toplevel`.
#
#   1. Refuses (exit 1, nothing touched) when: no <id>; worktree path does not
#      exist; or the resolved path is not under $WORKTREE_ROOT.
#   2. Dirty check via `git -C <worktree> status --porcelain`. Non-empty and
#      no --force -> full list to stderr, exit 2, nothing touched. --force
#      proceeds.
#   3. Close the Herdr workspace BEFORE removing the worktree. Look it up via
#      `herdr worktree list` (.result.worktrees[] | select(.path==<worktree>)
#      | .open_workspace_id), fall back to `herdr workspace list` matching
#      .worktree.checkout_path, then `herdr workspace close <id>`. No herdr on
#      PATH, or no workspace found -> say so on stdout, carry on.
#   4. `ddev delete -yO` from inside the worktree. No ddev on PATH or no
#      .ddev dir -> say so, carry on.
#   5. From the main checkout: `git worktree remove --force <worktree>` then
#      `git branch -D <id>` (only when that branch exists).
#   6. Final report naming workspace id, DDEV project name, path, branch —
#      explicit when there was no workspace to close.
#
#   Steps 3 and 4 are best-effort: a herdr/ddev failure warns on stderr but
#   must not abort the git teardown.
#   Step 3 is always the engine's own; a resolved RETIRE_HOOK replaces only
#   step 4.
#
#   --ddev-only skips step 3 entirely (never calls herdr), runs step 4, and
#   stops (exit 0), leaving worktree and branch.
#
# Harness rationale — hermetic, no network, no real DDEV, no herdr server, no
# real worktrees of this repo:
#   * Every fixture is a throwaway git repo built under mktemp -d.
#   * `herdr` and `ddev` are stub scripts on a *minimal, curated* PATH built
#     from `command -v` of only the binaries this harness genuinely needs
#     (git, bash, jq, coreutils). This is deliberate, not just tidy: it is
#     the only way to guarantee a real herdr/ddev installed on the developer
#     machine is never invoked, even by accident, regardless of host state.
#   * The stub logs its argv, one call per line, with \x1f between args, so
#     assertions compare exact argument values rather than sniffing output.
#   * We run a COPY of the script under test so nothing ever touches the
#     developer's real checkout, branches, or worktree registrations.
#
# Run from the repo root:
#   bash tests/repo/retire-worktree.test.sh
#
# Requires: bash 4+, git, jq. Exit 0 = green.

set -uo pipefail

# Derived from BASH_SOURCE, not `git rev-parse --show-toplevel` -- this suite
# must run from any cwd and must not require a git repo.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_SRC="$SKILL_DIR/scripts/retire-worktree.sh"

# Strip a trailing slash from TMPDIR (macOS's default TMPDIR ends in one)
# before appending our own -- otherwise the resulting SANDBOX_BASE contains a
# literal double slash that `cd`/git normalize away in some code paths (e.g.
# git worktree list --porcelain, or a hook's $PWD after `cd`) but not in the
# raw path strings this harness builds and greps for elsewhere, producing
# spurious path mismatches unrelated to the behaviour under test.
_TMPDIR_NOSLASH="${TMPDIR:-/tmp}"
_TMPDIR_NOSLASH="${_TMPDIR_NOSLASH%/}"
SANDBOX_BASE="$(cd "$(mktemp -d "$_TMPDIR_NOSLASH/ih-retire-XXXXXX")" && pwd -P)"
trap 'chmod -R u+rwx "$SANDBOX_BASE" 2>/dev/null; rm -rf "$SANDBOX_BASE"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Each fixture root is a project root under ORCH_PROJECTS_DIR. The engine runs
# from a copy, so point it at the real resolver.
export ORCH_PROJECTS_DIR="$SANDBOX_BASE"
export ORCH_PROJECT_LIB="$(cd "$SKILL_DIR/../.." && pwd -P)/scripts/orch-project.sh"
unset PROJECT_NAME MAIN_CHECKOUT RETIRE_HOOK BASE_BRANCH

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

# ---------------------------------------------------------------------------
# A COPY of the script under test. If it does not exist yet, invocations
# below fail because the copy is missing (exit 127, "No such file"), which is
# the correct red: the behaviour under test does not exist.
# ---------------------------------------------------------------------------
SCRIPT_COPY="$SANDBOX_BASE/retire-worktree.sh"
cp "$SCRIPT_SRC" "$SCRIPT_COPY" 2>/dev/null && chmod +x "$SCRIPT_COPY"
if [ ! -x "$SCRIPT_COPY" ]; then
  note "scripts/retire-worktree.sh does not exist yet — every case below is expected to fail red for that reason."
fi

# ---------------------------------------------------------------------------
# A minimal, curated PATH containing only what this harness truly needs, so a
# real herdr/ddev on the developer machine is never reachable unless we
# deliberately add our stub bin dir in front of it.
# ---------------------------------------------------------------------------
declare -A _dirs=()
for b in git bash jq mkdir cat mktemp rm sed grep awk tr dirname basename \
         realpath cut sort uniq wc cmp diff xargs sha1sum true false env \
         printf mv cp chmod pwd; do
  p="$(command -v "$b" 2>/dev/null)" || continue
  _dirs["$(dirname "$p")"]=1
done
MINIMAL_PATH=""
for d in "${!_dirs[@]}"; do
  MINIMAL_PATH="${MINIMAL_PATH:+$MINIMAL_PATH:}$d"
done

# ---------------------------------------------------------------------------
# Stub herdr / ddev. Behaviour is entirely env-var driven so one stub binary
# serves every scenario.
# ---------------------------------------------------------------------------
STUB_BIN="$SANDBOX_BASE/stubbin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
{
  first=1
  for a in "$@"; do
    if [ "$first" = 1 ]; then printf '%s' "$a"; first=0; else printf '\x1f%s' "$a"; fi
  done
  printf '\n'
} >> "${HERDR_LOG:?HERDR_LOG not set}"

if [ "${1:-}" = "worktree" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${HERDR_WORKTREE_LIST_JSON:-{\"result\":{\"worktrees\":[]}}}"
  exit "${HERDR_WORKTREE_LIST_EXIT:-0}"
fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${HERDR_WORKSPACE_LIST_JSON:-{\"result\":{\"workspaces\":[]}}}"
  exit "${HERDR_WORKSPACE_LIST_EXIT:-0}"
fi
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "close" ]; then
  if [ -n "${HERDR_CLOSE_ORDER_LOG:-}" ]; then
    if [ -n "${HERDR_CLOSE_EXISTS_CHECK:-}" ] && [ -d "$HERDR_CLOSE_EXISTS_CHECK" ]; then
      echo "exists" >> "$HERDR_CLOSE_ORDER_LOG"
    else
      echo "gone" >> "$HERDR_CLOSE_ORDER_LOG"
    fi
  fi
  [ -n "${COMBINED_ORDER_LOG:-}" ] && echo "herdr-close" >> "$COMBINED_ORDER_LOG"
  exit "${HERDR_WORKSPACE_CLOSE_EXIT:-0}"
fi
exit 0
EOF
chmod +x "$STUB_BIN/herdr"

cat > "$STUB_BIN/ddev" <<'EOF'
#!/usr/bin/env bash
{
  first=1
  for a in "$@"; do
    if [ "$first" = 1 ]; then printf '%s' "$a"; first=0; else printf '\x1f%s' "$a"; fi
  done
  printf '\n'
} >> "${DDEV_LOG:?DDEV_LOG not set}"
[ -n "${DDEV_CWD_LOG:-}" ] && pwd >> "$DDEV_CWD_LOG"
if [ "${1:-}" = "delete" ] && [ -n "${COMBINED_ORDER_LOG:-}" ]; then
  echo "ddev-delete" >> "$COMBINED_ORDER_LOG"
fi
exit "${DDEV_EXIT:-0}"
EOF
chmod +x "$STUB_BIN/ddev"

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------
FIXN=0
new_fixture() {
  FIXN=$((FIXN + 1))
  local root="$SANDBOX_BASE/fx$FIXN"
  mkdir -p "$root"
  MAIN="$root/acme-site"
  WTROOT="$root/worktrees"
  mkdir -p "$WTROOT"
  git init -q "$MAIN"
  printf 'PROJECT_NAME=acme-site\nMAIN_CHECKOUT=acme-site\n' > "$root/.orch"
  # Matches the real repo's .gitignore (.ddev/config.local.yaml is ignored
  # there — see .gitignore's "DDEV per-worktree project name" entry), so the
  # fixture's dirty check reflects the same reality a real worktree would:
  # add_ddev_dir()'s file must never itself make a worktree look dirty.
  printf '.ddev/config.local.yaml\n' > "$MAIN/.gitignore"
  (cd "$MAIN" && git checkout -q -b trunk && git add .gitignore && echo seed > seed.txt && git add seed.txt && git commit -q -m seed)
}

add_worktree() {
  # add_worktree <id> [--dirty] [--no-ddev-dir(default)]
  local id="$1"
  git -C "$MAIN" worktree add -q -b "$id" "$WTROOT/$id" trunk >/dev/null
  if [ "${2:-}" = "--dirty" ]; then
    echo "uncommitted change" >> "$WTROOT/$id/seed.txt"
  fi
}

# derive_ddev_name <id> -> expected DDEV project name (Identifier A, ticket
# #393). Restated rule: sanitize the id (lowercase, non-`a-z0-9-` to `-`,
# collapse runs, strip leading/trailing `-`); if the leading segment is all
# digits, the WHOLE digit run (no width cap, no padding) is the DDEV name;
# otherwise cap at the first 3 hyphen-separated segments. Append
# `-acme-site`. Must stay identical to scripts/setup-worktree.sh's and
# scripts/retire-worktree.sh's copies -- see tests/repo/setup-worktree-agent.
# test.sh sections O/P/Q for the full spec this pins the other half of.
derive_ddev_name() {
  local raw="$1" lower sanitized first capped i
  lower="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  sanitized="$(printf '%s' "$lower" | LC_ALL=C sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-//; s/-$//')"
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
  [ -z "$capped" ] && capped="worktree"
  printf '%s-acme-site' "$capped"
}

add_ddev_dir() {
  # add_ddev_dir <id> [<explicit-name>]
  #
  # Writes the name a REAL setup-worktree.sh run would have written for this
  # id: the derived/capped name, not a naive `$id-acme-site`. An explicit
  # second argument overrides that, for fixtures that deliberately simulate a
  # worktree provisioned under a DIFFERENT rule (e.g. a pre-#393 name) than
  # the one retire-worktree.sh would derive fresh.
  local id="$1" name="${2:-}"
  [ -z "$name" ] && name="$(derive_ddev_name "$id")"
  mkdir -p "$WTROOT/$id/.ddev"
  printf 'name: %s\n' "$name" > "$WTROOT/$id/.ddev/config.local.yaml"
}

# run_retire <main> <wtroot> <path-for-invoke-path: full|no-herdr|no-ddev|bare> [extra env assignments already exported] -- args
OUT=""
ERR=""
CODE=0
run_retire() {
  local main="$1" wtroot="$2" pathmode="$3"; shift 3
  local invoke_path
  case "$pathmode" in
    full) invoke_path="$STUB_BIN:$MINIMAL_PATH" ;;
    bare) invoke_path="$MINIMAL_PATH" ;;
    *) invoke_path="$MINIMAL_PATH" ;;
  esac
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  ( cd "$main" && PATH="$invoke_path" WORKTREE_ROOT="$wtroot" bash "$SCRIPT_COPY" "$@" ) >"$outf" 2>"$errf"
  CODE=$?
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

worktree_still_listed() {
  # SANDBOX_BASE is canonical (resolved once at startup via `pwd -P`), so
  # every wtpath built from it already matches what `git worktree list
  # --porcelain` reports -- no per-call resolution needed.
  # An exact-line match against the porcelain output avoids substring false
  # positives (e.g. "rd5" matching "rd50").
  local main="$1" wtpath="$2"
  git -C "$main" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wtpath"
}

branch_exists() {
  git -C "$1" show-ref --quiet --verify "refs/heads/$2"
}

# ===========================================================================
# R1: no id given -> refuses, exit 1, nothing touched.
# ===========================================================================
new_fixture
export HERDR_LOG="$SANDBOX_BASE/r1-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r1-ddev.log"
run_retire "$MAIN" "$WTROOT" full
if [ "$CODE" -eq 1 ]; then
  pass "R1a: no <id> given exits 1"
else
  fail "R1a: no <id> given must exit 1" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ ! -s "$HERDR_LOG" ] && [ ! -s "$DDEV_LOG" ]; then
  pass "R1b: no <id> given touches neither herdr nor ddev"
else
  fail "R1b: no <id> given must not call herdr/ddev" "herdr log: $(cat "$HERDR_LOG" 2>/dev/null)
ddev log: $(cat "$DDEV_LOG" 2>/dev/null)"
fi

# ===========================================================================
# R2: worktree path does not exist -> refuses, exit 1.
# ===========================================================================
new_fixture
export HERDR_LOG="$SANDBOX_BASE/r2-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r2-ddev.log"
run_retire "$MAIN" "$WTROOT" full ghost
if [ "$CODE" -eq 1 ]; then
  pass "R2a: nonexistent worktree path exits 1"
else
  fail "R2a: nonexistent worktree path must exit 1" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ ! -s "$HERDR_LOG" ] && [ ! -s "$DDEV_LOG" ]; then
  pass "R2b: nonexistent worktree path touches neither herdr nor ddev"
else
  fail "R2b: nonexistent worktree path must not call herdr/ddev" "herdr: $(cat "$HERDR_LOG" 2>/dev/null); ddev: $(cat "$DDEV_LOG" 2>/dev/null)"
fi

# ===========================================================================
# R3: resolved path escapes WORKTREE_ROOT -> refuses, exit 1, main untouched.
#   R3a: id=".." (WORKTREE_ROOT/.. is the fixture root, a real directory, but
#        not under WORKTREE_ROOT).
#   R3b: id="escape" where WORKTREE_ROOT/escape is a SYMLINK resolving
#        outside WORKTREE_ROOT — proves the guard resolves real paths, not
#        just string prefixes.
# ===========================================================================
new_fixture
mkdir -p "$SANDBOX_BASE/fx$FIXN/elsewhere"
run_retire "$MAIN" "$WTROOT" full ".."
if [ "$CODE" -eq 1 ]; then
  pass "R3a: id='..' escaping WORKTREE_ROOT via '..' is refused (exit 1)"
else
  fail "R3a: id='..' must be refused" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if git -C "$MAIN" rev-parse HEAD >/dev/null 2>&1 && [ "$(git -C "$MAIN" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse trunk)" ]; then
  pass "R3a-untouched: the main checkout is unharmed after the refusal"
else
  fail "R3a-untouched: the main checkout should be untouched" "git state looks different after the refusal"
fi

new_fixture
ln -s "$SANDBOX_BASE/fx$FIXN" "$WTROOT/escape"
run_retire "$MAIN" "$WTROOT" full escape
if [ "$CODE" -eq 1 ]; then
  pass "R3b: a symlink under WORKTREE_ROOT resolving outside it is refused (exit 1)"
else
  fail "R3b: symlink escape must be refused" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi

# ===========================================================================
# R4: dirty worktree, no --force -> exit 2, full list on stderr, nothing
#     touched (no herdr, no ddev, worktree still registered).
# ===========================================================================
new_fixture
add_worktree beta --dirty
export HERDR_LOG="$SANDBOX_BASE/r4-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r4-ddev.log"
run_retire "$MAIN" "$WTROOT" full beta
if [ "$CODE" -eq 2 ]; then
  pass "R4a: dirty worktree without --force exits 2"
else
  fail "R4a: dirty worktree without --force must exit 2" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if printf '%s' "$ERR" | grep -q 'seed.txt'; then
  pass "R4b: the dirty file list is printed on stderr"
else
  fail "R4b: stderr must list the dirty file(s)" "stderr: $ERR"
fi
if [ ! -s "$HERDR_LOG" ] && [ ! -s "$DDEV_LOG" ]; then
  pass "R4c: a refused dirty retire calls neither herdr nor ddev"
else
  fail "R4c: must not call herdr/ddev before the dirty check passes" "herdr: $(cat "$HERDR_LOG" 2>/dev/null); ddev: $(cat "$DDEV_LOG" 2>/dev/null)"
fi
if worktree_still_listed "$MAIN" "$WTROOT/beta"; then
  pass "R4d: the worktree is not removed"
else
  fail "R4d: the worktree must survive a refused dirty retire" "git worktree list: $(git -C "$MAIN" worktree list)"
fi

# ===========================================================================
# R5: dirty worktree WITH --force -> proceeds to a full, successful teardown.
# ===========================================================================
new_fixture
add_worktree gamma --dirty
export HERDR_LOG="$SANDBOX_BASE/r5-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r5-ddev.log"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/gamma" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-r5"}]}}')"
export HERDR_WORKTREE_LIST_JSON
run_retire "$MAIN" "$WTROOT" full gamma --force
if [ "$CODE" -eq 0 ]; then
  pass "R5a: --force proceeds past a dirty worktree (exit 0)"
else
  fail "R5a: --force must let a dirty worktree through" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if ! worktree_still_listed "$MAIN" "$WTROOT/gamma"; then
  pass "R5b: the worktree is removed under --force"
else
  fail "R5b: the worktree should be removed" "git worktree list: $(git -C "$MAIN" worktree list)"
fi
if ! branch_exists "$MAIN" gamma; then
  pass "R5c: the branch is deleted under --force"
else
  fail "R5c: branch 'gamma' should be deleted"
fi
unset HERDR_WORKTREE_LIST_JSON

# ===========================================================================
# R6: herdr workspace found via `herdr worktree list` -> closed BEFORE the
#     worktree is removed from disk.
# ===========================================================================
new_fixture
add_worktree delta
export HERDR_LOG="$SANDBOX_BASE/r6-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r6-ddev.log"
ORDER_LOG="$SANDBOX_BASE/r6-order.log"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/delta" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-delta-42"}]}}')"
export HERDR_WORKTREE_LIST_JSON HERDR_CLOSE_ORDER_LOG="$ORDER_LOG" HERDR_CLOSE_EXISTS_CHECK="$WTROOT/delta"
run_retire "$MAIN" "$WTROOT" full delta
if grep -qF $'workspace\x1fclose\x1fws-delta-42' "$HERDR_LOG" 2>/dev/null; then
  pass "R6a: herdr workspace close is called with the id from herdr worktree list"
else
  fail "R6a: expected 'herdr workspace close ws-delta-42'" "herdr log:
$(cat "$HERDR_LOG" 2>/dev/null)"
fi
if grep -qx 'exists' "$ORDER_LOG" 2>/dev/null; then
  pass "R6b: the herdr workspace is closed BEFORE the worktree is removed from disk"
else
  fail "R6b: herdr workspace close must happen while the worktree still exists" "order log: $(cat "$ORDER_LOG" 2>/dev/null)"
fi
unset HERDR_WORKTREE_LIST_JSON HERDR_CLOSE_ORDER_LOG HERDR_CLOSE_EXISTS_CHECK

# ===========================================================================
# R7: fallback to `herdr workspace list` when `herdr worktree list` has no
#     match, matching on .worktree.checkout_path.
# ===========================================================================
new_fixture
add_worktree epsilon
export HERDR_LOG="$SANDBOX_BASE/r7-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r7-ddev.log"
HERDR_WORKTREE_LIST_JSON='{"result":{"worktrees":[]}}'
HERDR_WORKSPACE_LIST_JSON="$(jq -n --arg p "$WTROOT/epsilon" '{result:{workspaces:[{workspace_id:"ws-fallback-9", worktree:{checkout_path:$p}}]}}')"
export HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_LIST_JSON
run_retire "$MAIN" "$WTROOT" full epsilon
if grep -qF $'workspace\x1fclose\x1fws-fallback-9' "$HERDR_LOG" 2>/dev/null; then
  pass "R7a: falls back to herdr workspace list and closes the matched id"
else
  fail "R7a: expected fallback close of ws-fallback-9" "herdr log:
$(cat "$HERDR_LOG" 2>/dev/null)"
fi
wt_line=$(grep -nF $'worktree\x1flist' "$HERDR_LOG" | head -1 | cut -d: -f1)
ws_line=$(grep -nF $'workspace\x1flist' "$HERDR_LOG" | head -1 | cut -d: -f1)
if [ -n "$wt_line" ] && [ -n "$ws_line" ] && [ "$wt_line" -lt "$ws_line" ]; then
  pass "R7b: herdr worktree list is tried before herdr workspace list"
else
  fail "R7b: expected 'worktree list' to precede 'workspace list'" "herdr log:
$(cat "$HERDR_LOG" 2>/dev/null)"
fi
unset HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_LIST_JSON

# ===========================================================================
# R8: no match anywhere -> no close call, said so on stdout, teardown
#     still completes.
# ===========================================================================
new_fixture
add_worktree zeta
export HERDR_LOG="$SANDBOX_BASE/r8-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r8-ddev.log"
HERDR_WORKTREE_LIST_JSON='{"result":{"worktrees":[]}}'
HERDR_WORKSPACE_LIST_JSON='{"result":{"workspaces":[]}}'
export HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_LIST_JSON
run_retire "$MAIN" "$WTROOT" full zeta
if ! grep -qF $'workspace\x1fclose' "$HERDR_LOG" 2>/dev/null; then
  pass "R8a: no workspace close call when nothing matches"
else
  fail "R8a: must not call workspace close with no match" "herdr log: $(cat "$HERDR_LOG" 2>/dev/null)"
fi
if printf '%s' "$OUT" | grep -qi 'no.*workspace'; then
  pass "R8b: stdout explicitly reports there was no workspace to close"
else
  fail "R8b: expected stdout to mention no workspace found/closed" "stdout: $OUT"
fi
if [ "$CODE" -eq 0 ] && ! worktree_still_listed "$MAIN" "$WTROOT/zeta"; then
  pass "R8c: git teardown still completes with no matching workspace"
else
  fail "R8c: teardown should still succeed" "exit $CODE; worktree list: $(git -C "$MAIN" worktree list)"
fi
unset HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_LIST_JSON

# ===========================================================================
# R9: herdr not on PATH at all -> says so on stdout, teardown still
#     completes, no herdr log is ever created (real herdr, if present on the
#     host, must never be reachable here).
# ===========================================================================
new_fixture
add_worktree eta
export HERDR_LOG="$SANDBOX_BASE/r9-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r9-ddev.log"
outf="$(mktemp)"; errf="$(mktemp)"
( cd "$MAIN" && PATH="$MINIMAL_PATH" WORKTREE_ROOT="$WTROOT" bash "$SCRIPT_COPY" eta ) >"$outf" 2>"$errf"
CODE=$?
OUT="$(cat "$outf")"; ERR="$(cat "$errf")"; rm -f "$outf" "$errf"
if [ ! -e "$HERDR_LOG" ]; then
  pass "R9a: no herdr on PATH — herdr is never invoked"
else
  fail "R9a: herdr must not be invoked when absent from PATH" "log: $(cat "$HERDR_LOG")"
fi
if printf '%s' "$OUT" | grep -qi herdr; then
  pass "R9b: stdout notes herdr is unavailable"
else
  fail "R9b: expected stdout to mention herdr being unavailable" "stdout: $OUT"
fi
if [ "$CODE" -eq 0 ] && ! worktree_still_listed "$MAIN" "$WTROOT/eta"; then
  pass "R9c: git teardown still completes without herdr"
else
  fail "R9c: teardown should still succeed without herdr" "exit $CODE"
fi

# ===========================================================================
# R10: ddev not on PATH -> says so, teardown still completes, no ddev log.
# ===========================================================================
new_fixture
add_worktree theta
add_ddev_dir theta
export DDEV_LOG="$SANDBOX_BASE/r10-ddev.log"
export HERDR_LOG="$SANDBOX_BASE/r10-herdr.log"
outf="$(mktemp)"; errf="$(mktemp)"
( cd "$MAIN" && PATH="$MINIMAL_PATH" WORKTREE_ROOT="$WTROOT" bash "$SCRIPT_COPY" theta ) >"$outf" 2>"$errf"
CODE=$?
OUT="$(cat "$outf")"; ERR="$(cat "$errf")"; rm -f "$outf" "$errf"
if [ ! -e "$DDEV_LOG" ]; then
  pass "R10a: no ddev on PATH — ddev is never invoked"
else
  fail "R10a: ddev must not be invoked when absent from PATH" "log: $(cat "$DDEV_LOG")"
fi
if printf '%s' "$OUT" | grep -qi ddev; then
  pass "R10b: stdout notes ddev is unavailable"
else
  fail "R10b: expected stdout to mention ddev being unavailable" "stdout: $OUT"
fi
if [ "$CODE" -eq 0 ] && ! worktree_still_listed "$MAIN" "$WTROOT/theta"; then
  pass "R10c: git teardown still completes without ddev"
else
  fail "R10c: teardown should still succeed without ddev" "exit $CODE"
fi

# ===========================================================================
# R11: ddev on PATH but no .ddev directory in the worktree -> ddev is not
#      invoked at all; says so; teardown completes.
# ===========================================================================
new_fixture
add_worktree iota
export HERDR_LOG="$SANDBOX_BASE/r11-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r11-ddev.log"
run_retire "$MAIN" "$WTROOT" full iota
if [ ! -s "$DDEV_LOG" ]; then
  pass "R11a: no .ddev directory — ddev is never invoked even though it's on PATH"
else
  fail "R11a: ddev must not be invoked without a .ddev directory" "log: $(cat "$DDEV_LOG")"
fi
if printf '%s' "$OUT" | grep -qi ddev; then
  pass "R11b: stdout notes there was no DDEV project to delete"
else
  fail "R11b: expected stdout to mention no .ddev / no DDEV project" "stdout: $OUT"
fi

# ===========================================================================
# R12: ddev present, .ddev dir present -> `ddev delete -yO` (or equivalent
#      exact tokens) is run from INSIDE the worktree.
#
# Interpretation: the spec's literal text is "ddev delete -yO", which reads
# as two argv tokens: "delete" and the combined short flag "-yO". Asserting
# the exact two tokens rather than "somewhere in the output contains -y and
# -O" because the harness captures exact argv.
# ===========================================================================
new_fixture
add_worktree kappa
add_ddev_dir kappa
export HERDR_LOG="$SANDBOX_BASE/r12-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r12-ddev.log"
DDEV_CWD_LOG="$SANDBOX_BASE/r12-ddev-cwd.log"
export DDEV_CWD_LOG
run_retire "$MAIN" "$WTROOT" full kappa
if grep -qxF $'delete\x1f-yO' "$DDEV_LOG" 2>/dev/null; then
  pass "R12a: ddev is invoked as 'ddev delete -yO'"
else
  fail "R12a: expected argv 'delete', '-yO'" "ddev log:
$(cat "$DDEV_LOG" 2>/dev/null)"
fi
if [ -f "$DDEV_CWD_LOG" ] && [ "$(realpath "$(head -1 "$DDEV_CWD_LOG")")" = "$(realpath "$WTROOT/kappa")" ]; then
  pass "R12b: ddev delete runs from inside the worktree"
else
  fail "R12b: ddev delete must run with cwd == the worktree" "cwd log: $(cat "$DDEV_CWD_LOG" 2>/dev/null); expected: $WTROOT/kappa"
fi
unset DDEV_CWD_LOG

# ===========================================================================
# R13: a failing `ddev delete` is best-effort — warns, does not abort the
#      git teardown.
# ===========================================================================
new_fixture
add_worktree lambda
add_ddev_dir lambda
export HERDR_LOG="$SANDBOX_BASE/r13-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r13-ddev.log"
DDEV_EXIT=17
export DDEV_EXIT
run_retire "$MAIN" "$WTROOT" full lambda
if [ "$CODE" -eq 0 ]; then
  pass "R13a: a failing ddev delete does not abort the overall teardown (exit 0)"
else
  fail "R13a: ddev failure must be best-effort, not fatal" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ -n "$ERR" ]; then
  pass "R13b: a ddev failure is warned about on stderr"
else
  fail "R13b: expected a warning on stderr about the ddev failure"
fi
if ! worktree_still_listed "$MAIN" "$WTROOT/lambda"; then
  pass "R13c: git teardown still happens after a ddev failure"
else
  fail "R13c: worktree should still be removed after a ddev failure" "worktree list: $(git -C "$MAIN" worktree list)"
fi
unset DDEV_EXIT

# ===========================================================================
# R14: a failing `herdr workspace close` is best-effort — warns, does not
#      abort ddev or the git teardown.
# ===========================================================================
new_fixture
add_worktree mu
add_ddev_dir mu
export HERDR_LOG="$SANDBOX_BASE/r14-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r14-ddev.log"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/mu" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-mu"}]}}')"
HERDR_WORKSPACE_CLOSE_EXIT=3
export HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_CLOSE_EXIT
run_retire "$MAIN" "$WTROOT" full mu
if [ "$CODE" -eq 0 ]; then
  pass "R14a: a failing herdr workspace close does not abort the overall teardown"
else
  fail "R14a: herdr close failure must be best-effort, not fatal" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ -n "$ERR" ]; then
  pass "R14b: a herdr close failure is warned about on stderr"
else
  fail "R14b: expected a warning on stderr about the herdr failure"
fi
if grep -qxF 'delete' "$DDEV_LOG" 2>/dev/null || grep -qF $'delete\x1f' "$DDEV_LOG" 2>/dev/null; then
  pass "R14c: ddev delete still runs after a herdr close failure"
else
  fail "R14c: expected ddev delete to still run" "ddev log: $(cat "$DDEV_LOG" 2>/dev/null)"
fi
if ! worktree_still_listed "$MAIN" "$WTROOT/mu"; then
  pass "R14d: git teardown still happens after a herdr close failure"
else
  fail "R14d: worktree should still be removed after a herdr close failure"
fi
unset HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_CLOSE_EXIT

# ===========================================================================
# R15: final report names the workspace id, the DDEV project name, the path
#      and the branch.
# ===========================================================================
new_fixture
add_worktree nu
add_ddev_dir nu
export HERDR_LOG="$SANDBOX_BASE/r15-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r15-ddev.log"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/nu" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-report-77"}]}}')"
export HERDR_WORKTREE_LIST_JSON
run_retire "$MAIN" "$WTROOT" full nu
checks=(
  "ws-report-77:the workspace id"
  "nu-acme-site:the DDEV project name"
  "$WTROOT/nu:the worktree path"
)
for c in "${checks[@]}"; do
  needle="${c%%:*}"; label="${c#*:}"
  if printf '%s' "$OUT" | grep -qF "$needle"; then
    pass "R15: final report mentions $label ($needle)"
  else
    fail "R15: final report must mention $label ($needle)" "stdout: $OUT"
  fi
done
if printf '%s' "$OUT" | grep -qw 'nu'; then
  pass "R15: final report mentions the branch (nu)"
else
  fail "R15: final report must mention the branch" "stdout: $OUT"
fi
unset HERDR_WORKTREE_LIST_JSON

# ===========================================================================
# R17: a worktree whose branch no longer exists (e.g. detached) is torn down
#      without erroring on the branch-delete step.
# ===========================================================================
new_fixture
git -C "$MAIN" worktree add -q --detach "$WTROOT/xi" trunk >/dev/null
export HERDR_LOG="$SANDBOX_BASE/r17-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r17-ddev.log"
run_retire "$MAIN" "$WTROOT" full xi
if [ "$CODE" -eq 0 ]; then
  pass "R17a: retiring a detached-HEAD worktree (no branch to delete) succeeds"
else
  fail "R17a: detached worktree with no branch should still retire cleanly" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if ! worktree_still_listed "$MAIN" "$WTROOT/xi"; then
  pass "R17b: the detached worktree is removed"
else
  fail "R17b: the detached worktree should be removed"
fi

# ===========================================================================
# R18: SAFETY — a genuinely dirty file INSIDE .ddev/ that is NOT the
#      gitignored config.local.yaml must still be treated as dirty.
#
# Only .ddev/config.local.yaml is gitignored (matching the real repo's
# .gitignore). A dirty check that excludes the whole .ddev/ directory via a
# pathspec (rather than relying on gitignore, as a plain `git status
# --porcelain` does) would silently let this through and destroy real work —
# the exact production safety gap this fixture exists to catch.
# ===========================================================================
new_fixture
add_worktree omicron
add_ddev_dir omicron
echo "stray uncommitted file, not gitignored" > "$WTROOT/omicron/.ddev/stray.txt"
export HERDR_LOG="$SANDBOX_BASE/r18-herdr.log"
export DDEV_LOG="$SANDBOX_BASE/r18-ddev.log"
run_retire "$MAIN" "$WTROOT" full omicron
if [ "$CODE" -eq 2 ]; then
  pass "R18a: SAFETY — a dirty file inside .ddev/ that is not gitignored still refuses (exit 2)"
else
  fail "R18a: SAFETY VIOLATION — a genuinely dirty file inside .ddev/ must not be silently ignored" \
"got exit $CODE (expected 2)
stdout: $OUT
stderr: $ERR"
fi
if printf '%s' "$ERR" | grep -q 'stray.txt'; then
  pass "R18b: the stray .ddev file is named in the dirty-file report"
else
  fail "R18b: stderr must list .ddev/stray.txt as a dirty file" "stderr: $ERR"
fi
if worktree_still_listed "$MAIN" "$WTROOT/omicron"; then
  pass "R18c: the worktree survives (was not force-removed despite the dirty file)"
else
  fail "R18c: the worktree must survive when a real dirty file is hidden inside .ddev/"
fi

# ===========================================================================
# SAFETY DEFECT 3 (retire-worktree.sh:130-137): a failed `git worktree
# remove` is ignored.
#
# The script is `set -uo pipefail` with no `-e`, and step 5 checks nothing.
# If `git worktree remove --force` fails (e.g. permission denied on the
# worktree's parent directory), the script carries on regardless: it still
# deletes the branch and still prints a "done." success report and exits 0.
# Worst case: the checkout survives (orphaned, no longer registered with
# git), its branch is gone, and every caller believes the retirement
# succeeded.
#
# Trigger: make WORKTREE_ROOT read-only so `git worktree remove` cannot
# delete the directory's contents.
#
# Exit code contract (post round-2 review): 1 = usage/refusal/bad id,
# 2 = dirty worktree, 4 = failed removal. 3 is retired (see below).
#
# NOT RUNNABLE AS ROOT. The whole scenario hangs off `chmod 555` on
# WORKTREE_ROOT, and root ignores directory permission bits: the removal
# just succeeds, the premise collapses, and the three assertions under it
# report safety violations that are not real. CI runs this job in
# python:3.12-slim as uid 0, so it is skipped there; non-root runs (local,
# and any runner with a normal user) still cover it. H8 is the self-check
# that catches the fixture silently not working -- keep it first.
# ===========================================================================
if [ "$(id -u)" -eq 0 ]; then
  skip "SAFETY DEFECT 3 scenario: needs a non-root user (chmod 555 does not stop root)"
  skip "SAFETY: retire-worktree.sh exits 4 when 'git worktree remove' fails"
  skip "SAFETY: the branch is NOT deleted when 'git worktree remove' failed"
  skip "SAFETY: no success report is printed when 'git worktree remove' failed"
else
new_fixture
add_worktree pi-branch
HERDR_LOG="$SANDBOX_BASE/r19-herdr.log"
DDEV_LOG="$SANDBOX_BASE/r19-ddev.log"
export HERDR_LOG DDEV_LOG

# H8: harness self-check — confirm this really does make `git worktree
# remove` fail, independent of retire-worktree.sh.
chmod 555 "$WTROOT"
git -C "$MAIN" worktree remove --force "$WTROOT/pi-branch" >/tmp/r19-h8.log 2>&1
h8_code=$?
chmod 755 "$WTROOT"
# Recreate the worktree: the self-check above may have partially unregistered
# it even though it failed to delete the files (git unregisters the worktree
# admin entry before attempting the on-disk removal).
if ! worktree_still_listed "$MAIN" "$WTROOT/pi-branch"; then
  rm -rf "$WTROOT/pi-branch" 2>/dev/null
  # The branch itself survived (only the worktree admin entry was dropped),
  # so reattach to it rather than add_worktree's `-b`, which would fail on
  # an already-existing branch.
  git -C "$MAIN" worktree add -q "$WTROOT/pi-branch" pi-branch >/dev/null
fi
if [ "$h8_code" -ne 0 ]; then
  pass "H8: a read-only WORKTREE_ROOT genuinely makes 'git worktree remove' fail"
else
  fail "H8: expected 'git worktree remove' to fail against a read-only parent directory" \
"$(cat /tmp/r19-h8.log)"
fi
rm -f /tmp/r19-h8.log

chmod 555 "$WTROOT"
run_retire "$MAIN" "$WTROOT" full pi-branch
chmod 755 "$WTROOT"

if [ "$CODE" -eq 4 ]; then
  pass "SAFETY: retire-worktree.sh exits 4 when 'git worktree remove' fails"
else
  fail "SAFETY VIOLATION: a failed 'git worktree remove' must exit 4, not $CODE" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if branch_exists "$MAIN" pi-branch; then
  pass "SAFETY: the branch is NOT deleted when 'git worktree remove' failed"
else
  fail "SAFETY VIOLATION: the branch must survive when the worktree could not actually be removed" \
"stdout: $OUT
stderr: $ERR"
fi
if ! printf '%s' "$OUT" | grep -qF 'retire-worktree: done.'; then
  pass "SAFETY: no success report is printed when 'git worktree remove' failed"
else
  fail "SAFETY VIOLATION: a success report must not be printed after a failed removal" "stdout: $OUT"
fi
fi

# ===========================================================================
# Round-2 decision: retire's unmerged-branch guard (formerly "defect 4",
# exit code 3) is REMOVED, not fixed. The reviewer found the fix made the
# feature inert: retire's ancestry check ran against the LOCAL trunk, while
# reap gates on origin/trunk with three tiers (ancestor, patch-equivalent,
# squash) and calls retire without --force. On an ordinary checkout, local
# trunk is routinely stale, so reap would vet a branch as landed and retire
# would then refuse it anyway — and it structurally could never see a
# squash- or rebase-landed branch, since it only ever checked ancestry.
#
# Decision: the merge gate lives in ONE place, reap-worktrees.sh's
# branch_has_landed (see reap-worktrees.test.sh's tier a/b/c coverage).
# retire-worktree.sh, invoked directly, intentionally trusts the caller and
# does not re-derive landed-ness itself. This case pins that on purpose, so
# nobody "fixes" it back into a second, weaker merge check: a worktree that
# is clean per `git status` but holds a committed, never-pushed, unique
# commit is retired successfully without --force.
# ===========================================================================
new_fixture
add_worktree unpushed-branch
echo "unpushed, unmerged content" > "$WTROOT/unpushed-branch/unique-work.txt"
git -C "$WTROOT/unpushed-branch" add unique-work.txt
git -C "$WTROOT/unpushed-branch" commit -q -m "unpushed-branch: unique work, never landed anywhere"

# H9: harness self-check — the worktree really is clean, and the commit
# really is reachable from nowhere else in the repo (i.e. this is genuinely
# the "unmerged but clean" case, not the dirty-worktree case).
if [ -z "$(git -C "$WTROOT/unpushed-branch" status --porcelain)" ]; then
  pass "H9a: the unpushed-branch worktree is genuinely clean per 'git status --porcelain'"
else
  fail "H9a: expected a clean worktree (the unmerged-commit case, not the dirty-worktree case)"
fi

HERDR_LOG="$SANDBOX_BASE/r20-herdr.log"
DDEV_LOG="$SANDBOX_BASE/r20-ddev.log"
export HERDR_LOG DDEV_LOG
run_retire "$MAIN" "$WTROOT" full unpushed-branch
if [ "$CODE" -eq 0 ]; then
  pass "INTENTIONAL: a clean worktree with an unpushed, unmerged commit is retired without --force (merge-gating is reap's job, not retire's)"
else
  fail "a clean worktree holding only an unpushed commit should retire successfully without --force" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if ! worktree_still_listed "$MAIN" "$WTROOT/unpushed-branch"; then
  pass "INTENTIONAL: the worktree is removed"
else
  fail "the worktree should be removed"
fi
if ! branch_exists "$MAIN" unpushed-branch; then
  pass "INTENTIONAL: the branch (and its unpushed commit) is deleted"
else
  fail "the branch should be deleted"
fi

# ===========================================================================
# Round-2 decision: the id charset regex reverts to setup-worktree.sh's exact
# `^[a-z0-9][a-z0-9-]*$` — dashes only, no underscores. No branch or worktree
# anywhere in the repo uses an underscore (the live ids are 338, 357, 358),
# so an underscored id must be REJECTED, matching setup-worktree.sh.
#
# The worktree/branch are deliberately created on disk first (git itself
# happily allows underscores in a branch/dir name) so a real path DOES exist
# at $WORKTREE_ROOT/bad_id — otherwise this would pass for the wrong reason
# (the pre-existing "worktree does not exist" check), not because the id was
# rejected for its charset.
# ===========================================================================
new_fixture
add_worktree bad_id
HERDR_LOG="$SANDBOX_BASE/r22-herdr.log"
DDEV_LOG="$SANDBOX_BASE/r22-ddev.log"
export HERDR_LOG DDEV_LOG
run_retire "$MAIN" "$WTROOT" full "bad_id"
if [ "$CODE" -eq 1 ]; then
  pass "an underscored id (bad_id) is rejected with exit 1, matching setup-worktree.sh's charset"
else
  fail "an underscored id must be rejected with exit 1" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ ! -s "$HERDR_LOG" ] && [ ! -s "$DDEV_LOG" ]; then
  pass "a rejected underscored id touches neither herdr nor ddev"
else
  fail "a rejected underscored id must not call herdr/ddev" "herdr: $(cat "$HERDR_LOG" 2>/dev/null); ddev: $(cat "$DDEV_LOG" 2>/dev/null)"
fi
if worktree_still_listed "$MAIN" "$WTROOT/bad_id"; then
  pass "a rejected underscored id leaves its (pre-existing) worktree untouched"
else
  fail "a rejected underscored id must not remove the worktree it was refused for"
fi
if branch_exists "$MAIN" "bad_id"; then
  pass "a rejected underscored id leaves its (pre-existing) branch untouched"
else
  fail "a rejected underscored id must not delete the branch it was refused for"
fi

# ===========================================================================
# R23: DDEV project naming (Identifier A, ticket #393) -- when a worktree's
# .ddev/config.local.yaml already names a project (the normal case: a real
# setup-worktree.sh run wrote it), retire-worktree.sh must report -- and,
# via `ddev delete -yO`'s cwd-based lookup, actually delete -- exactly THAT
# name, derived the SAME capped/sanitized way setup-worktree.sh derives it
# (see tests/repo/setup-worktree-agent.test.sh sections O/P/Q for the full
# spec), not a raw `$id-acme-site` concatenation.
#
# This is NOT itself the regression guard for the 0386-acme-site orphan
# (a substring match against stdout proves nothing about what `ddev delete`
# actually tore down, and the old bug was two scripts disagreeing on a name,
# not retire mis-rendering a report string). R23b below, which plants a
# config.local.yaml with a name that DISAGREES with what the shared rule
# would derive fresh and asserts retire still reports (and would delete)
# the file's actual name, is that guard.
#
# Rule (restated from the ticket): sanitize the id (lowercase, non-`a-z0-9-`
# to `-`, collapse runs, strip leading/trailing `-`); if the leading segment
# is all digits, the WHOLE digit run (no width cap, no padding) is the DDEV
# name; otherwise cap at the first 3 hyphen-separated segments. Append
# `-acme-site`.
# ===========================================================================

while IFS='|' read -r r_id r_ddev; do
  [ -z "$r_id" ] && continue
  new_fixture
  add_worktree "$r_id"
  # No config.local.yaml is planted here (deliberately, unlike R23b below):
  # retire-worktree.sh must fall back to its OWN ddev_project_name "$id"
  # derivation, not the test's derive_ddev_name helper's fixture content
  # read back -- that is what pins the script's capping/digit-run rule
  # itself, rather than comparing the test against itself.
  export HERDR_LOG="$SANDBOX_BASE/r23-$r_id-herdr.log"
  export DDEV_LOG="$SANDBOX_BASE/r23-$r_id-ddev.log"
  run_retire "$MAIN" "$WTROOT" full "$r_id"
  if [ "$CODE" -eq 0 ]; then
    pass "R23[$r_id]: retire of a multi-segment id exits 0"
  else
    fail "R23[$r_id]: retire of a multi-segment id must exit 0" "got exit $CODE
stdout: $OUT
stderr: $ERR"
  fi
  if printf '%s' "$OUT" | grep -qF "$r_ddev"; then
    pass "R23[$r_id]: final report names the DDEV project as '$r_ddev' (capped/derived), matching setup-worktree.sh"
  else
    fail "R23[$r_id]: final report must name the DDEV project '$r_ddev', matching the rule setup-worktree.sh uses" \
"expected to find: $r_ddev
stdout: $OUT"
  fi
  # The uncapped, naive concatenation must NOT appear either -- a report that
  # happens to contain both the right and the wrong name would pass the
  # check above for the wrong reason.
  naive="$r_id-acme-site"
  if [ "$naive" != "$r_ddev" ]; then
    if printf '%s' "$OUT" | grep -qF "$naive"; then
      fail "R23[$r_id]: final report must NOT use the naive, uncapped '$naive' name" "stdout: $OUT"
    else
      pass "R23[$r_id]: final report does not fall back to the naive, uncapped name"
    fi
  fi
done <<'CASES'
382-trunk-layout-backfill-skips-inline-blocks|382-acme-site
289-numbered-steps-style|289-acme-site
wait-times-mobile-ordering-fix|wait-times-mobile-acme-site
CASES

# ===========================================================================
# R23b: the actual regression guard for the 0386-acme-site orphan. A
# worktree's config.local.yaml may name a DIFFERENT project than the shared
# rule would derive fresh from $id right now -- e.g. it was provisioned
# under an older naming rule, or setup-worktree.sh's must-fix-1 guard
# refused to rewrite it because the derived name changed underneath it.
# `ddev delete -yO` acts on whatever that file says (cwd-based, no name
# argument), so the report -- and the actual delete target -- MUST be the
# file's name, not a fresh re-derivation from $id. Reporting the fresh
# derivation while the stale name is what's actually deleted (or, worse,
# nothing is deleted because the stale project's real name was never named
# anywhere) is exactly the 0386-acme-site failure mode.
# ===========================================================================
while IFS='|' read -r r_id r_stale; do
  [ -z "$r_id" ] && continue
  new_fixture
  add_worktree "$r_id"
  add_ddev_dir "$r_id" "$r_stale"
  export HERDR_LOG="$SANDBOX_BASE/r23b-$r_id-herdr.log"
  export DDEV_LOG="$SANDBOX_BASE/r23b-$r_id-ddev.log"
  run_retire "$MAIN" "$WTROOT" full "$r_id"
  fresh="$(derive_ddev_name "$r_id")"
  # Read the "DDEV project: X" report line exactly, rather than a plain
  # substring search against all of $OUT -- $fresh ("387-acme-site") is
  # itself a SUBSTRING of $r_stale ("0387-acme-site"), so a naive
  # grep -qF "$fresh" would spuriously match inside the correct output.
  reported_line="$(printf '%s\n' "$OUT" | sed -n 's/^retire-worktree:   DDEV project: //p')"
  if [ "$reported_line" = "$r_stale" ]; then
    pass "R23b[$r_id]: final report names the worktree's ACTUAL project '$r_stale', not a fresh re-derivation"
  else
    fail "R23b[$r_id]: final report must name the file's actual project '$r_stale' (what \`ddev delete\` really acts on)" \
"expected: $r_stale
got:      ${reported_line:-<missing>}
stdout: $OUT"
  fi
  if [ "$fresh" != "$r_stale" ] && [ "$reported_line" = "$fresh" ]; then
    fail "R23b[$r_id]: final report must NOT report the freshly re-derived '$fresh' in place of the actual '$r_stale'" "stdout: $OUT"
  else
    pass "R23b[$r_id]: final report does not substitute a freshly re-derived name for the actual one"
  fi
done <<'CASES'
387-delivery-type-styling|0387-acme-site
382-trunk-layout-backfill-skips-inline-blocks|0382-acme-site
CASES

# --- R24: wide ticket numbers are not truncated (regression: the retired
#     orca-setup-worktree.sh 4-char rule turned 10000 into 1000) -----------
while IFS='|' read -r r_id r_ddev; do
  [ -z "$r_id" ] && continue
  new_fixture
  add_worktree "$r_id"
  # No config.local.yaml here either -- same reasoning as R23 above: this
  # must exercise retire-worktree.sh's own ddev_project_name fallback, not
  # the test fixture's derive_ddev_name read back.
  export HERDR_LOG="$SANDBOX_BASE/r24-$r_id-herdr.log"
  export DDEV_LOG="$SANDBOX_BASE/r24-$r_id-ddev.log"
  run_retire "$MAIN" "$WTROOT" full "$r_id"
  if printf '%s' "$OUT" | grep -qF "$r_ddev"; then
    pass "R24[$r_id]: a ticket number past 999 is reported as '$r_ddev', not truncated to 4 characters"
  else
    fail "R24[$r_id]: final report must name the full, untruncated DDEV project '$r_ddev'" "stdout: $OUT"
  fi
done <<'CASES'
1024-shared-naming|1024-acme-site
10000|10000-acme-site
CASES

# ===========================================================================
# R25: the sanitizer itself must not depend on locale, and must never emit a
# bare "-acme-site" (ticket #393 round 2). retire-worktree.sh's own
# ddev_project_name is only ever called with an already-regex-validated id
# (^[a-z0-9][a-z0-9-]*$, checked at the top of the script), so these inputs
# can never arrive via the real `<id>` argument -- this pins the copy of the
# function directly, extracted straight out of scripts/retire-worktree.sh
# itself (not reimplemented here), so a fix that only lands in
# setup-worktree.sh's copy still shows up red here.
# ===========================================================================
real_ddev_project_name() { # real_ddev_project_name <locale> <input> -> name
  # The basename argument is REQUIRED in production (no "acme-site"
  # default lives in the engine -- see worktree-promotion-spec.md's
  # done-criterion 3), so this call site passes it explicitly. Every fixture
  # in this suite runs against a main checkout literally named
  # "acme-site" (see new_fixture), so that is the value a real call site
  # would resolve here too.
  LC_ALL="$1" bash -c '. "$ORCH_PROJECT_LIB"; ddev_project_name "$1" acme-site' _ "$2"
}

got="$(real_ddev_project_name en_US.UTF-8 'café-382')"
if [ "$got" = "caf-382-acme-site" ]; then
  pass "R25a: ddev_project_name pins LC_ALL=C so an accented branch under a UTF-8 locale still sanitizes (café-382 -> caf-382-acme-site)"
else
  fail "R25a: ddev_project_name must not let the caller's locale leave accented characters unsanitized" \
"expected: caf-382-acme-site
got:      ${got:-<empty>}"
fi

got="$(real_ddev_project_name C '!!!')"
if [ "$got" != "-acme-site" ] && [ -n "$got" ]; then
  pass "R25b: ddev_project_name never emits a bare '-acme-site' for an all-punctuation input (got: $got)"
else
  fail "R25b: an all-punctuation input must fall back to a non-empty name, not a bare '-acme-site'" "got: ${got:-<empty>}"
fi

# ===========================================================================
# RD. Genericization (worktree-promotion-spec.md): the symmetric optional
#     retire hook (PROVISION_HOOK's counterpart on the teardown side) and the
#     WORKTREE_ROOT default derived from the main checkout's basename rather
#     than a hardcoded .../acme-site.
#
#     Interpretation pinned here -- flag to the implementor/reviewer: the
#     spec names the hook only as "conventionally
#     <worktree>/scripts/retire-worktree.sh, called if present"; it does not
#     name an environment-variable override the way PROVISION_HOOK has one.
#     Tests below assume an analogous `RETIRE_HOOK` env override for
#     symmetry with the create side, since the spec explicitly calls this
#     "PROVISION_HOOK's counterpart" -- if the implementor decides there is
#     no env override, RD1 is the one case to drop or rewrite.
# ===========================================================================

# --- RD1: RETIRE_HOOK env override wins, called with cwd = the worktree,
#     BEFORE the worktree is removed (it needs to exist to run against). ----
new_fixture
add_worktree rd1
RD1_HOOK_DIR="$SANDBOX_BASE/rd1-hook"
mkdir -p "$RD1_HOOK_DIR"
RD1_HOOK_LOG="$RD1_HOOK_DIR/hook.log"; : > "$RD1_HOOK_LOG"
cat > "$RD1_HOOK_DIR/hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'ran:%s:%s\n' "$PWD" "$*" >> "$RD1_HOOK_LOG_TARGET"
HOOK
chmod +x "$RD1_HOOK_DIR/hook.sh"
export HERDR_LOG="$SANDBOX_BASE/rd1-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd1-ddev.log"; : > "$DDEV_LOG"
export RETIRE_HOOK="$RD1_HOOK_DIR/hook.sh"
export RD1_HOOK_LOG_TARGET="$RD1_HOOK_LOG"
run_retire "$MAIN" "$WTROOT" full rd1
unset RETIRE_HOOK RD1_HOOK_LOG_TARGET

if grep -qF "ran:$WTROOT/rd1:" "$RD1_HOOK_LOG" 2>/dev/null; then
  pass "RD1a: RETIRE_HOOK (env) is invoked with cwd = the worktree, before it is removed"
else
  fail "RD1a: RETIRE_HOOK must be invoked with cwd set to the still-existing worktree" "$(cat "$RD1_HOOK_LOG" 2>/dev/null)
stdout: $OUT
stderr: $ERR"
fi

if [ ! -s "$DDEV_LOG" ]; then
  pass "RD1b: a successful RETIRE_HOOK (exit 0) replaces the engine's own ddev delete step"
else
  fail "RD1b: ddev delete must not run when RETIRE_HOOK succeeded" "ddev: $(cat "$DDEV_LOG" 2>/dev/null)"
fi

# --- RD2: the conventional <worktree>/scripts/retire-worktree.sh, when no
#     RETIRE_HOOK override is set. -------------------------------------------
new_fixture
add_worktree rd2
mkdir -p "$WTROOT/rd2/scripts"
RD2_HOOK_LOG="$SANDBOX_BASE/rd2-hook.log"; : > "$RD2_HOOK_LOG"
cat > "$WTROOT/rd2/scripts/retire-worktree.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'ran:%s:%s\n' "$PWD" "$*" >> "$RD2_HOOK_LOG_TARGET"
HOOK
chmod +x "$WTROOT/rd2/scripts/retire-worktree.sh"
export HERDR_LOG="$SANDBOX_BASE/rd2-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd2-ddev.log"; : > "$DDEV_LOG"
export RD2_HOOK_LOG_TARGET="$RD2_HOOK_LOG"
run_retire "$MAIN" "$WTROOT" full rd2
unset RD2_HOOK_LOG_TARGET

if grep -qF "ran:$WTROOT/rd2:" "$RD2_HOOK_LOG" 2>/dev/null; then
  pass "RD2: the conventional <worktree>/scripts/retire-worktree.sh runs when no RETIRE_HOOK env override is set"
else
  fail "RD2: the conventional retire hook path must be tried before the engine's own retire behaviour" "$(cat "$RD2_HOOK_LOG" 2>/dev/null)
stdout: $OUT
stderr: $ERR"
fi

if [ ! -s "$DDEV_LOG" ]; then
  pass "RD2b: a successful conventional hook (exit 0) replaces the engine's own ddev delete step"
else
  fail "RD2b: ddev delete must not run when the conventional hook succeeded" "ddev: $(cat "$DDEV_LOG" 2>/dev/null)"
fi

# --- RD3: neither RETIRE_HOOK nor the conventional path exists -> the
#     engine's own retire behaviour runs (unchanged) -- a project with no
#     retire hook is not required to have one. -------------------------------
new_fixture
add_worktree rd3
export HERDR_LOG="$SANDBOX_BASE/rd3-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd3-ddev.log"; : > "$DDEV_LOG"
run_retire "$MAIN" "$WTROOT" full rd3
if [ "$CODE" -eq 0 ] && ! worktree_still_listed "$MAIN" "$WTROOT/rd3"; then
  pass "RD3: with no retire hook anywhere, the engine's own retire behaviour still tears the worktree down"
else
  fail "RD3: a project with no retire hook must still retire normally" "exit $CODE; stdout: $OUT; stderr: $ERR"
fi

# --- RD4: default layout (<root>/code/<main> + <root>/code/<id>), run from
#     inside the worktree being retired. Retire must step out of it first.
rd4_root="$SANDBOX_BASE/rd4"
mkdir -p "$rd4_root/code/some-other-checkout"
git init -q "$rd4_root/code/some-other-checkout" >/dev/null 2>&1
(cd "$rd4_root/code/some-other-checkout" && git checkout -q -b trunk && echo seed > seed.txt && git add seed.txt && git commit -q -m seed) >/dev/null 2>&1
git -C "$rd4_root/code/some-other-checkout" worktree add -q -b rd4 "$rd4_root/code/rd4" trunk >/dev/null 2>&1
: > "$rd4_root/.orch"
(
  cd "$rd4_root/code/rd4" || exit 99
  PATH="$MINIMAL_PATH" bash "$SCRIPT_COPY" rd4
) > "$rd4_root/stdout" 2> "$rd4_root/stderr"
rd4_rc=$?

if [ "$rd4_rc" -eq 0 ] && [ ! -e "$rd4_root/code/rd4" ] && [ -d "$rd4_root/code/some-other-checkout" ]; then
  pass "RD4: retire works from inside the worktree it retires, in the default layout"
else
  fail "RD4: retire must work from inside the worktree it retires" \
"exit $rd4_rc
stdout: $(cat "$rd4_root/stdout")
stderr: $(cat "$rd4_root/stderr")"
fi

# --- RD4b: a worktree whose DDEV name is the main checkout's (<PROJECT_NAME>)
#     must never have that project deleted.
new_fixture
add_worktree rd4b
add_ddev_dir rd4b acme-site
export DDEV_LOG="$SANDBOX_BASE/rd4b-ddev.log"; : > "$DDEV_LOG"
run_retire "$MAIN" "$WTROOT" full rd4b
if [ ! -s "$DDEV_LOG" ] && printf '%s' "$ERR" | grep -q "main checkout's DDEV project; refusing"; then
  pass "RD4b: the main checkout's DDEV project is never deleted"
else
  fail "RD4b: retire must refuse to delete the DDEV project named <PROJECT_NAME>" "ddev log: $(cat "$DDEV_LOG")
stderr: $ERR"
fi
unset DDEV_LOG

# ===========================================================================
# RD5-RD7: BUG regression -- the conventional <worktree>/scripts/retire-worktree.sh
#     hook is frequently a thin DELEGATE SHIM back to this very engine
#     (`exec "$RETIRE_ENGINE" "$@"`, see acme-site's real copy). Called
#     with no args, a naive re-entry prints usage and exits 1/nonzero, which
#     the engine must not silently treat as "the hook handled step 4" --
#     that orphans the real DDEV project.
#
#     Intended fix: the engine exports RETIRE_WORKTREE_IN_HOOK=1 into the
#     hook's environment when it invokes one. A re-entered engine that sees
#     RETIRE_WORKTREE_IN_HOOK already set recognizes it was called from its
#     own retire hook, warns on stderr, and exits 3 immediately, doing
#     nothing. The OUTER engine checks the hook's exit code: 0 means the
#     hook genuinely handled step 4 (existing RD1/RD2 behaviour, above);
#     any nonzero exit means it did NOT, so the engine warns (naming the
#     hook and its exit code) and falls through to run its OWN
#     ddev-delete step, and the final report names the real
#     DDEV project rather than "(handled by ...)".
# ===========================================================================

# --- RD5: a conventional hook that is a delegate shim identical in shape to
#     acme-site's real scripts/retire-worktree.sh, pointed via
#     RETIRE_ENGINE at the SCRIPT_COPY under test, so re-entry is genuine
#     (the same binary, the same code path a real project would hit). -------
new_fixture
add_worktree rd5
add_ddev_dir rd5
mkdir -p "$WTROOT/rd5/scripts"
cat > "$WTROOT/rd5/scripts/retire-worktree.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
ENGINE="${RETIRE_ENGINE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/retire-worktree/scripts/retire-worktree.sh}"
if [ ! -x "$ENGINE" ]; then
  echo "retire-worktree: skipping — no engine to delegate to. Looked for $ENGINE." >&2
  exit 0
fi
exec "$ENGINE" "$@"
HOOK
chmod +x "$WTROOT/rd5/scripts/retire-worktree.sh"
export HERDR_LOG="$SANDBOX_BASE/rd5-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd5-ddev.log"; : > "$DDEV_LOG"
export RETIRE_ENGINE="$SCRIPT_COPY"
run_retire "$MAIN" "$WTROOT" full rd5
unset RETIRE_ENGINE

if [ "$CODE" -eq 0 ]; then
  pass "RD5a: retiring through a delegate-shim conventional hook still exits 0"
else
  fail "RD5a: retiring through a delegate-shim conventional hook must still exit 0" "exit $CODE
stdout: $OUT
stderr: $ERR"
fi

if grep -qxF $'delete\x1f-yO' "$DDEV_LOG" 2>/dev/null; then
  pass "RD5b: the engine's own ddev delete ran when the delegate-shim hook did not handle it"
else
  fail "RD5b: ddev delete must run when the resolved hook is a delegate shim back into this engine" "ddev log: $(cat "$DDEV_LOG" 2>/dev/null)
stdout: $OUT
stderr: $ERR"
fi

if [ -s "$HERDR_LOG" ]; then
  pass "RD5c: herdr is consulted (the engine's own step 3 always runs)"
else
  fail "RD5c: herdr must be consulted by the engine's own step 3" "herdr log: $(cat "$HERDR_LOG" 2>/dev/null)"
fi

if ! printf '%s' "$OUT" | grep -qF 'handled by'; then
  pass "RD5d: the final report does not attribute teardown to a hook that never actually ran it"
else
  fail "RD5d: report must not say 'handled by' when the hook was an ignored re-entry" "stdout: $OUT"
fi

if ! worktree_still_listed "$MAIN" "$WTROOT/rd5" && ! branch_exists "$MAIN" rd5; then
  pass "RD5e: the worktree and branch are still torn down despite the hook not handling step 4"
else
  fail "RD5e: worktree/branch teardown (step 5) must still happen" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

if ! printf '%s\n%s' "$OUT" "$ERR" | grep -qi 'usage:'; then
  pass "RD5f: no usage message leaks out — the re-entered engine must recognize it was called from its own hook, not just fail argument parsing"
else
  fail "RD5f: stdout/stderr must not contain a usage message from the re-entered engine" "stdout: $OUT
stderr: $ERR"
fi

# --- RD6: RETIRE_HOOK (env override) points at a hook that exits nonzero
#     (7) without ever touching ddev -- any nonzero hook exit, not
#     just the re-entry case, must fall through to the engine's own
#     ddev step and be reported on stderr. ----------------------------
new_fixture
add_worktree rd6
add_ddev_dir rd6
RD6_HOOK_DIR="$SANDBOX_BASE/rd6-hook"
mkdir -p "$RD6_HOOK_DIR"
cat > "$RD6_HOOK_DIR/hook.sh" <<'HOOK'
#!/usr/bin/env bash
exit 7
HOOK
chmod +x "$RD6_HOOK_DIR/hook.sh"
export HERDR_LOG="$SANDBOX_BASE/rd6-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd6-ddev.log"; : > "$DDEV_LOG"
export RETIRE_HOOK="$RD6_HOOK_DIR/hook.sh"
run_retire "$MAIN" "$WTROOT" full rd6
unset RETIRE_HOOK

if printf '%s' "$ERR" | grep -qF 'exit 7'; then
  pass "RD6a: a failing hook's exit code (7) is named in the engine's stderr warning"
else
  fail "RD6a: stderr must name the hook's nonzero exit code" "stderr: $ERR"
fi

if [ -s "$DDEV_LOG" ]; then
  pass "RD6b: the engine's own ddev delete ran after the hook exited nonzero"
else
  fail "RD6b: ddev delete must run when the hook did not exit 0" "ddev log: $(cat "$DDEV_LOG" 2>/dev/null)"
fi

if [ "$CODE" -eq 0 ]; then
  pass "RD6c: overall exit stays 0 despite the hook's own nonzero exit"
else
  fail "RD6c: overall exit must stay 0 when the engine's own fallback teardown succeeds" "exit $CODE
stdout: $OUT
stderr: $ERR"
fi

if ! worktree_still_listed "$MAIN" "$WTROOT/rd6"; then
  pass "RD6d: the worktree is still removed"
else
  fail "RD6d: worktree removal (step 5) must still happen after a failing hook" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# --- RD7: the engine, invoked directly with RETIRE_WORKTREE_IN_HOOK=1
#     already set (simulating a delegate-shim hook re-entering it), refuses
#     immediately (exit 3) and touches nothing -- this is the guard that
#     RD5's re-entry relies on. -----------------------------------------------
new_fixture
add_worktree rd7
export HERDR_LOG="$SANDBOX_BASE/rd7-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd7-ddev.log"; : > "$DDEV_LOG"
export RETIRE_WORKTREE_IN_HOOK=1
run_retire "$MAIN" "$WTROOT" full rd7
unset RETIRE_WORKTREE_IN_HOOK

if [ "$CODE" -eq 3 ]; then
  pass "RD7a: direct invocation with RETIRE_WORKTREE_IN_HOOK=1 already set exits 3"
else
  fail "RD7a: RETIRE_WORKTREE_IN_HOOK=1 must make the engine refuse with exit 3" "exit $CODE
stdout: $OUT
stderr: $ERR"
fi

if worktree_still_listed "$MAIN" "$WTROOT/rd7" && branch_exists "$MAIN" rd7; then
  pass "RD7b: the worktree and branch are left untouched"
else
  fail "RD7b: a re-entry refusal must not touch the worktree or branch" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# --- RD8: SAFETY -- the conventional-hook exemption (RD5-RD7) must only ever
#     strip the exact `scripts/retire-worktree.sh` status line, never any
#     other dirty file whose path merely CONTAINS the substring
#     "retire-worktree". A too-broad filter (e.g. `grep -vF
#     'retire-worktree'` instead of the anchored `^.. scripts/retire-worktree\.sh$`)
#     would also swallow a sibling `scripts/retire-worktree.sh.orig` and a
#     same-named file nested elsewhere (`other/scripts/retire-worktree.sh`),
#     silently hiding real uncommitted work and letting a dirty worktree
#     through without --force. Run WITHOUT --force: must still refuse. ------
new_fixture
add_worktree rd8
mkdir -p "$WTROOT/rd8/scripts" "$WTROOT/rd8/other/scripts"
cat > "$WTROOT/rd8/scripts/retire-worktree.sh" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
chmod +x "$WTROOT/rd8/scripts/retire-worktree.sh"
echo "stray sibling file, not the conventional hook itself" > "$WTROOT/rd8/scripts/retire-worktree.sh.orig"
echo "stray nested file, same basename, different path" > "$WTROOT/rd8/other/scripts/retire-worktree.sh"
export HERDR_LOG="$SANDBOX_BASE/rd8-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rd8-ddev.log"; : > "$DDEV_LOG"
run_retire "$MAIN" "$WTROOT" full rd8

if [ "$CODE" -eq 2 ]; then
  pass "RD8a: SAFETY -- extra dirty files that merely contain 'retire-worktree' in their path still refuse without --force (exit 2)"
else
  fail "RD8a: SAFETY VIOLATION -- a too-broad conventional-hook exemption must not swallow other dirty files" "got exit $CODE (expected 2)
stdout: $OUT
stderr: $ERR"
fi

if printf '%s' "$ERR" | grep -qF 'scripts/retire-worktree.sh.orig'; then
  pass "RD8b: stderr still lists the sibling scripts/retire-worktree.sh.orig as dirty"
else
  fail "RD8b: stderr must list scripts/retire-worktree.sh.orig" "stderr: $ERR"
fi

if printf '%s' "$ERR" | grep -qF 'other/scripts/retire-worktree.sh'; then
  pass "RD8c: stderr still lists the nested other/scripts/retire-worktree.sh as dirty"
else
  fail "RD8c: stderr must list other/scripts/retire-worktree.sh" "stderr: $ERR"
fi

if worktree_still_listed "$MAIN" "$WTROOT/rd8"; then
  pass "RD8d: the worktree survives (was not force-removed despite the hidden dirty files)"
else
  fail "RD8d: the worktree must survive when extra dirty files are wrongly exempted" "git worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# ===========================================================================
# RS. Self-workspace deferral: when the resolved Herdr workspace id equals
#     $HERDR_WORKSPACE_ID (the agent is running INSIDE the very workspace it
#     is about to close), closing it in step 3 (today's order) kills the
#     agent's own pane — and the script with it — before ddev delete, git
#     worktree remove and the branch delete ever run. Required behaviour:
#     defer that one close to the very last action, AFTER steps 4 (ddev), 5
#     (git worktree remove + branch delete) and 6 (final report). A
#     DIFFERENT (or unset) $HERDR_WORKSPACE_ID keeps today's ordering
#     (close first, in step 3) unchanged.
#
# COMBINED_ORDER_LOG (harness addition, this suite only) is written to by
# BOTH stubs — "ddev-delete" from the ddev stub on `ddev delete`, and
# "herdr-close" from the herdr stub on `herdr workspace close` — so ordering
# between the two is observed directly from real call order, independent of
# source-line order in the script under test.
# ===========================================================================

# --- RS1: self case — resolved workspace id equals $HERDR_WORKSPACE_ID.
#     ddev delete must run, and the worktree must already be gone from disk,
#     BEFORE the herdr close call. -------------------------------------------
new_fixture
add_worktree rs1
add_ddev_dir rs1
export HERDR_LOG="$SANDBOX_BASE/rs1-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rs1-ddev.log"; : > "$DDEV_LOG"
RS1_ORDER_LOG="$SANDBOX_BASE/rs1-order.log"; : > "$RS1_ORDER_LOG"
RS1_EXISTS_LOG="$SANDBOX_BASE/rs1-exists.log"; : > "$RS1_EXISTS_LOG"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/rs1" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-self-rs1"}]}}')"
export HERDR_WORKTREE_LIST_JSON
export COMBINED_ORDER_LOG="$RS1_ORDER_LOG"
export HERDR_CLOSE_ORDER_LOG="$RS1_EXISTS_LOG" HERDR_CLOSE_EXISTS_CHECK="$WTROOT/rs1"
HERDR_WORKSPACE_ID=ws-self-rs1 run_retire "$MAIN" "$WTROOT" full rs1
unset HERDR_WORKTREE_LIST_JSON COMBINED_ORDER_LOG HERDR_CLOSE_ORDER_LOG HERDR_CLOSE_EXISTS_CHECK

if [ "$CODE" -eq 0 ]; then
  pass "RS1a: retiring your own workspace's worktree still exits 0"
else
  fail "RS1a: retiring your own workspace's worktree must still exit 0" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi

order="$(cat "$RS1_ORDER_LOG" 2>/dev/null)"
if printf '%s\n' "$order" | grep -qxF 'ddev-delete' && printf '%s\n' "$order" | grep -qxF 'herdr-close'; then
  ddev_line="$(printf '%s\n' "$order" | grep -nxF 'ddev-delete' | head -1 | cut -d: -f1)"
  close_line="$(printf '%s\n' "$order" | grep -nxF 'herdr-close' | head -1 | cut -d: -f1)"
  if [ -n "$ddev_line" ] && [ -n "$close_line" ] && [ "$ddev_line" -lt "$close_line" ]; then
    pass "RS1b: ddev delete runs BEFORE the deferred herdr workspace close, for the caller's own workspace"
  else
    fail "RS1b: ddev delete must run before the deferred close" "order log: $order"
  fi
else
  fail "RS1b: expected both a ddev-delete and a herdr-close entry in the combined order log" "order log: $order"
fi

if grep -qx 'gone' "$RS1_EXISTS_LOG" 2>/dev/null; then
  pass "RS1c: the worktree is already gone from disk by the time the deferred close runs (git worktree remove + branch delete ran first)"
else
  fail "RS1c: the worktree must already be removed before the deferred close of the caller's own workspace" "exists log: $(cat "$RS1_EXISTS_LOG" 2>/dev/null)"
fi

if printf '%s' "$OUT" | grep -qF 'ws-self-rs1'; then
  pass "RS1d: the final report names the workspace id even though its close is deferred"
else
  fail "RS1d: the final report must still name the workspace id" "stdout: $OUT"
fi

if printf '%s' "$OUT" | grep -qi 'defer'; then
  pass "RS1e: stdout explains the close is deferred because it is the caller's own workspace"
else
  fail "RS1e: expected stdout to explain the deferral" "stdout: $OUT"
fi

if ! worktree_still_listed "$MAIN" "$WTROOT/rs1" && ! branch_exists "$MAIN" rs1; then
  pass "RS1f: the worktree and branch are torn down"
else
  fail "RS1f: the worktree and branch must still be torn down" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# --- RS2: a DIFFERENT $HERDR_WORKSPACE_ID (not the resolved workspace) —
#     ordering is UNCHANGED: close happens first, in step 3, before ddev
#     delete and before the worktree is removed from disk. -------------------
new_fixture
add_worktree rs2
add_ddev_dir rs2
export HERDR_LOG="$SANDBOX_BASE/rs2-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rs2-ddev.log"; : > "$DDEV_LOG"
RS2_ORDER_LOG="$SANDBOX_BASE/rs2-order.log"; : > "$RS2_ORDER_LOG"
RS2_EXISTS_LOG="$SANDBOX_BASE/rs2-exists.log"; : > "$RS2_EXISTS_LOG"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/rs2" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-different-rs2"}]}}')"
export HERDR_WORKTREE_LIST_JSON
export COMBINED_ORDER_LOG="$RS2_ORDER_LOG"
export HERDR_CLOSE_ORDER_LOG="$RS2_EXISTS_LOG" HERDR_CLOSE_EXISTS_CHECK="$WTROOT/rs2"
HERDR_WORKSPACE_ID=ws-some-other-workspace run_retire "$MAIN" "$WTROOT" full rs2
unset HERDR_WORKTREE_LIST_JSON COMBINED_ORDER_LOG HERDR_CLOSE_ORDER_LOG HERDR_CLOSE_EXISTS_CHECK

order="$(cat "$RS2_ORDER_LOG" 2>/dev/null)"
ddev_line="$(printf '%s\n' "$order" | grep -nxF 'ddev-delete' | head -1 | cut -d: -f1)"
close_line="$(printf '%s\n' "$order" | grep -nxF 'herdr-close' | head -1 | cut -d: -f1)"
if [ -n "$ddev_line" ] && [ -n "$close_line" ] && [ "$close_line" -lt "$ddev_line" ]; then
  pass "RS2a: a different \$HERDR_WORKSPACE_ID leaves ordering unchanged — herdr close runs BEFORE ddev delete"
else
  fail "RS2a: a different HERDR_WORKSPACE_ID must not defer the close" "order log: $order"
fi

if grep -qx 'exists' "$RS2_EXISTS_LOG" 2>/dev/null; then
  pass "RS2b: the worktree still exists on disk at close time — close is not deferred for someone else's workspace id"
else
  fail "RS2b: close must happen while the worktree still exists (undeferred case)" "exists log: $(cat "$RS2_EXISTS_LOG" 2>/dev/null)"
fi

# --- RS3: \$HERDR_WORKSPACE_ID unset entirely — same as today, unchanged. ---
new_fixture
add_worktree rs3
export HERDR_LOG="$SANDBOX_BASE/rs3-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rs3-ddev.log"; : > "$DDEV_LOG"
RS3_EXISTS_LOG="$SANDBOX_BASE/rs3-exists.log"; : > "$RS3_EXISTS_LOG"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/rs3" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-rs3"}]}}')"
export HERDR_WORKTREE_LIST_JSON
export HERDR_CLOSE_ORDER_LOG="$RS3_EXISTS_LOG" HERDR_CLOSE_EXISTS_CHECK="$WTROOT/rs3"
unset HERDR_WORKSPACE_ID
run_retire "$MAIN" "$WTROOT" full rs3
unset HERDR_WORKTREE_LIST_JSON HERDR_CLOSE_ORDER_LOG HERDR_CLOSE_EXISTS_CHECK

if grep -qx 'exists' "$RS3_EXISTS_LOG" 2>/dev/null; then
  pass "RS3: an unset \$HERDR_WORKSPACE_ID closes the workspace undeferred, same as today"
else
  fail "RS3: an unset HERDR_WORKSPACE_ID must not defer the close" "exists log: $(cat "$RS3_EXISTS_LOG" 2>/dev/null)"
fi

# --- RS4: the deferred close is best-effort — a failing deferred close
#     still exits 0 (the worktree is already gone), with a warning on
#     stderr. --------------------------------------------------------------
new_fixture
add_worktree rs4
add_ddev_dir rs4
export HERDR_LOG="$SANDBOX_BASE/rs4-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rs4-ddev.log"; : > "$DDEV_LOG"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/rs4" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-self-rs4"}]}}')"
export HERDR_WORKTREE_LIST_JSON
export HERDR_WORKSPACE_CLOSE_EXIT=13
HERDR_WORKSPACE_ID=ws-self-rs4 run_retire "$MAIN" "$WTROOT" full rs4
unset HERDR_WORKTREE_LIST_JSON HERDR_WORKSPACE_CLOSE_EXIT

if [ "$CODE" -eq 0 ]; then
  pass "RS4a: a failing DEFERRED close of the caller's own workspace still exits 0"
else
  fail "RS4a: a failing deferred close must be best-effort (exit 0)" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi

if [ -n "$ERR" ]; then
  pass "RS4b: a failing deferred close is warned about on stderr"
else
  fail "RS4b: expected a warning on stderr about the failed deferred close"
fi

if ! worktree_still_listed "$MAIN" "$WTROOT/rs4" && ! branch_exists "$MAIN" rs4; then
  pass "RS4c: the worktree and branch are torn down despite the deferred close failing"
else
  fail "RS4c: the worktree and branch must be torn down regardless of the deferred close's outcome" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# ===========================================================================
# RS5: the caller's own workspace close was DEFERRED (step 3 skipped, to run
#     last), but step 5's `git worktree remove` then fails. The deferred
#     close never gets a chance to run (the script exits 4 before reaching
#     it), so the workspace is left open with no code path left to close it.
#     Required behaviour (round-2 finding): stderr must additionally name
#     the herdr workspace id that was left open (the caller's own) and tell
#     the caller to re-run retire-worktree.sh after fixing the removal
#     failure. Same non-root-only caveat as the SAFETY DEFECT 3 scenario
#     above (chmod 555 does not stop root). ------------------------------
if [ "$(id -u)" -eq 0 ]; then
  skip "RS5: needs a non-root user (chmod 555 does not stop root)"
else
new_fixture
add_worktree rs5
add_ddev_dir rs5
export HERDR_LOG="$SANDBOX_BASE/rs5-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/rs5-ddev.log"; : > "$DDEV_LOG"
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/rs5" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-self-rs5"}]}}')"
export HERDR_WORKTREE_LIST_JSON

chmod 555 "$WTROOT"
HERDR_WORKSPACE_ID=ws-self-rs5 run_retire "$MAIN" "$WTROOT" full rs5
chmod 755 "$WTROOT"
unset HERDR_WORKTREE_LIST_JSON

# Recreate the worktree admin entry if the failed removal partially
# unregistered it, same recovery as H8 above, so later cases in this file
# start from a clean $MAIN.
if ! worktree_still_listed "$MAIN" "$WTROOT/rs5"; then
  rm -rf "$WTROOT/rs5" 2>/dev/null
  git -C "$MAIN" worktree add -q "$WTROOT/rs5" rs5 >/dev/null 2>&1 || true
fi

if [ "$CODE" -eq 4 ]; then
  pass "RS5a: retire-worktree.sh still exits 4 when the removal fails, even with a deferred close pending"
else
  fail "RS5a: expected exit 4" "got exit $CODE
stdout: $OUT
stderr: $ERR"
fi

if printf '%s' "$ERR" | grep -qF 'ws-self-rs5'; then
  pass "RS5b: stderr names the herdr workspace id (ws-self-rs5) left open by the deferred close that never ran"
else
  fail "RS5b: stderr must name the workspace id left open" "stderr: $ERR"
fi

if printf '%s' "$ERR" | grep -qF 'retire-worktree.sh'; then
  pass "RS5c: stderr tells the caller to re-run retire-worktree.sh"
else
  fail "RS5c: stderr must tell the caller to re-run retire-worktree.sh" "stderr: $ERR"
fi
fi

# ===========================================================================
# DO. --ddev-only: skip the Herdr step, run the DDEV teardown, then stop
#     (exit 0) leaving the worktree checkout and branch for the caller's
#     platform to remove.
# ===========================================================================

# --- DO1: clean worktree with .ddev -> ddev delete, worktree + branch kept.
new_fixture
add_worktree do1
add_ddev_dir do1
export HERDR_LOG="$SANDBOX_BASE/do1-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/do1-ddev.log"; : > "$DDEV_LOG"
# A matching workspace is advertised, so only the --ddev-only skip keeps
# herdr out of the log (DO1e).
HERDR_WORKTREE_LIST_JSON="$(jq -n --arg p "$WTROOT/do1" '{result:{worktrees:[{path:$p, open_workspace_id:"ws-do1"}]}}')"
export HERDR_WORKTREE_LIST_JSON
run_retire "$MAIN" "$WTROOT" full do1 --ddev-only
unset HERDR_WORKTREE_LIST_JSON
if [ "$CODE" -eq 0 ]; then
  pass "DO1a: --ddev-only on a clean worktree exits 0"
else
  fail "DO1a: --ddev-only must exit 0" "exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if grep -qxF $'delete\x1f-yO' "$DDEV_LOG" 2>/dev/null; then
  pass "DO1b: --ddev-only runs ddev delete -yO"
else
  fail "DO1b: expected ddev delete -yO" "ddev log: $(cat "$DDEV_LOG" 2>/dev/null)"
fi
if worktree_still_listed "$MAIN" "$WTROOT/do1" && [ -d "$WTROOT/do1" ] && branch_exists "$MAIN" do1; then
  pass "DO1c: --ddev-only leaves the worktree directory and branch in place"
else
  fail "DO1c: worktree and branch must survive --ddev-only" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi
if printf '%s' "$OUT" | grep -qF -- '--ddev-only: left the worktree and branch in place.' \
   && ! printf '%s' "$OUT" | grep -qF 'retire-worktree: done.'; then
  pass "DO1d: stdout says the worktree and branch were left, with no 'done.' report"
else
  fail "DO1d: expected the --ddev-only line and no 'done.' report" "stdout: $OUT"
fi
if [ ! -s "$HERDR_LOG" ]; then
  pass "DO1e: --ddev-only never calls herdr"
else
  fail "DO1e: herdr must never be called" "herdr log: $(cat "$HERDR_LOG")"
fi

# --- DO2: dirty worktree, --ddev-only without --force -> exit 2, nothing done.
new_fixture
add_worktree do2 --dirty
add_ddev_dir do2
export HERDR_LOG="$SANDBOX_BASE/do2-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/do2-ddev.log"; : > "$DDEV_LOG"
run_retire "$MAIN" "$WTROOT" full do2 --ddev-only
if [ "$CODE" -eq 2 ]; then
  pass "DO2a: --ddev-only on a dirty worktree without --force exits 2"
else
  fail "DO2a: expected exit 2" "exit $CODE
stdout: $OUT
stderr: $ERR"
fi
if [ ! -s "$DDEV_LOG" ]; then
  pass "DO2b: ddev is not called when the dirty check refuses"
else
  fail "DO2b: ddev must not be called" "ddev log: $(cat "$DDEV_LOG")"
fi
if worktree_still_listed "$MAIN" "$WTROOT/do2" && branch_exists "$MAIN" do2; then
  pass "DO2c: the worktree and branch are untouched"
else
  fail "DO2c: nothing may be deleted on refusal" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# --- DO3: --force --ddev-only (flag order swapped) on a dirty worktree ->
#     ddev delete runs, worktree still present.
new_fixture
add_worktree do3 --dirty
add_ddev_dir do3
export HERDR_LOG="$SANDBOX_BASE/do3-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/do3-ddev.log"; : > "$DDEV_LOG"
run_retire "$MAIN" "$WTROOT" full do3 --ddev-only --force
if [ "$CODE" -eq 0 ] && grep -qxF $'delete\x1f-yO' "$DDEV_LOG" 2>/dev/null; then
  pass "DO3a: --ddev-only --force on a dirty worktree runs ddev delete and exits 0"
else
  fail "DO3a: expected exit 0 and ddev delete" "exit $CODE; ddev log: $(cat "$DDEV_LOG" 2>/dev/null)
stderr: $ERR"
fi
if worktree_still_listed "$MAIN" "$WTROOT/do3" && branch_exists "$MAIN" do3 \
   && grep -q 'uncommitted change' "$WTROOT/do3/seed.txt"; then
  pass "DO3b: the dirty worktree, its uncommitted change, and its branch survive"
else
  fail "DO3b: worktree/branch/uncommitted work must survive --ddev-only --force" "worktree list: $(git -C "$MAIN" worktree list 2>&1)"
fi

# --- DO4: --ddev-only with a successful RETIRE_HOOK -> hook replaces ddev
#     delete; worktree still present.
new_fixture
add_worktree do4
add_ddev_dir do4
DO4_HOOK="$SANDBOX_BASE/do4-hook.sh"
printf '#!/usr/bin/env bash\necho hook-ran >> "%s"\n' "$SANDBOX_BASE/do4-hook.log" > "$DO4_HOOK"
chmod +x "$DO4_HOOK"
export HERDR_LOG="$SANDBOX_BASE/do4-herdr.log"; : > "$HERDR_LOG"
export DDEV_LOG="$SANDBOX_BASE/do4-ddev.log"; : > "$DDEV_LOG"
RETIRE_HOOK="$DO4_HOOK" run_retire "$MAIN" "$WTROOT" full do4 --ddev-only
if [ "$CODE" -eq 0 ] && grep -qx hook-ran "$SANDBOX_BASE/do4-hook.log" 2>/dev/null \
   && [ ! -s "$DDEV_LOG" ] && worktree_still_listed "$MAIN" "$WTROOT/do4"; then
  pass "DO4: --ddev-only runs the retire hook in place of ddev delete and keeps the worktree"
else
  fail "DO4: expected hook run, no ddev, worktree kept" "exit $CODE; ddev: $(cat "$DDEV_LOG")
stdout: $OUT
stderr: $ERR"
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
