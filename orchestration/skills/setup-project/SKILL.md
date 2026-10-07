---
name: setup-project
description: Set up a project folder for orchestration by writing its `.orch` config with every default filled in. Use when asked to set up, initialize or onboard a project for orchestration, or when another orchestration skill reports that `.orch` is missing.
---

# Set up a project

Projects live in `~/Projects/<project-name>/`, with the main git checkout cloned by the user into `code/`:

```
~/Projects/<project-name>/
├── .orch                    # written by this skill
├── .agents/orchestration/   # orch state, created by this skill
└── code/
    └── <main checkout>/
```

Run the script from anywhere inside the project folder:

```
${CLAUDE_PLUGIN_ROOT}/skills/setup-project/scripts/setup-project.sh [--force]
```

It finds the project root by walking up, finds the main checkout in `code/`, and writes `.orch`:

| Key | Default |
|---|---|
| `PROJECT_NAME` | The project folder's name. DDEV names are `<PROJECT_NAME>` for the main checkout and `<id>-<PROJECT_NAME>` for each worktree. |
| `MAIN_CHECKOUT` | `code/<the one git checkout in code/>` |
| `WORKTREE_ROOT` | `code` |
| `BASE_BRANCH` | The main checkout's `origin/HEAD` branch. Empty when that can't be read. |
| `ACCESSIBILITY_TESTS` | `false` |
| `DB_DUMP`, `PROVISION_HOOK`, `RETIRE_HOOK` | Written commented out. No default. |

Relative paths in `.orch` resolve against the project folder.

- Never clone the repository yourself. If the script says there is no main checkout, tell the user to clone it into `code/`.
- The script refuses when `.orch` exists. Pass `--force` only when the user asked to overwrite it.
- If the script says `BASE_BRANCH` is empty, ask the user which branch to use and set it in `.orch`.

Report the path written and any warning. Show the `.orch` contents.
