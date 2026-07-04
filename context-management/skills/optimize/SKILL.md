---
name: optimize
description: The entry point for auditing and cleaning up Claude context — CLAUDE.md/AGENTS.md, their @-imports, the skills that live in that scope, and that scope's memory. Fixes redundant/contradictory/dead instructions directly, and surfaces candidates for the other context-management skills (misplaced content to extract, duplicate/broken skill registrations, memory worth promoting to team docs, memory worth pruning) rather than trying to do all of it inline itself. Use whenever the user asks to audit, clean up, or review CLAUDE.md, AGENTS.md, project instructions, context files, memory, or skills for duplication, conflicts, staleness, or bloat — even if they only name one file or one narrow problem, since overlap usually spans several. Also trigger on "optimize context", "clean up instructions", "is this redundant", "find contradictions in my rules", "audit my context/memory/skills". Takes a scope of "project" or "global" (global = user-level ~/.claude); if the user doesn't say which, ask before doing anything.
---

# optimize

The roll-up entry point for this plugin. Point it at a scope and it looks for every kind of problem the sibling skills in `context-management` each specialize in, fixes the ones that are its own direct job, and hands the rest off to the skill built for that job — rather than reimplementing each one inline. Think of it as the thing you run when you just want "is my context in good shape?" answered, without having to know in advance which specific skill applies.

## 1. Determine scope

Scope is either:

- **`project`** — the current project's `CLAUDE.md` and/or `AGENTS.md` (whichever exist at the repo root or wherever the project keeps them), every file they `@`-import, every skill under that project's own `.claude/skills/`, and that project's memory (`~/.claude/projects/<project-slug>/memory/`).
- **`global`** — `~/.claude/CLAUDE.md`, every file it `@`-imports (e.g. `RTK.md`), every skill under `~/.claude/skills/` (the user's global skill library — not third-party marketplace plugins, which aren't the user's to edit), and the memory attached to the `~/.claude` project itself.

If the user passed a scope, use it. If not, ask which — don't guess. Guessing wrong means auditing the wrong thing and wasting the run.

## 2. Read everything in scope, then look across it, not just within one file

Read every file in scope — context files, their imports, the relevant skills, and the memory store — before drawing conclusions. The interesting findings are usually *between* files, not within one: a rule in a project's `CLAUDE.md` that already exists in the global `CLAUDE.md`, a skill that duplicates a rule its own project's context file states, or a memory file restating something already promoted to docs. Reading only the file the user named will miss most of this.

## 3. Sort what you find into two piles

**Your own job — instruction content problems. Fix or flag these directly, don't hand them off:**

1. **Redundancy** — the same rule or fact stated more than once, in the same file, across files in scope, or between a context file and a skill it references. Restating something once as a summary and once in detail is fine; restating it three times with no new information is not.
2. **Contradiction** — two rules that conflict outright (opposite defaults, opposite "always"/"never"), or that quietly disagree on a specific (different port numbers, different tool names for the same job, different file paths).
3. **Dead weight** — empty section headers, headings orphaned by a parent section that was removed elsewhere, broken pointers (a skill or file referenced by name that no longer exists), and typos that change the meaning of a rule (not cosmetic ones).

Classify each: **fix directly** if it's an exact/near-exact duplicate, an empty header, an orphaned heading, a clear typo, or one rule that's a strict subset of another. **Flag and ask** if the correct resolution isn't obvious, the repetition might be deliberate emphasis, or fixing it means picking which version of a rule survives. When in doubt, flag rather than fix — a wrong guess here corrupts instructions the user relies on every session.

**Candidates for a sibling skill — surface these, don't act on them yourself:**

4. **Misplaced weight** — a large, rarely-needed block sitting in an always-loaded file when it would serve just as well as a skill loaded on demand. → candidate for `extract-to-skill`.
5. **Registry problems** — a skill that appears to duplicate another one found in scope, or (if you happen to notice while reading `settings.json`) an `enabledPlugins` entry that doesn't resolve. → candidate for `skill-registry-audit`.
6. **Promotable memory** — a memory file describing a durable project fact, convention, or decision that the whole team would benefit from, sitting in memory instead of tracked docs. → candidate for `memory-to-context`.
7. **Memory hygiene issues** — memory files that duplicate or contradict each other, or project-status memories that have clearly gone stale. → candidate for `memory-hygiene`.

Don't perform the actual extraction, registry cleanup, or memory migration/pruning yourself — each of those has its own confirmation flow and mechanics that live in its own skill. Your job here is to notice and describe the candidate well enough that invoking the right skill next is a one-line decision.

## 4. Apply, report, and offer to hand off

Apply the obvious fixes from your own job (redundancy/contradiction/dead weight). For everything flagged — both your own judgment calls and the sibling-skill candidates — report it clearly: quote the text, name the files and locations involved, and state what you'd recommend.

For the sibling-skill candidates specifically, list them grouped by which skill would handle them, then ask which (if any) the user wants run now. If they confirm one, invoke that skill directly rather than doing its job yourself — it has context and steps (like its own confirmation gate) that this pass shouldn't skip.

Do not commit anything. Committing is governed by the project's own git conventions (usually "never commit unless explicitly asked"); this skill's job ends at making the edits.

If other unrelated, uncommitted changes already exist in a file you're editing, isolate your edit into its own hunk rather than bundling it with unrelated work — check `git diff` on the file first and only stage/describe the lines this audit actually changed.
