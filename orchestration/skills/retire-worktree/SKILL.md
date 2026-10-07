---
name: retire-worktree
description: Retire a finished git worktree. Use when asked to retire, tear down, remove, clean up, or delete a worktree or its DDEV project.
---

# Retire a worktree

This skill is a **base/override pair** (worktree-promotion-spec.md), the
teardown counterpart of `create-worktree`: a generic engine here
(`scripts/retire-worktree.sh`, `scripts/reap-worktrees.sh`), plus an
optional thin per-project shim that configures and delegates to it. A
project with no shim at all still works — see `create-worktree/SKILL.md`
for the full inheritance-pattern diagram; it applies the same way here.

```
scripts/retire-worktree.sh <id> [--force] [--ddev-only]
scripts/reap-worktrees.sh [--dry-run]
```

`retire-worktree.sh` finds the worktree through `git worktree list`: `<id>` must
be the directory name of a linked worktree of the current repo, wherever it
lives on disk. `WORKTREE_ROOT` is not used by it (only by `reap-worktrees.sh`).

Tears down one worktree completely: the Herdr workspace, the DDEV project
(handed to a project's `RETIRE_HOOK` if one resolves), the directory on
disk, and the local branch. Every step is destructive and none of it is
recoverable outside git's own reflog. The Herdr close is the engine's own
step and always runs, so a manual retire never leaves a Herdr tab pointing
at a deleted folder. For ticket worktrees, the `orchestration` plugin's
`orch` closes the platform side (including the Herdr workspace) through its
adapters before calling this engine, so the engine then finds no workspace
and says so — expected and harmless.

1. Refuses (exit 1, nothing touched) when: no `<id>`; no linked
   worktree of this repo has that directory name (the main checkout never
   matches); or its path does not exist.
2. Dirty check (`git status --porcelain --untracked-files=all`). Non-empty
   and no `--force` → refuses (exit 2), full list on stderr. `--force`
   proceeds and lets git discard it.
3. Close the Herdr workspace, before the DDEV step and before the worktree
   is removed. Lookup: `herdr worktree list` (the entry whose `path` is the
   worktree → `open_workspace_id`), falling back to `herdr workspace list`
   (the entry whose `worktree.checkout_path` is the worktree →
   `workspace_id`), then `herdr workspace close <id>`. No herdr on PATH or
   no match → says so on stdout and carries on. Best-effort: a close
   failure warns on stderr but never aborts the teardown. This step is
   always the engine's own — a `RETIRE_HOOK` does not replace it.

   If the resolved workspace id equals `$HERDR_WORKSPACE_ID` (the agent is
   retiring the very worktree it is running in), its close is deferred:
   everything else runs first — steps 4, 5 and the step 6 report — and the
   close itself becomes the script's very last action, after the report.
   Stdout says so at the point of deferral. If step 5's `git worktree
   remove` then fails (exit 4), stderr names the workspace left open and
   says to re-run `retire-worktree.sh` once the removal failure is fixed. A
   different or unset `$HERDR_WORKSPACE_ID` closes in step 3 as normal.
4. Delete the DDEV project — or, if a `RETIRE_HOOK` resolves (env, then
   the main checkout's `.env`, then the conventional
   `<worktree>/scripts/retire-worktree.sh`), delegate this step to it
   instead. The hook runs with cwd set to the still-existing worktree,
   before it is removed, with `RETIRE_WORKTREE_IN_HOOK=1` exported into its
   environment. A project with no retire hook anywhere is not required to
   have one — the engine's own step 4 runs unchanged. It is best-effort: a
   ddev failure warns on stderr but never aborts the git teardown.

   The conventional `<worktree>/scripts/retire-worktree.sh` hook is often a
   thin delegate shim that `exec`s straight back into this same engine. The
   engine only trusts a hook's exit 0 as "step 4 genuinely handled";
   any nonzero exit (including from a re-entered engine — see below) is
   warned about on stderr, naming the hook and its exit code, and the
   engine then runs its own step 4 as a fallback, so nothing is silently
   orphaned. If the resolved hook IS this same engine (direct re-entry via a
   delegate shim), the re-entered process detects
   `RETIRE_WORKTREE_IN_HOOK=1` already set in its environment, prints a
   warning to stderr, and refuses immediately with **exit 3**, touching
   nothing — the outer invocation then treats that exit 3 the same as any
   other nonzero hook exit and falls through to its own teardown.

   `RETIRE_WORKTREE_IN_HOOK=1` is exported, so it is inherited by every
   process the hook spawns, not just a direct `exec` back into this engine.
   A hook must not itself shell out to this engine's `retire-worktree.sh`
   (e.g. to retire other worktrees as a side effect), nor to
   `reap-worktrees.sh` — `reap-worktrees.sh` in turn invokes
   `retire-worktree.sh` per worktree it reaps, and that inner invocation
   would inherit the guard variable and refuse immediately with exit 3,
   exactly as if it were the delegate-shim re-entry case above.
5. From the main checkout: `git worktree remove --force <worktree>`, then
   `git branch -D <id>` when that branch exists — always the engine's own
   job, even when a `RETIRE_HOOK` handled step 4, since only the engine
   still has the main checkout's context once the worktree directory is
   gone.
6. Final report: workspace id (`none closed` when there was none; marked
   "closed last: caller's own workspace" when its close was deferred per
   step 3), DDEV project name (the name the still-present
   `.ddev/config.local.yaml` actually names, not a fresh re-derivation — a
   worktree provisioned under an older naming rule must report what
   `ddev delete` really acted on), path, branch.

`--ddev-only` skips the Herdr step (3) entirely — it never calls `herdr` —
runs steps 1, 2 and 4 (lookup, the uncommitted-work check, then the DDEV
delete or the retire hook) and stops with exit 0, leaving the checkout
and its branch for the caller's platform to remove (`orch` uses it on Orca,
then runs `orca worktree rm`). It combines with `--force`; without it a
dirty worktree still refuses with exit 2.

`reap-worktrees.sh` enumerates every worktree under `WORKTREE_ROOT`, decides
whether each branch has landed on `$REMOTE/$BASE_BRANCH` (ancestor,
patch-equivalent/rebase, or squash — three tiers), and hands anything landed
to the sibling `retire-worktree.sh` (without `--force`, so a dirty worktree
survives and is reported as skipped). `--dry-run` prints what would be
retired without calling it. `BASE_BRANCH` is resolved environment, then the
main checkout's `.env`, then refuses (no literal default — see the overrides
table); `REMOTE` defaults to `origin`.

Every step is destructive and none of it is recoverable. Stop and ask the
user whenever a step reports something unexpected — an unmerged commit with
nowhere else it exists, in particular, is the one case worth blocking on
manually rather than trusting `--force`.

## Layers, precisely

Same two-layer model as `create-worktree`: a caller runs
`<project>/scripts/retire-worktree.sh` (or `reap-worktrees.sh`) if the
project has one — a thin shim that sets project config and delegates — and
this engine underneath does the actual work. A project with **no shim at
all** can call this engine directly: the plugin ships it at
`${CLAUDE_PLUGIN_ROOT}/skills/retire-worktree/scripts/retire-worktree.sh`.
`orch` calls a project shim with `RETIRE_ENGINE` set to that path, so a shim
can delegate with `exec "$RETIRE_ENGINE" "$@"`; the engine itself does not
read `RETIRE_ENGINE`.

## Overrides

Same precedence rule as `create-worktree`: **environment, then the main
checkout's `.env`, then the convention/default.**

| Variable | What it does | Default / convention | Read from |
|---|---|---|---|
| `WORKTREE_ROOT` | Where worktrees live on disk — must agree with `create-worktree`'s value for the same project. | `$HOME/Projects/worktrees/<main-checkout-basename>` | environment, `.env` |
| `RETIRE_HOOK` | Project's own teardown script, replacing this engine's own DDEV-delete step (4) if it exits 0. A nonzero exit (e.g. a delegate shim re-entering this engine, which refuses with exit 3) falls back to the engine's own step 4. The Herdr close (step 3) and git-level teardown (step 5) always stay with the engine. | conventional `<worktree>/scripts/retire-worktree.sh` | environment, `.env`, convention |
| `RETIRE_WORKTREE_IN_HOOK` | Set to `1` by the engine itself when invoking a resolved retire hook; not meant to be set by callers. If already set when the engine starts, it refuses immediately (exit 3) — this is what makes re-entry via a delegate-shim hook safe. | unset | environment (engine-internal) |
| `BASE_BRANCH` (`reap-worktrees.sh` only) | Branch checked for "has this landed". | **No fallback default** — env, then `.env`; refuses (non-zero, reaps nothing) if neither resolves | environment, `.env` |
| `REMOTE` (`reap-worktrees.sh` only) | Remote checked for "has this landed". | `origin` | environment only |

## Conventions (no configuration required)

- **Retire hook**: `<worktree>/scripts/retire-worktree.sh`, run with cwd set
  to the still-existing worktree, before it's removed, whenever
  `RETIRE_HOOK` doesn't resolve to something else first.
- `reap-worktrees.sh` needs no per-project convention beyond `WORKTREE_ROOT`
  agreeing with the create side — it calls the sibling
  `retire-worktree.sh` for anything landed, which then resolves its own
  `RETIRE_HOOK` the normal way.

## Adopting this on a new project

1. **Nothing to create, if the project needs no config.** `WORKTREE_ROOT`
   defaults to match `create-worktree`'s own default (main-checkout
   basename), so the two engines agree with zero setup on either side.
2. **Add a shim only for project-specific teardown** — a `RETIRE_HOOK`, or
   anything else that varies per project. Otherwise call the global engine
   directly.

## Tests

`tests/run-all.sh` (in the `create-worktree` skill) runs this skill's two
suites (`retire-worktree.test.sh`, `reap-worktrees.test.sh`) alongside
`create-worktree`'s own, and prints one combined verdict. **These suites are
manual: nothing in CI runs them** — run `bash
../create-worktree/tests/run-all.sh` (or this skill's own test files
directly) after changing either engine, before relying on the change.
