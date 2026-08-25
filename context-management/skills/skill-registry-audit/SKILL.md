---
name: skill-registry-audit
description: Audit the skill registry itself — skills registered in more than one place, settings entries enabling missing plugins, installed-but-never-enabled plugins, and SKILL.md vs marketplace.json drift. Use on "audit skills", "find duplicate skills", "clean up plugins", or when a registered skill isn't triggering. (optimize audits instruction text; this audits the registry.)
---

# skill-registry-audit

`optimize` finds redundant or contradictory *instructions*. This finds redundant or broken *registrations* — the same skill existing in two places, or the registry pointing at something that isn't there. Both matter, but they're different failure modes and need different fixes.

Can be triggered directly, or invoked by `optimize` after it notices something registry-shaped (a duplicate skill, a suspicious `enabledPlugins` entry) while auditing a scope.

## 1. Enumerate every skill

Collect skills from every source:
- Plain skill directories: `~/.claude/skills/*/SKILL.md` (global) and `<project>/.claude/skills/*/SKILL.md` (project-scoped, for whichever project is relevant).
- Plugin-based skills: for every marketplace listed in `~/.claude/settings.json`'s `extraKnownMarketplaces`, read that marketplace's `marketplace.json`, resolve each plugin's source, and read every `skills/*/SKILL.md` inside it.

For each skill, record: its name, its description, which mechanism it's registered through (plain dir vs. `plugin@marketplace`), and whether that plugin is currently enabled in `settings.json`'s `enabledPlugins`.

## 2. Check registry consistency

- **Enabled but missing**: an `enabledPlugins` entry whose `plugin@marketplace` doesn't resolve to an actual plugin on disk/in the marketplace. This means the user thinks something is active that isn't.
- **Installed but not enabled**: a plugin that exists in a known marketplace but has no `enabledPlugins` entry. Not necessarily wrong — could be deliberate — so report it, don't fix it.
- **Metadata drift**: for plugin-based skills, compare the SKILL.md `description`, the `plugin.json` `description`, and the marketplace entry's `description` for the same skill. These are three independent copies of the same fact and nothing keeps them in sync — flag when they've diverged enough that reading one wouldn't tell you what another says.

## 3. Detect duplicates

Compare every discovered skill's `name` and `description` against every other one, across *all* sources (plain dirs and every plugin), not just within one marketplace. Two skills count as duplicates when they'd both plausibly trigger on the same user request, even if their names differ. A real example found in this environment: `mr` existed simultaneously as a plain `~/.claude/skills/mr/SKILL.md` and as a separate marketplace plugin — same purpose, two registrations, no indication either was meant to be the deprecated one.

For each duplicate pair, report both locations and recommend which to keep — generally prefer the more complete, more recently touched, or more properly structured (plugin over ad hoc plain directory) version, but say why rather than just picking one.

## 4. Report; don't resolve automatically

Merging or deleting a skill is consequential — it can silently change what triggers on a request the user relies on. Report every finding with enough detail to act on (both file paths, both descriptions, the specific settings.json line), recommend a resolution, and wait for confirmation before removing or merging anything. Do not commit anything; that's the user's call.
