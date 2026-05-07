---
name: pitchai-pm
description: Alias for the workspace-local PM DB skill used by Symphony app-server agents.
---

# PitchAI PM

This workspace-local skill is intentionally an alias. Use the canonical
workspace-local PM instructions at:

`.codex/skills/pm-db/SKILL.md`

That skill contains the deduplicated Symphony app-server PM workflow for:

- `pitchai_pm` dynamic-tool operations
- task state transitions
- workpads, comments, blockers, dependencies, PR links, and changelogs
- blocker reconciliation and follow-up task creation

In normal interactive Codex sessions on the host, the broader canonical PM skill
is `/root/.codex/skills/project-management/SKILL.md`.
