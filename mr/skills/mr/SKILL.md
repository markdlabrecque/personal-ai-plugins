---
name: mr
description: Create a merge/pull request from a feature branch off develop — confirm branch state, run tests, rebase onto develop, then commit, push, open the MR, and merge only after explicit confirmation. Use when the user wants to ship a feature branch, open an MR/PR, or run the rebase-then-merge cycle.
---

# Create MR

Standardizes the rebase-then-merge cycle. Follow these steps in order. **Stop and ask** at any gate that fails rather than working around it.

## 1. Confirm branch state

- Run `git rev-parse --abbrev-ref HEAD` and `git rev-parse --show-toplevel`.
- Confirm we are on a **feature branch off `develop`** — not `develop`, `main`/`master`, and **not** a git worktree (the toplevel should be the primary clone, not a `spaces/`-style worktree path).
- If on a worktree or a base branch, stop and ask how to proceed. Do **not** create a branch silently.

## 2. Run tests; abort if failing

- Detect and run the project's test suite (e.g. `npm test`, `phpunit`, `ddev exec phpunit`, kernel tests with `SIMPLETEST_DB` configured).
- If any test fails, **abort** and report the failures. Do not rebase, commit, or push.
- If no test suite exists, say so and ask whether to continue.

## 3. (Drupal only) Check config export

- For Drupal projects, run `drush cex` (no confirm) to check for un-exported config.
- If there is config to export, **confirm with the user** before committing.

## 4. Rebase onto develop

- `git fetch` the relevant remote first.
- Rebase the feature branch onto the latest `develop`.
- **Never delete untracked files** to clean the tree for rebase without first confirming they are safe to remove.
- If conflicts arise, stop and surface them — do not guess resolutions.

## 5. Commit, push, open MR

- Group only related work; use **conventional commits** (`feat:`, `fix:`, `chore:`, etc.) with a concise one-line subject.
- Prefix the subject with the **ticket number** if known.
- **Never** add a `Co-Authored-By: Claude` line.
- Highlight any working-copy files not staged; offer to commit or clean them up to keep the tree tidy.
- Detect the remote to pick the CLI: **`gh`** for GitHub, **`glab`** for GitLab. If multiple remotes, prefer `origin`.
- Open the MR/PR **against `develop`**.

## 6. Merge — only after confirmation

- **Never merge automatically.** Present the MR and ask for explicit confirmation before merging.
- **Never merge into `main`/`master`** via the CLI on your own initiative under any circumstances.
- Merge only the target the user confirms.
