---
name: pitchai-pm
description: Use Symphony's `pitchai_pm` dynamic tool to read and update PitchAI project-management tasks, workpads, changelogs, blockers, and PR links.
---

# PitchAI PM

Use the `pitchai_pm` client tool exposed by the Symphony app-server session.

Tool input:

```json
{
  "operation": "get_task",
  "params": {
    "task_id": "00000000-0000-0000-0000-000000000000"
  }
}
```

## Operations

- `get_task`: read one task by `task_id`.
- `list_tasks`: list tasks by `project_id`, `states`, and optional `limit`.
- `list_workflow_states`: list the Symphony-specific state buttons configured for the project.
- `list_blocked_tasks`: list blocked tasks and grouped blocker candidates for the board scope.
- `list_blocker_tasks`: list existing Symphony-managed canonical blocker tasks and downstream counts.
- `update_task_state`: set `state_name` for a task and record a transition event.
- `append_changelog`: append a timestamped changelog item to `public.tasks.description->changelog`.
- `get_workpad`: fetch the persistent `## Codex Workpad`.
- `upsert_workpad`: create or replace the persistent workpad body.
- `add_comment`: add an auditable task comment row.
- `attach_pr`: attach or update a PR link.
- `create_task`: create a follow-up task.
- `link_task_dependency`: link a blocked task to a canonical blocker task.
- `merge_duplicate_blocker_task`: move dependencies to the canonical blocker task and mark the duplicate `Duplicate`.

## Rules

- Treat `public.tasks.state_name` as authoritative task state.
- Always branch implementation work from `origin/staging` unless the task explicitly
  names another base.
- Use `pitchai_symphony.task_workpads` as the persistent execution checklist.
- Use `pitchai_symphony.task_dependencies` for blocker relationships.
- For `symphony_kind = blocker_reconciliation_agent`, call `list_blocked_tasks`
  and `list_blocker_tasks`, semantically unify duplicate blocker descriptions,
  create or reuse one `Suggested` canonical blocker task per root cause, link
  every blocked task with `link_task_dependency`, and merge duplicate blocker
  tasks before marking the reconciliation task `Done`.
- Append a changelog entry after completing user-visible or repository-changing work.
- Fail loudly when a required task, project, state, blocker, repo, permission, or secret is missing.
