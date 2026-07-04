---
name: extract-to-skill
description: Pull a large or rarely-needed block out of an always-loaded context file (CLAUDE.md/AGENTS.md) into its own skill, loaded on demand instead of paying its token cost every session. Use whenever the user says "extract this to a skill", "make this a skill", "pull this out", "this is too big for CLAUDE.md", or confirms an optimize skill's misplaced-weight finding. Also trigger when a section is clearly a self-contained, occasionally-needed procedure (a runbook, a workflow with an embedded script, reference material for one narrow scenario) sitting in an always-loaded file.
---

# extract-to-skill

Moves a block of content from an always-loaded file into a skill, replacing it with a short pointer. The always-loaded file only ever pays the cost of that pointer; the full content loads only when the skill actually triggers.

Can be triggered directly, or invoked by `optimize` after it finds a misplaced-weight candidate during a broader audit.

## 1. Confirm this is worth doing

Extraction earns its keep when the content is large relative to how often it's actually needed, and has a clear, nameable trigger (a discrete action like "wait for CI" or "prepare a contrib MR" — not a vague symptom). If the block is short (a paragraph or two) or is needed nearly every session, extraction just adds indirection for no savings — say so and suggest leaving it in place instead.

### Examples of good candidates

- **A runbook with an embedded script, needed only for one discrete action.** A ~35-line CI-pipeline-polling procedure (including a full bash background-wait loop) sat in `CLAUDE.md`, paid for every session, but only ever mattered right after a push. Extracted to its own skill; `CLAUDE.md` kept one sentence: "after pushing, use the `ci-pipeline-polling` skill." This is the clearest case — big, rare, discrete trigger.
- **A narrow reference workflow that only applies in one specific scenario.** The drupal.org contrib-module conventions (username, clone/remote layout, MR branch naming) only matter when actually preparing a contrib MR — a small fraction of Drupal work. Extracted into a `drupal-development` skill rather than living in global `CLAUDE.md` where every session pays for it regardless of relevance.
- **A large troubleshooting/gotchas doc for one narrow technical area.** An 8-item Drupal Form API/AJAX gotchas reference was too detailed to inline even in a skill's main body — it became a *nested* reference file (`references/form-alter-gotchas.md`) with a one-line pointer left in the skill itself, so it only loads when actually reading that reference, not every time the skill triggers.

### A non-example — content that should stay put

Not everything large-feeling should move. A rule like "check for un-exported Drupal config before committing" is short, but more importantly it needs to fire on *every* Drupal commit automatically — it's not a discrete, occasionally-invoked action, it's a standing safety check. Moving it into a skill would make it depend on the skill actually being triggered, which defeats the point of a check that must never be skipped. When a rule's value comes from applying unconditionally rather than on-demand, leave it in the always-loaded file even if a skill also documents the *why* and *how* in more depth.

## 2. Decide where the new skill lives

- **Which scope?** If the source content came from a project's `CLAUDE.md`/`AGENTS.md`, the new skill belongs in that project's `.claude/skills/`. If it came from the global `~/.claude/CLAUDE.md`, it belongs in `~/.claude/skills/` (or a personal marketplace plugin, see below). Match the scope of the source — don't promote project-specific content to global scope or vice versa without asking.
- **Plain skill directory or a plugin?** Default to a plain `<scope>/.claude/skills/<name>/SKILL.md` — it hot-reloads immediately and needs no registration. Only use a full plugin (`.claude-plugin/plugin.json` + marketplace registration) if the user asks for one, or the new skill naturally belongs inside an existing plugin (e.g. a Drupal-specific extraction belongs in `drupal-development`, not as a standalone skill).
- **Before creating anything new, check whether a skill covering this ground already exists** (run the equivalent of `skill-registry-audit`'s duplicate check, or at minimum grep skill names/descriptions in the target scope). Extracting into a duplicate is the exact failure this session found with `mr` existing in two places — extend an existing skill instead of creating a near-duplicate when one already fits.

## 3. Draft the skill

- **name**: short, kebab-case, matching what a user would actually say to trigger it.
- **description**: state what it does AND when to trigger it, including phrasings a user would actually type — this is the only thing that determines whether the skill ever gets used.
- **body**: the extracted content. If the scope is global, generalize it — drop references to one specific project's branch names, ticket numbers, class names, or file paths, since a global skill has to make sense in any project. If the scope is project, keep the project-specific detail; that's exactly where it belongs.

## 4. Replace the original with a pointer

Cut the block from the source file down to one or two sentences: what triggers it and which skill to use. Look at how this has already been done in this same repo for reference — the `CI pipeline polling` and `Data migrations` sections of `~/.claude/CLAUDE.md` and `drupal-development` are both worked examples of "one-sentence pointer left behind, full detail moved to a skill."

## 5. Confirm, then apply

Show the drafted SKILL.md and the proposed pointer text before writing anything — this creates new files and edits a context file the user relies on every session. Once confirmed: write the skill, replace the block in the source file, and if the source file had other unrelated uncommitted changes pending, isolate this edit into its own hunk rather than bundling it with unrelated work.

Do not register a new plugin in a marketplace or flip its `enabledPlugins` entry without saying so first — that changes what loads in every future session, not just this one. Do not commit anything; that's the user's call.
