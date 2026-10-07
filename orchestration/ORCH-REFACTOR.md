# Orchestration refactor: wrapper-folder project layout

Status: implemented in 0.7.0 on `feat/orch-project-root`. Step 10 (migrate one real project by hand) is still open.

## Proposed layout

```
~/Projects/<project-name>/          # project root (wrapper folder); not under version control; notes, docs, scratch
├── .orch                           # per-project orchestration config (KEY=VALUE), written by setup-project
├── .agents/orchestration/          # orchestrator state: state.db, logs/, briefs/, config.json
└── code/                           # default WORKTREE_ROOT
    ├── <main-checkout>/            # main git checkout (any folder name); DDEV name: <PROJECT_NAME>
    ├── 19/                         # ticket worktree; DDEV name: 19-<PROJECT_NAME>
    └── 42/                         # ticket worktree; DDEV name: 42-<PROJECT_NAME>
```

`.orch` holds the per-project orchestration settings (`PROJECT_NAME`, `MAIN_CHECKOUT`, `WORKTREE_ROOT`, `BASE_BRANCH`, `DB_DUMP`, `PROVISION_HOOK`, `RETIRE_HOOK`, `ACCESSIBILITY_TESTS`). Today these settings live in the main checkout's `.env`.

## How it works today

Location: ~/skills/personal/orchestration

- `create-worktree/scripts/setup-worktree.sh`, `retire-worktree/scripts/retire-worktree.sh` and `reap-worktrees.sh` each carry their own copy of a small `.env` reader. Each reads `<main checkout>/.env`.
- `scripts/orch` (Python) also reads `BASE_BRANCH` from `<main checkout>/.env`, in three places (`create_worktree`, the preflight check, and selftest).
- The orchestration skill reads `ACCESSIBILITY_TESTS` from the main checkout's `.env`.
- Every script finds the main checkout through git, so it must run from inside the main checkout or a worktree.
- Orchestrator state lives in `<main checkout>/.agents/orchestration/` (`ORCH_HOME` overrides): `state.db` (tickets, events, CI results, selftest runs), `logs/`, `briefs/`, and the optional `config.json` (`verify_harness`). `orch init` writes a `.gitignore` there to keep it out of git.
- The `orch hook` (Claude Code hooks) and the Pi extension find the state dir through git from the session's cwd. The hook skips sessions whose cwd is the main checkout (`in_main`): that is how it tells the main orchestrator from a ticket orchestrator.
- Settings are resolved in this order: environment variable, then the main checkout's `.env`, then the built-in default.
- The default `WORKTREE_ROOT` is `$HOME/Projects/worktrees/<main-checkout-basename>`.
- DDEV project names are `<id>-<main-checkout-basename>`, written as `name:` in the worktree's `.ddev/config.local.yaml`. The basename is sanitized and cut to its first three hyphen segments (`ddev_project_name`, duplicated in setup and retire).
- The engines never write the main checkout's `.ddev/config.local.yaml`.
- `BASE_BRANCH` is required. Worktree creation refuses to run without it.

## What stays the same

- `BASE_BRANCH` keeps its meaning. Only the file it is read from changes.
- `.orch` uses the same `KEY=VALUE` format as `.env`, so the existing sed-based reader works unchanged. Only the path changes.

## Requirements

### Assumptions

- The user clones the main checkout by hand. It is already in place before `setup-project` or `create-worktree` runs. No skill clones anything.
- `create-worktree` (and `retire-worktree`, `orch`) can run from anywhere inside `~/Projects/<project-name>`: the project root itself, `code/`, the main checkout, a worktree, or any folder below them.

### Project root lookup

The scripts walk up from the current directory to find the project root: the folder directly under `~/Projects` on the current path. Example: cwd `~/Projects/foo/code/42/web/themes` → project root `~/Projects/foo`.

- Compare real paths (`pwd -P`) on both sides, so a symlinked `~/Projects` still works.
- Not under `~/Projects/<something>/` → stop with a clear error.
- `.orch` lives at `<project root>/.orch`. Missing `.orch` → stop and tell the user to run `orchestration:setup-project`.
- Relative paths in `.orch` resolve against the project root.

### Main checkout lookup

The scripts no longer find the main checkout through git from the cwd, since the cwd may be the project root, which is not a git repo.

- `MAIN_CHECKOUT` in `.orch` names it (relative to the project root, e.g. `code/foo`).
- Default, used by `setup-project` to fill it in: the one folder in `WORKTREE_ROOT` whose `.git` is a directory (worktrees have a `.git` file). None, or more than one → stop with a clear error.
- Worktrees are placed at `<WORKTREE_ROOT>/<id>`, wherever the command was run from.

### `PROJECT_NAME`

- Default: the project root's folder name (`~/Projects/foo` → `foo`).
- `PROJECT_NAME` in `.orch` overrides it.
- Sanitized once, in the shared resolver: lowercase, `a-z0-9-` only, hyphens collapsed. No three-segment cut: `my-big-client-site` stays `my-big-client-site`. Every DDEV name below uses that one sanitized value, so the main checkout and its worktrees always agree.

### DDEV project names (`.ddev/config.local.yaml`)

- **Main checkout:** `name: <PROJECT_NAME>`.
- **Ticket worktree:** `name: <id>-<PROJECT_NAME>`. `<id>` keeps today's derivation from the ticket id or branch.
- The main checkout's folder name no longer matters, so `code/main` is safe.
- Who writes the main checkout's `config.local.yaml`: `setup-worktree.sh` checks it on every run. Missing file → write `name: <PROJECT_NAME>`. Different `name:` already there → warn and leave it (same as the existing worktree-name mismatch warning).

### `WORKTREE_ROOT`

- Default: `<project root>/code`. The project root comes from the folder name, not from an overridden `PROJECT_NAME`.
- `WORKTREE_ROOT` in `.orch` overrides it.

### Config lookup order

In every reader (the three shell scripts, `scripts/orch`, and the skills), for every key:

1. environment variable
2. `<project root>/.orch`
3. default

### Orchestrator state in the project root

State moves to `<project root>/.agents/orchestration/`, outside any git repo. The main orchestrator runs in the project root, and manages tickets and their worktrees from there.

- `state_dir()` returns `<project root>/.agents/orchestration`. `ORCH_HOME` still overrides.
- Everything in the folder moves together: `state.db`, `logs/`, `briefs/`, `config.json`.
- `orch init` no longer writes a `.gitignore`. Nothing there is in git.
- **Main vs ticket session.** The hook and the Pi extension find the state dir with the project root walk-up, not git. A session whose cwd is inside a ticket worktree (`<WORKTREE_ROOT>/<id>`, matched against `tickets.worktree`) is a ticket orchestrator. Any other cwd in the project root (the root itself, `code/`, the main checkout) is the main orchestrator, and the hook leaves it alone.
- The hook stays cheap: a path walk-up and a file check. It makes one git call only for a cwd outside `~/Projects` (to trace a worktree under an out-of-root `WORKTREE_ROOT` back to its main checkout), as it did before.
- A ticket row whose worktree is a main checkout (`.git` is a directory) never matches, so a bad row can't turn the main session into a ticket session.

### New skill: `orchestration:setup-project`

Writes a template `.orch` into the project root, with every key set to its default as derived from the folder structure. A deterministic script does the work (`skills/setup-project/scripts/setup-project.sh`); the skill only runs it and reports back.

- Run from anywhere inside `~/Projects/<project-name>`. Uses the same project root and main checkout lookup as the other scripts (shared resolver).
- Main checkout not there yet → stop and tell the user to clone it into `code/` first.
- `.orch` already exists → refuse. `--force` overwrites it.
- Same folder in, same file out: fixed key order, no timestamps.
- Also creates `<project root>/.agents/orchestration/` (same as `orch init`), so the project is ready for the orchestrator.

Template written (example for `~/Projects/foo/code/foo-site`):

```
# Orchestration config for this project. Relative paths resolve against this folder.
PROJECT_NAME=foo
MAIN_CHECKOUT=code/foo-site
WORKTREE_ROOT=code
BASE_BRANCH=main
ACCESSIBILITY_TESTS=false
# Optional. Uncomment to use.
# DB_DUMP=
# PROVISION_HOOK=
# RETIRE_HOOK=
```

- `BASE_BRANCH`: read from the main checkout's `origin/HEAD` (`git symbolic-ref --short refs/remotes/origin/HEAD`, minus `origin/`). Can't read it → write `BASE_BRANCH=` empty and say so. Worktree creation still refuses until it is set.
- Keys with no default (`DB_DUMP`, `PROVISION_HOOK`, `RETIRE_HOOK`) are written commented out, so the user sees they exist.

## What has to change

1. **Shared shell resolver.** Factor the reader into one shared file rather than editing three copies. It walks up to the project root, reads `.orch`, finds the main checkout, and exports `PROJECT_NAME` (sanitized), `MAIN_CHECKOUT` and `WORKTREE_ROOT`. Move `ddev_project_name` into it too, so setup and retire can't drift.
2. **Run from anywhere.** Replace each script's git-based main checkout lookup with the resolver's `MAIN_CHECKOUT`.
3. **DDEV naming.** Replace every use of the main checkout's basename with `PROJECT_NAME`. Drop the three-segment cut. Worktrees get `<id>-<PROJECT_NAME>`. Setup also writes the main checkout's `name: <PROJECT_NAME>`.
4. **Default `WORKTREE_ROOT`.** Change it to `<project root>/code`.
5. **`scripts/orch`.** Its `main_checkout()` and three `read_base_branch(<main>/.env)` calls move to the project root and `.orch`. Its error messages name `.orch`. Add a Python twin of the resolver here (one function), since `orch` can't source the shell file.
6. **State dir.** `state_dir()`, `cmd_init` (drop the `.gitignore`), `hook_locate` and its `in_main` test in `scripts/orch`; `hasOrchState` in `pi/extension.ts`. All move to the project root walk-up.
7. **New `setup-project` skill and script.** As above. Register it in the plugin manifest.
8. **Skill docs.**
   - `create-worktree/SKILL.md`: frontmatter description, the `BASE_BRANCH` instruction, the `PROVISION_HOOK` lookup, the config table (`WORKTREE_ROOT` default, source column), and the shim section all say `.env` or `<main-checkout-basename>`. Say it runs from anywhere in the project root.
   - `retire-worktree/SKILL.md`: same check.
   - `orchestration/SKILL.md`: `ACCESSIBILITY_TESTS` is read from `.env`; move it to `.orch`. Step 1 ("check the main checkout") uses `MAIN_CHECKOUT`. Say the main orchestrator runs in the project root. Log paths (`.agents/orchestration/logs/`) are now under the project root.
   - `orchestration/references/design.md`: the "state under `.agents/orchestration` in the main checkout" constraint.
   - `orchestration/references/platforms.md`: the line about engines running with the main checkout's `BASE_BRANCH`.
   - `README.md`: replace the `.env` setup steps with: make `~/Projects/<name>/code/`, clone into it, run `setup-project`, start the orchestrator in `~/Projects/<name>`. The `config.json` path changes too.
9. **Tests.**
   - `create-worktree/tests/worktree-naming-parity.test.sh` pins the `-acme-site` suffix from the main checkout's basename and tests the three-segment cut. Rewrite it around `PROJECT_NAME`, drop the cut cases, and add the main checkout's own name.
   - `tests/test_orch_adapters.py` builds a main checkout with a `.env` and sets `WORKTREE_ROOT` itself. Change the fixture to a project root with `.orch`.
   - New: project root lookup from several depths (root, `code/`, main checkout, inside a worktree); cwd outside `~/Projects` errors; missing `.orch` errors; main checkout lookup (one, none, two); `PROJECT_NAME` and `WORKTREE_ROOT` default and override; main checkout `config.local.yaml` written once and not overwritten; `setup-project` output byte-for-byte against a fixture, refusal without `--force`, empty `BASE_BRANCH` when there's no `origin/HEAD`; state dir in the project root; hook treats the project root and main checkout as main, a ticket worktree as ticket.

## Traps

- **Tests can't use the real `~/Projects`.** The resolver needs a way to point at a temp folder. Read the projects folder from an env var (`ORCH_PROJECTS_DIR`, default `$HOME/Projects`) so tests can set it.
- **Reaper safety.** `reap-worktrees.sh` skips the main checkout with an exact string match on the path (`[ "$path" = "$main_repo" ]`), not a resolved path. With the default `WORKTREE_ROOT`, the main checkout sits inside `WORKTREE_ROOT`, so that one check is all that keeps the reaper from retiring it. Change the check to compare resolved paths (`pwd -P`).
- **Retire must never touch the main DDEV site.** Retire reads `name:` from the worktree's `config.local.yaml` and deletes that DDEV project. The main checkout's name is now just `<PROJECT_NAME>`, with no id prefix. Add a guard: refuse to delete a DDEV project whose name equals `PROJECT_NAME`.
- **Retire from inside the worktree it's retiring.** Now that it can run from anywhere, it can run from inside the folder it deletes. `cd` to the project root first.
- **`PROJECT_NAME` collisions.** Two project roots with the same `PROJECT_NAME` override would produce clashing DDEV names. Leave the override to the user; don't try to detect it.
- **Renaming the main DDEV site.** A project that already runs DDEV under a different name gets the warning, not a rename. Renaming means `ddev stop --unlist`, edit `name:`, `ddev start`, and the database may need re-importing.
- **Existing state.** Projects already using `orch` have a `state.db` in the main checkout. Not migrated (same as worktrees): finish or drop open tickets first, or move the folder by hand.
- **Claude Code history.** Session history and per-project memory are stored by folder path (`~/.claude/projects/<path-slug>/`). Moving a checkout leaves them under the old path. Starting sessions from the project root instead of the main checkout also changes the path.
- **DDEV registration.** DDEV records each project's location. Run `ddev stop --unlist` before moving a checkout, or `ddev start` in the new location may report that the project already exists elsewhere.

## Decided

- The fork lives in `~/skills/personal/orchestration` (personal marketplace). No backward compatibility with the old layout: drop the `.env` fallback.
- The user clones the main checkout by hand. Skills assume it is there.
- Commands run from anywhere inside the project root and find it by walking up.
- `.orch` is written by `orchestration:setup-project`, a deterministic script.
- Main checkout folder name is free. Project identity comes from `PROJECT_NAME` (project root folder name, overridable in `.orch`), not from the checkout's folder name.
- Main checkout DDEV name is `<PROJECT_NAME>`; each worktree's is `<id>-<PROJECT_NAME>`.
- No three-segment cut on `PROJECT_NAME`.
- Orchestrator state lives in `<project root>/.agents/orchestration/`, outside git. The main orchestrator runs in the project root.
- Existing worktrees are not migrated.
- `~/dotfiles` is being retired. Its `orca-retire-merged` was the only reader of `worktree-start-sha` (MR !62), so the fork needs its own cleanup path or can drop that file.

## Next steps

1. On a feature branch in `~/skills/personal`, add the shared resolver: project root walk-up, `.orch` reading, main checkout lookup, `PROJECT_NAME` and `WORKTREE_ROOT` defaults, `ddev_project_name`.
2. Add `setup-project` (script and skill) on top of the resolver. This is the first thing to run on a migrated project, so it makes a good tracer bullet.
3. Switch setup and retire to the resolver and `PROJECT_NAME` naming. Have setup write the main checkout's `name:`.
4. Add the retire guard against deleting the `PROJECT_NAME` DDEV project.
5. Harden the reaper's main-checkout check to compare resolved paths.
6. Move `scripts/orch` and `pi/extension.ts` to the project root, `.orch`, and the new state dir. Update the hook's main vs ticket test.
7. Update the skill docs and README.
8. Update and add the tests listed above.
9. Run `bash tests/run-all.sh` (manual; not in CI; the retire suites need bash 4+ first on `PATH`).
10. Migrate one project by hand. Start the orchestrator in the project root and confirm that setup-project, create, a ticket run, retire and reap all work end to end.
