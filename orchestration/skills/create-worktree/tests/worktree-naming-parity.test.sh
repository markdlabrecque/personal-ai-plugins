#!/usr/bin/env bash
#
# Ticket #394 (item A): the DDEV project naming rule lives as FOUR separate
# copies -- scripts/setup-worktree.sh's ddev_project_name(),
# scripts/retire-worktree.sh's ddev_project_name(), and a derive_ddev_name()
# reference implementation restated inside each of
# tests/repo/setup-worktree-agent.test.sh and tests/repo/retire-worktree.test.sh.
# Each production copy is pinned only against its OWN suite's reference, so a
# coordinated edit of one production script plus its own test's reference
# passes both suites while the two production scripts quietly disagree.
#
# This suite extracts ddev_project_name() DIRECTLY out of both production
# scripts (never re-typing the rule) and:
#   1. runs both extracted copies over the same input list, asserting
#      byte-identical output per input;
#   2. asserts the two extracted function source blocks are byte-identical to
#      each other -- a direct drift tripwire that names which script differs,
#      even on an input where the two functions happen to still agree.
#
# Post-promotion (worktree-promotion-spec.md): the suffix is no longer the
# literal `-acme-site` -- it is derived from the MAIN CHECKOUT'S BASENAME,
# sanitized the same way as the id. ddev_project_name() therefore now takes a
# SECOND argument: `ddev_project_name <branch-or-id> <main-checkout-basename>`.
# A main checkout literally named `acme-site` must still yield the
# `-acme-site` suffix -- that pin is what protects live DDEV projects
# from being renamed out from under them (section A below). Section C
# exercises the generic derivation itself (other basenames, uppercase,
# dots/underscores).
#
# This suite now reaches across TWO SIBLING skill directories --
# create-worktree/scripts/setup-worktree.sh and
# retire-worktree/scripts/retire-worktree.sh -- rather than one repo's
# scripts/ directory, since the two engines live in the base/override split's
# global skills, not a project checkout.
#
# Harness style matches tests/setup-worktree-agent.test.sh and
# retire-worktree/tests/retire-worktree.test.sh: same pass/fail/skip helpers,
# same BASH_SOURCE-derived resolution, same "N passed, N failed, N skipped"
# summary line.
#
# Run from anywhere:
#   bash worktree-naming-parity.test.sh
#
# Requires: bash. No git repo required. Exit 0 = green.

set -uo pipefail

# Derived from BASH_SOURCE, not `git rev-parse --show-toplevel` -- this suite
# must run from any cwd and must not require a git repo, and it must reach
# across two sibling skill directories rather than one repo's scripts/.
CREATE_WORKTREE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RETIRE_WORKTREE_DIR="$(cd "$CREATE_WORKTREE_DIR/../retire-worktree" && pwd -P)"
SETUP_SCRIPT="$CREATE_WORKTREE_DIR/scripts/setup-worktree.sh"
RETIRE_SCRIPT="$RETIRE_WORKTREE_DIR/scripts/retire-worktree.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/naming-parity-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

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
# Extract the ddev_project_name() function body verbatim out of a production
# script: from the line declaring the function through the next line that is
# exactly "}" (the function has no nested top-level braces -- its `for`/`if`
# blocks close with `done`/`fi`, not `}`).
# ---------------------------------------------------------------------------
extract_fn() { # extract_fn <script-path> -> prints the function source on stdout
  awk '
    /^ddev_project_name\(\) \{/ { p = 1 }
    p { print }
    p && /^}$/ { exit }
  ' "$1"
}

FN_SETUP="$SANDBOX/fn-setup.sh"
FN_RETIRE="$SANDBOX/fn-retire.sh"

if [ -f "$SETUP_SCRIPT" ]; then
  extract_fn "$SETUP_SCRIPT" > "$FN_SETUP"
else
  : > "$FN_SETUP"
fi

if [ -f "$RETIRE_SCRIPT" ]; then
  extract_fn "$RETIRE_SCRIPT" > "$FN_RETIRE"
else
  : > "$FN_RETIRE"
fi

if [ ! -s "$FN_SETUP" ]; then
  echo "FATAL: could not extract ddev_project_name() from create-worktree/scripts/setup-worktree.sh" >&2
  exit 1
fi
if [ ! -s "$FN_RETIRE" ]; then
  echo "FATAL: could not extract ddev_project_name() from retire-worktree/scripts/retire-worktree.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Z. The two extracted function source blocks must be byte-identical. This is
#    the direct drift tripwire: if it fails, the diff below names exactly
#    which script changed.
# ---------------------------------------------------------------------------
if cmp -s "$FN_SETUP" "$FN_RETIRE"; then
  pass "Z0: ddev_project_name() is byte-identical between scripts/setup-worktree.sh and scripts/retire-worktree.sh"
else
  fail "Z0: ddev_project_name() has drifted between scripts/setup-worktree.sh and scripts/retire-worktree.sh" \
"$(diff -u "$FN_RETIRE" "$FN_SETUP" 2>&1 | sed -e "s#$FN_RETIRE#retire-worktree.sh#" -e "s#$FN_SETUP#setup-worktree.sh#")"
fi

# ---------------------------------------------------------------------------
# call_fn <fn-file> <input> <main-checkout-basename> -> prints
# ddev_project_name(<input>, <main-checkout-basename>) on stdout. Runs the
# extracted function body in its own bash -c, with both arguments passed as
# real positional parameters (never interpolated into a command string), so
# an input like '$(touch /tmp/pwned)' is inert data, not something the shell
# evaluates.
# ---------------------------------------------------------------------------
call_fn() {
  bash -c 'source "$1"; ddev_project_name "$2" "$3"' _bash "$1" "$2" "$3" 2>/dev/null
}

# ---------------------------------------------------------------------------
# A. Both extracted copies must agree, byte-for-byte, on every input, with
#    the main checkout basename PINNED to "acme-site" -- this is the
#    regression guard named in the promotion spec: a main checkout literally
#    named acme-site must still yield the `-acme-site` suffix once
#    that suffix is derived generically, or every live DDEV project under
#    that name gets silently renamed out from under it.
# ---------------------------------------------------------------------------
POISON_MARKER="$SANDBOX/pwned"
rm -f "$POISON_MARKER"

check_parity() { # check_parity <label> <input> [<basename>]
  local label="$1" input="$2" basename="${3:-acme-site}" got_setup got_retire
  got_setup="$(call_fn "$FN_SETUP" "$input" "$basename")"
  got_retire="$(call_fn "$FN_RETIRE" "$input" "$basename")"
  if [ "$got_setup" = "$got_retire" ]; then
    pass "$label: setup-worktree.sh and retire-worktree.sh agree on input '$input' (basename '$basename') -> '$got_setup'"
  else
    fail "$label: setup-worktree.sh and retire-worktree.sh DISAGREE on input '$input' (basename '$basename')" \
"create-worktree/scripts/setup-worktree.sh  -> '$got_setup'
retire-worktree/scripts/retire-worktree.sh -> '$got_retire'"
  fi
}

check_parity "A01" "0386"
check_parity "A02" "382_x"
check_parity "A03" "12-34-56-78"
check_parity "A04" "feat/382-x"
check_parity "A05" '$(touch /tmp/pwned)'
check_parity "A06" "café-382"
check_parity "A07" "---"
check_parity "A08" ""
check_parity "A09" "1024"
check_parity "A10" "10000"
check_parity "A11" "field-toggles"
check_parity "A12" "field-toggles-a-b-c-d"
check_parity "A13" "FEAT-382-Fix"
check_parity "A14" $'382-trunk-layout-backfill\r'
check_parity "A15" "382-trunk-layout-backfill"

# A18: the pinned regression itself, spelled out explicitly rather than left
# implicit in the "acme-site" default above -- a main checkout named
# `acme-site` must derive the suffix "-acme-site" from EITHER engine.
a18_setup="$(call_fn "$FN_SETUP" "393" "acme-site")"
a18_retire="$(call_fn "$FN_RETIRE" "393" "acme-site")"
if [ "$a18_setup" = "393-acme-site" ] && [ "$a18_retire" = "393-acme-site" ]; then
  pass "A18: a main checkout named 'acme-site' still yields the '-acme-site' suffix on both engines"
else
  fail "A18: a main checkout named 'acme-site' must still yield '-acme-site' (live DDEV projects depend on this)" \
"create-worktree/scripts/setup-worktree.sh  -> '$a18_setup'
retire-worktree/scripts/retire-worktree.sh -> '$a18_retire'"
fi

# ---------------------------------------------------------------------------
# C. Generic derivation: both engines must agree on a suffix derived from
#    OTHER main-checkout basenames too -- uppercase, dots, underscores, and
#    a name with digits leading (which must NOT be confused with the id's
#    own leading-digit-run rule; the basename is sanitized independently).
#
#    check_parity alone (mutual agreement) is NOT enough here: an engine
#    that simply IGNORES the second argument and always appends the literal
#    "-acme-site" would still pass every check_parity call below, since
#    both copies would agree on the same (wrong) constant. check_derived
#    additionally pins the ACTUAL expected output, so failing to implement
#    basename derivation shows up here, not just a cross-script drift.
# ---------------------------------------------------------------------------
check_derived() { # check_derived <label> <input> <basename> <expected>
  local label="$1" input="$2" basename="$3" expected="$4" got_setup got_retire
  got_setup="$(call_fn "$FN_SETUP" "$input" "$basename")"
  got_retire="$(call_fn "$FN_RETIRE" "$input" "$basename")"
  if [ "$got_setup" = "$expected" ] && [ "$got_retire" = "$expected" ]; then
    pass "$label: basename '$basename' derives suffix '$expected' on both engines"
  else
    fail "$label: basename '$basename' must derive suffix '$expected' (not the literal '-acme-site')" \
"expected: $expected
create-worktree/scripts/setup-worktree.sh  -> '$got_setup'
retire-worktree/scripts/retire-worktree.sh -> '$got_retire'"
  fi
}

check_parity "C01" "393" "webapp"
check_derived "C01d" "393" "webapp" "393-webapp"
check_parity "C02" "393" "WebApp"
check_derived "C02d" "393" "WebApp" "393-webapp"
check_parity "C03" "393" "my.project_name"
check_derived "C03d" "393" "my.project_name" "393-my-project-name"
check_parity "C04" "393" "382-worktree-tickets"
check_derived "C04d" "393" "382-worktree-tickets" "393-382-worktree-tickets"
check_parity "C05" "393" ""
check_parity "C06" "393" "UPPER_CASE.Repo"
check_derived "C06d" "393" "UPPER_CASE.Repo" "393-upper-case-repo"

if [ -e "$POISON_MARKER" ]; then
  fail "A16: input '\$(touch /tmp/pwned)' must never be evaluated by the shell" \
"$POISON_MARKER was created -- the harness (or the function under test) evaluated attacker-controlled input as a command."
else
  pass "A16: input '\$(touch /tmp/pwned)' is treated as inert data, never evaluated"
fi

# Also make sure it didn't poison the REAL /tmp/pwned that the spec's example
# literally names, in case some layer resolved the path outside the sandbox.
if [ -e /tmp/pwned ]; then
  fail "A17: /tmp/pwned must never be created by this suite" \
"/tmp/pwned exists on the real filesystem -- clean it up and find where the shell evaluated it."
  rm -f /tmp/pwned
else
  pass "A17: /tmp/pwned was never created on the real filesystem"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
