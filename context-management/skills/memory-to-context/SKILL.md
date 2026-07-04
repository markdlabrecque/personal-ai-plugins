---
name: memory-to-context
description: Review a project's Claude memory files and promote the ones with durable, team-wide value (facts about the codebase, architecture, conventions, or decisions) into the project's own tracked documentation — AGENTS.md, README, docs/*.md — so the whole team can see them, then remove them from memory once promoted. Use whenever the user asks to promote memories to docs, get something out of memory and into the repo, wants memory content visible to teammates, or is auditing/cleaning up project memory. Do not promote memories about the user's own personal workflow habits or how they like Claude to behave — those are personal, not project knowledge, and don't belong in team docs.
---

# memory-to-context

Moves memory content that documents the *project* into the project's own repo, where anyone on the team can see it — not just Claude. Memory is private and gitignored; project docs are shared and version-controlled. Content that's genuinely about the codebase belongs in the second place, not the first. This skill decides what graduates *out* of memory; for cleaning up memory that's staying (deduping, archiving stale entries), use `memory-hygiene` instead — the two are complementary passes over the same store.

Can be triggered directly, or invoked by `optimize` after it spots a promotable memory while auditing a project scope.

## 1. Read the project's memory

Read the project's `MEMORY.md` index and every memory file it points to.

## 2. Classify each memory: promotable or personal

The frontmatter `type:` field is a hint, not the deciding factor — judge by what the content actually says, independent of who it's addressed to.

**Promotable — durable facts about the project that any teammate would benefit from knowing:**
- Architecture, data model, or codebase facts (`reference`/`project`-type memories are usually this)
- Team-wide workflow conventions specific to this codebase — e.g. "run `drush cim -y && drush cr` after config changes on this project," "migrations here must ship as a Drush command or deploy hook" — even when the memory is phrased as an instruction to Claude, if a human developer working in this repo would need to know it too, it's project knowledge that happened to get captured as a Claude memory.
- Decisions, gotchas, or precedents that would help the next person (human or Claude) working in this codebase.

**Personal — not promotable, leave in memory:**
- The user's preferences for how Claude should communicate, verify work, ask questions, or structure responses (tone, terseness, when to ask before acting). This is about working with *this user*, not about the project — a teammate reading it in project docs would find it out of place and confusing.
- Anything scoped to the user's own machine or personal setup rather than the project (their local paths, their own tool preferences).

If a memory is a mix of both, split it: promote the project-fact portion, leave the personal-preference portion in memory.

## 3. Find or confirm a destination

Look at the project's existing docs (`AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `docs/*.md`) for a section that's already a natural home for the content — matching topic, not just proximity. If one is clearly right, propose it. If nothing fits well or more than one place could work, ask the user where it should go rather than guessing; a wrong guess here means the content ends up somewhere the team won't think to look.

## 4. Confirm the plan, then apply

Present the full migration plan before writing anything: which memories, which destination file and section each is going to, and a one-line summary of what will be written there. Get confirmation, since this mutates the actual project repository.

Once confirmed:
- Write the content into the destination doc(s), adapting phrasing as needed for a team audience (drop any "tell Claude to..." framing — write it as a fact or instruction for a developer).
- Delete the promoted memory file(s).
- In `MEMORY.md`, replace the removed entries with a dated note recording what was promoted and where it went, e.g.:
  ```
  ## Promoted to project docs (YYYY-MM-DD)
  The following used to be memory files; their content now lives in the repo where the whole team can see it, so they were deleted here:
  - <short description> -> `<destination file>` (<section>)
  ```
  This keeps a paper trail so a future pass doesn't re-discover the same memory and try to promote it again.

Do not commit the project doc changes. Committing is governed by the project's own git conventions; this skill's job ends at making the edits.
