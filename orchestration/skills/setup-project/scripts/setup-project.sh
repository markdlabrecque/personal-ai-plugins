#!/usr/bin/env bash
set -euo pipefail

# Write <project root>/.orch with every key at its default, derived from the
# folder layout, and create the orch state folder.
#
#   setup-project.sh [--force]
#
# Run from anywhere inside $ORCH_PROJECTS_DIR/<project> (default ~/Projects).
# The main checkout must already be cloned into <project>/code/. Environment
# overrides are ignored: the template records the layout's own defaults.
# Refuses when .orch exists unless --force is given.

LIB="${ORCH_PROJECT_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)/scripts/orch-project.sh}"
# shellcheck source=../../../scripts/orch-project.sh
. "$LIB"

force=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    *) echo "usage: $(basename "$0") [--force]" >&2; exit 1 ;;
  esac
done

root="$(orch_project_root "$PWD")"
orch="$root/.orch"

if [ -e "$orch" ] && [ "$force" -ne 1 ]; then
  echo "setup-project: $orch already exists. Re-run with --force to overwrite it." >&2
  exit 1
fi

main="$(orch_find_main_checkout "$root/code" 2>/dev/null)" || {
  echo "setup-project: no single main checkout in $root/code. Clone the repository into $root/code/ first." >&2
  exit 1
}

base="$(git -C "$main" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
base="${base#origin/}"

tmp="$(mktemp "$root/.orch.XXXXXX")"
cat > "$tmp" <<ORCH
# Orchestration config for this project. Relative paths resolve against this folder.
PROJECT_NAME=$(basename "$root")
MAIN_CHECKOUT=code/$(basename "$main")
WORKTREE_ROOT=code
BASE_BRANCH=$base
ACCESSIBILITY_TESTS=false
# Optional. Uncomment to use.
# DB_DUMP=
# PROVISION_HOOK=
# RETIRE_HOOK=
ORCH
mv "$tmp" "$orch"
mkdir -p "$root/.agents/orchestration"

echo "setup-project: wrote $orch."
if [ -z "$base" ]; then
  echo "setup-project: could not read origin/HEAD in $main. Set BASE_BRANCH in $orch before creating worktrees." >&2
fi
