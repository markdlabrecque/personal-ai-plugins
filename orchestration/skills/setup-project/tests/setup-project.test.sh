#!/usr/bin/env bash
#
# setup-project.sh and the shared resolver (scripts/orch-project.sh).
# Hermetic: a temp ORCH_PROJECTS_DIR, throwaway git repos, no network.
#
#   bash tests/setup-project.test.sh      exit 0 = green

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$SKILL_DIR/scripts/setup-project.sh"
LIB="$(cd "$SKILL_DIR/../.." && pwd -P)/scripts/orch-project.sh"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/orchsp-XXXXXX")" && pwd -P)"
case "$SANDBOX" in */orchsp-??????) ;; *) echo "FATAL: bad sandbox $SANDBOX" >&2; exit 1 ;; esac
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '       %s\n' "$2"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$3', got '$2'"; fi; }

export ORCH_PROJECTS_DIR="$SANDBOX/Projects"
unset PROJECT_NAME WORKTREE_ROOT MAIN_CHECKOUT BASE_BRANCH ORCH_PROJECT_LIB
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# new_project <name> <checkout> [origin-head] -> a project root with a main
# checkout in code/, optionally with origin/HEAD pointing at <origin-head>.
new_project() {
  local root="$ORCH_PROJECTS_DIR/$1" main="$ORCH_PROJECTS_DIR/$1/code/$2"
  mkdir -p "$main"
  git -C "$main" init -q -b main
  git -C "$main" commit -q --allow-empty -m init
  if [ -n "${3:-}" ]; then
    git -C "$main" update-ref "refs/remotes/origin/$3" HEAD
    git -C "$main" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$3"
  fi
  printf '%s' "$root"
}

# --- setup-project ---------------------------------------------------------

root="$(new_project acme acme-site develop)"
mkdir -p "$root/notes"
out="$(cd "$root/notes" && bash "$SCRIPT" 2>&1)"; rc=$?
eq "setup-project succeeds from a subfolder of the project root" "$rc" 0
want="# Orchestration config for this project. Relative paths resolve against this folder.
PROJECT_NAME=acme
MAIN_CHECKOUT=code/acme-site
WORKTREE_ROOT=code
BASE_BRANCH=develop
ACCESSIBILITY_TESTS=false
# Optional. Uncomment to use.
# DB_DUMP=
# PROVISION_HOOK=
# RETIRE_HOOK="
eq "setup-project writes the default template" "$(cat "$root/.orch")" "$want"
[ -d "$root/.agents/orchestration" ] && pass "setup-project creates the state folder" || fail "setup-project creates the state folder"

echo "PROJECT_NAME=edited" > "$root/.orch"
(cd "$root" && bash "$SCRIPT" >/dev/null 2>&1); rc=$?
eq "setup-project refuses to overwrite .orch" "$rc" 1
eq "setup-project leaves the existing .orch alone" "$(cat "$root/.orch")" "PROJECT_NAME=edited"
(cd "$root" && bash "$SCRIPT" --force >/dev/null 2>&1)
eq "setup-project --force rewrites .orch" "$(cat "$root/.orch")" "$want"

root="$(new_project noorigin main)"
out="$(cd "$root" && bash "$SCRIPT" 2>&1)"; rc=$?
eq "setup-project without origin/HEAD still succeeds" "$rc" 0
eq "setup-project leaves BASE_BRANCH empty without origin/HEAD" "$(grep '^BASE_BRANCH' "$root/.orch")" "BASE_BRANCH="
case "$out" in *"Set BASE_BRANCH"*) pass "setup-project says to set BASE_BRANCH" ;; *) fail "setup-project says to set BASE_BRANCH" "$out" ;; esac

mkdir -p "$ORCH_PROJECTS_DIR/empty/code"
(cd "$ORCH_PROJECTS_DIR/empty" && bash "$SCRIPT" >/dev/null 2>&1); rc=$?
eq "setup-project refuses with no main checkout" "$rc" 1
[ ! -e "$ORCH_PROJECTS_DIR/empty/.orch" ] && pass "no .orch written without a main checkout" || fail "no .orch written without a main checkout"

(cd "$SANDBOX" && bash "$SCRIPT" >/dev/null 2>&1); rc=$?
eq "setup-project refuses outside the projects folder" "$rc" 1

# --- resolver --------------------------------------------------------------

# shellcheck source=/dev/null
. "$LIB"

root="$ORCH_PROJECTS_DIR/acme"
git -C "$root/code/acme-site" worktree add -q -b 42 "$root/code/42"
mkdir -p "$root/code/42/web/themes"
for d in "$root" "$root/code" "$root/code/acme-site" "$root/code/42/web/themes"; do
  eq "project root found from ${d#"$ORCH_PROJECTS_DIR"/}" "$(orch_project_root "$d")" "$root"
done

ln -s "$ORCH_PROJECTS_DIR" "$SANDBOX/linked"
eq "project root found through a symlinked projects folder" \
  "$(ORCH_PROJECTS_DIR="$SANDBOX/linked" orch_project_root "$root/code")" "$root"

eq "main checkout ignores linked worktrees" "$(orch_find_main_checkout "$root/code")" "$root/code/acme-site"
orch_find_main_checkout "$ORCH_PROJECTS_DIR/empty/code" >/dev/null 2>&1
eq "main checkout lookup fails with none" "$?" 1
new_project acme2 one >/dev/null; new_project acme2 two >/dev/null
orch_find_main_checkout "$ORCH_PROJECTS_DIR/acme2/code" >/dev/null 2>&1
eq "main checkout lookup fails with two" "$?" 1

printf 'BASE_BRANCH=main\n' > "$root/.orch"
orch_resolve "$root/code/42"
eq "PROJECT_NAME defaults to the folder name" "$PROJECT_NAME" "acme"
eq "WORKTREE_ROOT defaults to <root>/code" "$WORKTREE_ROOT" "$root/code"
eq "MAIN_CHECKOUT defaults to the one checkout" "$MAIN_CHECKOUT" "$root/code/acme-site"

mkdir -p "$SANDBOX/elsewhere"
printf 'PROJECT_NAME="My Big_Client-Site"\nWORKTREE_ROOT=%s\nMAIN_CHECKOUT=code/acme-site\n' "$SANDBOX/elsewhere" > "$root/.orch"
orch_resolve "$root"
eq "PROJECT_NAME from .orch, sanitized and not cut" "$PROJECT_NAME" "my-big-client-site"
eq "WORKTREE_ROOT from .orch" "$WORKTREE_ROOT" "$SANDBOX/elsewhere"
eq "PROJECT_NAME from the environment wins" "$(export PROJECT_NAME=envname; . "$LIB"; orch_resolve "$root"; printf '%s' "$PROJECT_NAME")" "envname"

rm "$root/.orch"
orch_resolve "$root" >/dev/null 2>&1
eq "orch_resolve refuses without .orch" "$?" 1

eq "ddev name for a ticket id" "$(ddev_project_name 42 my-big-client-site)" "42-my-big-client-site"
eq "ddev name for a long branch" "$(ddev_project_name Feature/One-Two-Three acme)" "feature-one-two-acme"
eq "ddev name keeps the whole ticket number" "$(ddev_project_name 12345-fix-it acme)" "12345-acme"

printf '%d passed, %d failed, 0 skipped\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
