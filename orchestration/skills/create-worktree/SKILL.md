---
name: create-worktree
description: Create and provision a Git worktree (plain `git worktree add`, plus DDEV/composer/DB provisioning) in a project folder set up with `.orch`. Ticket worktrees are created for the `orchestration` plugin's main orchestrator.
---

# Create a worktree

This skill is a **base/override pair** (worktree-promotion-spec.md): a
generic engine here, plus an optional thin per-project shim that configures
and delegates to it. The project layer is always the entry point.

```
  caller (a human, an orchestrator, this skill)
        |
        v
  <project>/scripts/setup-worktree.sh      <- optional, thin. Project config
        |  (DB_DUMP, etc.), then delegates.  only, then delegates.
        v
  ${CLAUDE_PLUGIN_ROOT}/skills/create-worktree/scripts/setup-worktree.sh   <- this engine
```

Projects live in `~/Projects/<project>/` (`ORCH_PROJECTS_DIR` overrides),
with the main checkout cloned by the user into `code/` and `.orch` written by
the `setup-project` skill. The engine walks up from the current directory to
the project root, so it runs from anywhere inside it: the root, `code/`, the
main checkout or a worktree. No `.orch` → it stops and says to run
`setup-project`.

A project with **no shim at all** works: run this engine directly, or point
`WORKTREE_ENGINE` at it. Worktrees land in `<WORKTREE_ROOT>/<id>` (default
`<project root>/code/<id>`). DDEV names are `<id>-<PROJECT_NAME>` for
worktrees and `<PROJECT_NAME>` for the main checkout, which the engine
writes once into the main checkout's `.ddev/config.local.yaml` when that has
no name yet (an existing different name is kept, with a warning). There is
no default database dump.

## Running it

```
scripts/setup-worktree.sh <id> [--no-db]          # create (git worktree add) + provision
scripts/setup-worktree.sh --provision [--no-db]   # provision the worktree at $PWD only
```

**Always go through the engine.** Never run `git worktree add` by hand, and
never skip the provisioning step, even when only part of it is wanted. The
engine writes `.ddev/config.local.yaml`, wires git hooks and starts DDEV;
a hand-made worktree silently misses all of that. If the engine can't do what
was asked, stop and ask the user instead of working around it.

- **Existing branch**: pass its name as `<id>`. A local branch is checked
  out; a branch that only exists on origin is checked out tracking
  `origin/<id>`. Only a name that exists nowhere is cut from `BASE_BRANCH`.
- **`--no-db`**: provisions everything except the database (no import, no
  `drush deploy`). Use it when the user wants the database left alone, for
  example while a fresh dump is still being made. It is passed on to the
  project's provision hook.

This skill only creates and provisions a worktree; it never starts an agent
session. Ticket sessions are launched by the `orchestration:orchestration`
skill, whose main orchestrator calls this skill to create each ticket
worktree. For a ticket, use the ticket identifier alone as the worktree
name, such as `19`.

`<id>` becomes the worktree directory name and the branch name, verbatim
(lowercase letters, digits, hyphens only), and seeds the DDEV project name
(sanitized/capped separately).

Read `BASE_BRANCH` from `<project root>/.orch` before creating a worktree. If the file or value is missing, stop without creating anything. Use it for rebases and PR/MR targeting. The engine reads the same value itself; it never substitutes the checked-out branch or repository default.

## The project provision hook

After `git worktree add`, mode 1 provisions through the project's hook if
it has one. Resolved as: `PROVISION_HOOK` in the environment, then
`PROVISION_HOOK` in `.orch`, then the conventional
`<worktree>/scripts/setup-worktree.sh`, called with `--provision` and cwd
set to the new worktree. If none of those exists on disk, this engine runs
its own provisioning directly; a project with no shim is not required to
have one. Recursion guard: `--provision` mode itself never calls the hook.

Both modes provision **conditionally** on what the worktree actually
contains: `git config core.hooksPath scripts/githooks` only when that
directory exists; the whole DDEV leg (start, composer install, db import)
only when the worktree has a `.ddev/` directory or a `composer.json`;
`ddev composer install` within that leg only when `composer.json` exists.
No `.ddev/` and no `composer.json` is a plain worktree and a success, not a
warning. `--provision` on a project with only a `composer.json` and no
`.ddev/config.yaml` still fails at `ddev start`, with a message naming the
missing config.

In both modes, a **fresh** `ddev import-db` (the branch that actually ran the
import, not an already-populated DB, no dump, or a failed `ddev mysql`) on a
Drupal site (`.ddev/config.yaml`'s `type:` starts with `drupal`) is followed
by `ddev drush deploy`, so the checked-out code and the just-imported DB
agree. A failing `drush deploy` is a warning on stderr naming the re-run
command, not a run failure — provisioning still finishes and still exits 0.

## Layers, precisely

Every caller hits the **project layer** first:
`<project>/scripts/setup-worktree.sh`, if the project has one. That file is
not the engine; it is a thin shim that sets a handful of environment
variables (project config: `DB_DUMP`, `WORKTREE_ROOT`, etc.) and then
`exec`s straight into this engine. The shim is the stable, project-local
entry point; the engine underneath it can move, get upgraded, or be pointed
at via `WORKTREE_ENGINE` without touching any caller.

If a project has **no shim at all**, callers point straight at this engine
(directly, or via `WORKTREE_ENGINE`) and it still works — see "Adopting
this on a new project" below.

## Overrides

Every one of these follows the same precedence unless a row says otherwise:
**environment variable, then the same-named key in `<project root>/.orch`,
then the convention/default in the last column.** Relative paths in `.orch`
resolve against the project root.

| Variable | What it does | Default / convention | Read from |
|---|---|---|---|
| `WORKTREE_ENGINE` | Path to this engine, for a project shim (or a direct call) to delegate to. `orch` sets it when it calls a project shim. | `${CLAUDE_PLUGIN_ROOT}/skills/create-worktree/scripts/setup-worktree.sh` | environment only (a shim sets this itself; `.orch` is not consulted) |
| `PROJECT_NAME` | DDEV names: `<PROJECT_NAME>` for the main checkout, `<id>-<PROJECT_NAME>` for worktrees. Sanitized (lowercase, `a-z0-9-`), never cut. | the project root's folder name | environment, `.orch` |
| `MAIN_CHECKOUT` | The main checkout. | the one folder in `WORKTREE_ROOT` whose `.git` is a directory | environment, `.orch` |
| `BASE_BRANCH` | Branch new worktrees are cut from. | none; missing value refuses creation | environment, `.orch` |
| `DB_DUMP` | Database dump to import during provisioning, either mode. Relative paths resolve against the project root. | none — no import happens without one. A project that wants a default sets `DB_DUMP` in `.orch` | environment, then `.orch` |
| `WORKTREE_ROOT` | Where worktrees live on disk. | `<project root>/code` | environment, `.orch` |
| `PROVISION_HOOK` | Path to a project's own provisioning script, run instead of this engine's own mode-1 provisioning. | conventional `<worktree>/scripts/setup-worktree.sh --provision` | environment, `.orch`, convention |
| `RETIRE_HOOK` | Teardown counterpart of `PROVISION_HOOK`; see `retire-worktree/SKILL.md`. | conventional `<worktree>/scripts/retire-worktree.sh` | environment, `.orch`, convention |

All also documented at the top of `scripts/setup-worktree.sh`. The lookup itself lives in `scripts/orch-project.sh` at the plugin root, shared with the retire and reap engines and `setup-project` (`ORCH_PROJECT_LIB` overrides its path, for tests).

## Conventions without a project shim

No project shim is required. Worktree creation still requires `BASE_BRANCH` (in `.orch` or the environment):

- **Provision hook**: `<worktree>/scripts/setup-worktree.sh --provision`, run
  with cwd set to the new worktree, whenever `PROVISION_HOOK` doesn't
  resolve to something else first.
- **Retire hook**: `<worktree>/scripts/retire-worktree.sh` (see
  `retire-worktree/SKILL.md`), the same shape on the teardown side.
- **`.orch` keys this engine reads**, each only when the matching
  environment variable is unset: `PROJECT_NAME`, `MAIN_CHECKOUT`,
  `BASE_BRANCH`, `DB_DUMP`, `WORKTREE_ROOT`, `PROVISION_HOOK`.

## Adopting this on a new project

1. **No shim needed for a plain repository.** Run `setup-project` and check `BASE_BRANCH` in `.orch`. A project
   with no `.ddev/`, no `composer.json`, and no `scripts/githooks`
   works without a provision hook: point a caller (or `WORKTREE_ENGINE`)
   straight at this engine, and worktree creation, DDEV-leg skipping, and
   hooksPath-skipping work without warnings. This is a normal,
   fully-supported case, not a degraded path.
2. **Add a shim only if the project has config to set** — a fixed `DB_DUMP`,
   `WORKTREE_ROOT`, hook overrides, etc. The shim is a few lines: set the
   variables, then
   `exec "${WORKTREE_ENGINE:-$CLAUDE_PLUGIN_ROOT/skills/create-worktree/scripts/setup-worktree.sh}" "$@"`.
   One engine serves many projects: the shim carries only the
   project-specific overrides.
3. **Skip the retire/reap shims** unless the project needs project-specific
   teardown behaviour (a `RETIRE_HOOK`, a non-default `WORKTREE_ROOT`
   already covered by the create shim's env, etc.) — the global engines in
   `retire-worktree/scripts/` work directly with no project file at all.

## Tests

`tests/run-all.sh` runs this skill's two suites plus the two sibling
`retire-worktree` suites and prints a combined verdict. **These suites are
manual: nothing in CI runs them**, in this repo or in any adopting project —
run `bash tests/run-all.sh` yourself after changing either engine, before
relying on the change. The `retire-worktree` suites need bash 4+ first on
`PATH` (macOS `/bin/bash` is 3.2).
