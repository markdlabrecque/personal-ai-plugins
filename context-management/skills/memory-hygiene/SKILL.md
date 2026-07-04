---
name: memory-hygiene
description: Clean up a project's (or every project's) Claude memory in place — find memory files that duplicate or contradict each other, and project-status memories that have gone stale (past due dates, closed tickets, superseded decisions) and should be archived or updated. Use whenever the user asks to clean up memory, audit memory, prune stale memories, or mentions memory files that seem out of date or repetitive. Distinct from memory-to-context, which promotes team-useful memories into project docs — this skill is about the memory store's own internal health, not what should move to the repo.
---

# memory-hygiene

Memory accumulates the way any long-lived notes do: two files end up saying almost the same thing, or a status note never gets removed after the status changes. Neither is caught by `memory-to-context` — that skill only asks "should this move to team docs?", not "is this memory store internally consistent?". This skill asks the second question.

Can be triggered directly, or invoked by `optimize` after it spots duplicate/stale memory while auditing a project scope.

## 1. Determine scope

Ask if not given: a single project's memory (`~/.claude/projects/<project-slug>/memory/`) or a sweep across every project. A full sweep is a bigger, slower operation — confirm that's really what's wanted before reading dozens of memory directories.

## 2. Read the memory store(s)

For each scope, read `MEMORY.md` and every file it indexes.

## 3. Look for three things

1. **Redundancy** — two or more memory files covering the same fact or preference with overlapping content, usually written at different times without either author (Claude, across sessions) noticing the other already exists. Example found in this environment: `feedback_local_playwright_first.md` and `feedback_playwright_headless.md` both governing Playwright behavior in the same project's memory.
2. **Contradiction** — a memory that conflicts with a newer one that superseded it but was never removed. When memory is read back into context, the older one can still win depending on ordering, so it isn't just clutter — it's a live risk of doing the wrong thing.
3. **Staleness** — `project`-type memories anchored to a date, ticket, or status ("awaiting review", "in progress", "due 2026-XX-XX") that has clearly passed or resolved. Check referenced dates against the current date, and where a ticket number is mentioned, note that the memory should be checked against the ticket's current state rather than assumed current.

## 4. Classify: obvious vs. needs judgment

**Fix directly:**
- Two memories with near-identical content — merge into one, keep the clearer/more complete wording, update `MEMORY.md`.
- A status memory with an unambiguous past date and no sign the situation is still live.

**Flag and ask:**
- Partial overlap where merging would lose a detail that only one version has.
- Apparent contradictions where it's not obvious which memory is actually the current one.
- Staleness calls that depend on information not visible from the memory files themselves (e.g. "is ticket #234 actually closed?") — say what you'd need to check rather than guessing.

## 5. Apply, and hand off promotable content

Apply the obvious merges and archive (or delete, per the user's preference — ask if unstated) the clearly stale entries, updating `MEMORY.md` to match.

If a memory looks less like something to prune and more like a durable project fact the whole team should see, don't act on it here — flag it and point at `memory-to-context` instead. This skill cleans the memory store; that one decides what graduates out of it.
