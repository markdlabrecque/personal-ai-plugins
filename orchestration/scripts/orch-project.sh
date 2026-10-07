# shellcheck shell=bash
#
# Shared project-root resolver for the worktree engines and setup-project.
# Sourced, never executed. Bash 3.2 compatible (macOS /bin/bash).
#
# Layout:
#
#   $ORCH_PROJECTS_DIR/<project>/        project root (default ~/Projects/<project>)
#   ├── .orch                            KEY=VALUE config
#   ├── .agents/orchestration/           orch state
#   └── code/                            default WORKTREE_ROOT
#       ├── <main checkout>/
#       └── <id>/                        ticket worktrees
#
# Every key resolves: environment variable, then <root>/.orch, then default.
# Relative paths in .orch resolve against the project root.

# The environment as it was when this file was sourced. orch_resolve sets
# PROJECT_NAME and friends itself, so reading them live would let one resolve
# leak into the next.
ORCH_KEYS="PROJECT_NAME MAIN_CHECKOUT WORKTREE_ROOT BASE_BRANCH DB_DUMP PROVISION_HOOK RETIRE_HOOK ACCESSIBILITY_TESTS"
for _orch_k in $ORCH_KEYS; do
  eval "_ORCH_ENV_$_orch_k=\"\${$_orch_k-}\""
done
unset _orch_k

# orch_projects_dir -> real path of the projects folder, rc1 if missing.
orch_projects_dir() {
  (cd "${ORCH_PROJECTS_DIR:-$HOME/Projects}" 2>/dev/null && pwd -P)
}

# orch_project_root [dir] -> the folder directly under the projects folder
# that contains <dir> (default $PWD). rc1 with a message when <dir> is not
# inside one.
orch_project_root() {
  local start projects rest
  start="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || {
    echo "orch: no such directory: ${1:-$PWD}" >&2
    return 1
  }
  projects="$(orch_projects_dir)" || {
    echo "orch: projects folder ${ORCH_PROJECTS_DIR:-$HOME/Projects} does not exist." >&2
    return 1
  }
  case "$start/" in
    "$projects"/?*/)
      rest="${start#"$projects"/}"
      printf '%s/%s' "$projects" "${rest%%/*}"
      ;;
    *)
      echo "orch: $start is not inside a project folder ($projects/<project-name>)." >&2
      return 1
      ;;
  esac
}

# orch_read <root> <KEY> -> the last KEY=value in <root>/.orch, quotes
# stripped, or empty. A single sed pass, so an odd line can't abort a caller
# running under `set -euo pipefail`.
orch_read() {
  local root="$1" key="$2"
  [ -f "$root/.orch" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$root/.orch" |
    tail -n 1 |
    tr -d '\r' |
    sed -e "s/^['\"]//" -e "s/['\"]\$//"
}

# orch_get <root> <KEY> -> environment variable (as sourced), then .orch, or
# empty.
orch_get() {
  local root="$1" key="$2" val
  eval "val=\"\${_ORCH_ENV_$key-}\""
  if [ -n "$val" ]; then
    printf '%s' "$val"
  else
    orch_read "$root" "$key"
  fi
}

# orch_abs <root> <path> -> <path> made absolute against <root>.
orch_abs() {
  case "$2" in
    /*) printf '%s' "$2" ;;
    *) printf '%s/%s' "$1" "$2" ;;
  esac
}

# orch_sanitize <name> -> lowercase, a-z0-9- only, hyphens collapsed and
# trimmed. LC_ALL=C so accented letters are replaced, not passed through
# (DDEV rejects them).
orch_sanitize() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
    LC_ALL=C sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-//; s/-$//'
}

# orch_find_main_checkout <worktree_root> -> the one child folder whose .git
# is a directory (linked worktrees have a .git file). rc1 when there is none
# or more than one.
orch_find_main_checkout() {
  local wt_root="$1" d found="" n=0
  for d in "$wt_root"/*/; do
    [ -d "$d.git" ] || continue
    found="${d%/}"
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    echo "orch: no main checkout in $wt_root. Clone the repository into it first." >&2
    return 1
  fi
  if [ "$n" -gt 1 ]; then
    echo "orch: more than one git checkout in $wt_root. Set MAIN_CHECKOUT in .orch." >&2
    return 1
  fi
  (cd "$found" && pwd -P)
}

# orch_resolve [dir] -- for the engines. Needs <root>/.orch. Sets:
#   ORCH_ROOT       project root (real path)
#   PROJECT_NAME    sanitized; default the project root's folder name
#   WORKTREE_ROOT   absolute; default <root>/code
#   MAIN_CHECKOUT   absolute; default the one git checkout in WORKTREE_ROOT
orch_resolve() {
  local start="${1:-$PWD}" root raw wt main common
  # A worktree under a WORKTREE_ROOT outside the project root still finds it
  # through its main checkout.
  if ! root="$(orch_project_root "$start" 2>/dev/null)"; then
    common="$(git -C "$start" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
      root="$(orch_project_root "$(dirname "$common")" 2>/dev/null)" ||
      { orch_project_root "$start" >/dev/null; return 1; }
  fi
  if [ ! -f "$root/.orch" ]; then
    echo "orch: $root/.orch not found. Run the orchestration:setup-project skill first." >&2
    return 1
  fi
  raw="$(orch_get "$root" PROJECT_NAME)"
  raw="$(orch_sanitize "${raw:-$(basename "$root")}")"
  if [ -z "$raw" ]; then
    echo "orch: PROJECT_NAME is empty after sanitizing." >&2
    return 1
  fi
  wt="$(orch_get "$root" WORKTREE_ROOT)"
  wt="$(orch_abs "$root" "${wt:-code}")"
  main="$(orch_get "$root" MAIN_CHECKOUT)"
  if [ -n "$main" ]; then
    main="$(orch_abs "$root" "$main")"
    main="$(cd "$main" 2>/dev/null && pwd -P)" || {
      echo "orch: MAIN_CHECKOUT $(orch_get "$root" MAIN_CHECKOUT) does not exist." >&2
      return 1
    }
  else
    main="$(orch_find_main_checkout "$wt")" || return 1
  fi
  ORCH_ROOT="$root"
  PROJECT_NAME="$raw"
  WORKTREE_ROOT="$wt"
  MAIN_CHECKOUT="$main"
}

# ddev_project_name <branch-or-id> <project-name> -> <id-part>-<project-name>.
# The id is sanitized and capped at 3 hyphen segments, except an all-digit
# leading segment, which is kept whole and alone (ticket numbers never
# truncate). The project name is sanitized only, never cut.
ddev_project_name() {
  local sanitized id_part project
  sanitized="$(orch_sanitize "$1")"
  case "$sanitized" in
    [0-9]*)
      id_part="${sanitized%%-*}"
      case "$id_part" in
        *[!0-9]*) id_part="" ;;
      esac
      ;;
    *) id_part="" ;;
  esac
  if [ -z "$id_part" ]; then
    id_part="$(printf '%s' "$sanitized" | cut -d- -f1-3)"
  fi
  [ -n "$id_part" ] || id_part="worktree"
  project="$(orch_sanitize "$2")"
  printf '%s-%s' "$id_part" "${project:-worktree}"
}
