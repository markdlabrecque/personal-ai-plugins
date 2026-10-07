#!/usr/bin/env bash
#
# Runs all four worktree-tooling suites -- the two that live here
# (create-worktree/tests/) plus the two sibling suites in
# retire-worktree/tests/ -- and prints a per-suite verdict plus a combined
# summary. Exit 1 if any suite failed (a non-zero exit OR a non-empty
# "N failed" count in its own summary line), exit 0 only when every suite is
# green.
#
# Derived from BASH_SOURCE, not `git rev-parse --show-toplevel` -- this must
# run from any cwd and must not require a git repo.
#
# Run from anywhere:
#   bash run-all.sh
# or, from elsewhere:
#   bash <plugin>/skills/create-worktree/tests/run-all.sh   (needs bash 4+)

set -uo pipefail

CREATE_WORKTREE_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CREATE_WORKTREE_DIR="$(cd "$CREATE_WORKTREE_TESTS/.." && pwd -P)"
RETIRE_WORKTREE_DIR="$(cd "$CREATE_WORKTREE_DIR/../retire-worktree" && pwd -P)"
RETIRE_WORKTREE_TESTS="$RETIRE_WORKTREE_DIR/tests"

SUITES=(
  "$CREATE_WORKTREE_TESTS/setup-worktree-agent.test.sh"
  "$CREATE_WORKTREE_TESTS/worktree-naming-parity.test.sh"
  "$RETIRE_WORKTREE_TESTS/retire-worktree.test.sh"
  "$RETIRE_WORKTREE_TESTS/reap-worktrees.test.sh"
)

overall_fail=0

for suite in "${SUITES[@]}"; do
  name="$(basename "$suite")"
  echo "=== $name ==="
  if [ ! -f "$suite" ]; then
    echo "FATAL: $suite not found"
    overall_fail=1
    continue
  fi
  out="$(bash "$suite" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  summary="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$' | tail -n 1)"
  failed_count=""
  if [ -n "$summary" ]; then
    failed_count="$(printf '%s\n' "$summary" | sed -E 's/^[0-9]+ passed, ([0-9]+) failed,.*/\1/')"
  fi
  if [ "$rc" -ne 0 ] || [ -z "$summary" ] || [ "${failed_count:-1}" != "0" ]; then
    echo "--- $name: FAILED (exit $rc) ---"
    overall_fail=1
  else
    echo "--- $name: PASSED ---"
  fi
  echo
done

if [ "$overall_fail" -ne 0 ]; then
  echo "run-all: at least one suite failed."
  exit 1
fi

echo "run-all: all suites green."
exit 0
