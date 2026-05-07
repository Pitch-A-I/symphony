---
name: pm-db
description: |
  Use Symphony's `pitchai_pm` dynamic tool for raw PitchAI project-management
  task operations, replacing legacy external-tracker GraphQL workflows.
---

# PM DB Operations

Use this skill during Symphony app-server sessions whenever you need task reads,
comments, workpads, state transitions, blockers, changelogs, PR links, or
follow-up task creation in the PitchAI project-management database.

Do not use external issue-tracker GraphQL tools for PitchAI orchestration work.

## Primary Tool

Use the `pitchai_pm` client tool exposed by Symphony's app-server session.

Tool input:

```json
{
  "operation": "get_task",
  "params": {
    "task_id": "00000000-0000-0000-0000-000000000000"
  }
}
```

Tool behavior:

- Send one operation per tool call.
- Treat `{"error": ...}` or failed tool responses as hard failures.
- Keep every operation narrowly scoped to the current task or an explicitly
  related blocker/follow-up.

Operations:

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

## Common Workflows

### Read a task

```json
{"operation": "get_task", "params": {"task_id": "<task-uuid>"}}
```

Use the UUID from the Symphony prompt. Public IDs are display identifiers; UUIDs
are the stable write keys.

### List candidate or related tasks

```json
{
  "operation": "list_tasks",
  "params": {
    "project_id": "<project-uuid>",
    "states": ["Todo", "In Progress", "Blocked"],
    "limit": 20
  }
}
```

### Reconcile blocked tasks

Use these operations when this task is a `blocker_reconciliation_agent` task.

```json
{"operation": "list_blocked_tasks", "params": {"project_id": "<board-project-uuid>"}}
```

```json
{"operation": "list_blocker_tasks", "params": {"project_id": "<board-project-uuid>"}}
```

Use semantic judgment to group equivalent blocker reasons across blocked tasks.
Create or reuse one canonical `Suggested` blocker task per root cause, then link
each blocked task to its canonical blocker.

```json
{
  "operation": "link_task_dependency",
  "params": {
    "task_id": "<blocked-task-uuid>",
    "blocker_task_id": "<canonical-blocker-task-uuid>",
    "relation_type": "blocked_by",
    "metadata": {"blocker_key": "<stable-key>"}
  }
}
```

When two blocker tasks describe the same root cause, keep the clearest task as
canonical and merge the duplicate:

```json
{
  "operation": "merge_duplicate_blocker_task",
  "params": {
    "canonical_task_id": "<canonical-blocker-task-uuid>",
    "duplicate_task_id": "<duplicate-blocker-task-uuid>"
  }
}
```

### Move task state

```json
{
  "operation": "update_task_state",
  "params": {
    "task_id": "<task-uuid>",
    "state_name": "In Progress",
    "reason": "started_work"
  }
}
```

Use canonical states: `Suggested`, `Todo`, `In Progress`, `Human Review`,
`Merging`, `Rework`, `Blocked`, `Done`, `Cancelled`, and `Duplicate`.

### Maintain the workpad

```json
{"operation": "get_workpad", "params": {"task_id": "<task-uuid>"}}
```

```json
{
  "operation": "upsert_workpad",
  "params": {
    "task_id": "<task-uuid>",
    "body": "## Codex Workpad\n\n### Plan\n\n- [ ] ..."
  }
}
```

The workpad is the persistent execution checklist. Keep `Plan`, `Acceptance
Criteria`, `Validation`, `Notes`, and `Blockers` current.

### Add comments, changelogs, and PR links

```json
{
  "operation": "add_comment",
  "params": {
    "task_id": "<task-uuid>",
    "body": "Blocked: <clear blocker reason>",
    "kind": "comment"
  }
}
```

```json
{"operation": "append_changelog", "params": {"task_id": "<task-uuid>", "summary": "Shipped <change>."}}
```

```json
{
  "operation": "attach_pr",
  "params": {
    "task_id": "<task-uuid>",
    "url": "https://github.com/org/repo/pull/123",
    "repo_full_name": "org/repo",
    "branch_name": "feature/example"
  }
}
```

### Create a blocker or follow-up task

```json
{
  "operation": "create_task",
  "params": {
    "project_id": "<project-uuid>",
    "state_name": "Suggested",
    "name": "Unblock: <short summary>",
    "description": {
      "request": "Resolve <blocker> so dependent tasks can continue."
    },
    "value_name": "Task",
    "labels": ["auto-blocker", "blocker", "symphony"],
    "metadata": {
      "managed_by": "pitchai_symphony",
      "symphony_kind": "blocker_task",
      "blocker_key": "<stable-key>"
    }
  }
}
```

Use a single shared blocker task for semantically identical blockers instead of
creating duplicates with different wording.

## Rules

- Treat `public.tasks.state_name` as authoritative.
- Start implementation branches from `origin/staging` unless the task explicitly
  names another base.
- Use `pitchai_symphony.task_workpads` as the persistent execution checklist.
- Use `pitchai_symphony.task_dependencies` for blocker relationships.
- For `symphony_kind = blocker_reconciliation_agent`, call `list_blocked_tasks`
  and `list_blocker_tasks`, semantically unify duplicate blocker descriptions,
  create or reuse one `Suggested` canonical blocker task per root cause, link
  every blocked task with `link_task_dependency`, and merge duplicate blocker
  tasks before marking the reconciliation task `Done`.
- Record true blockers in the workpad `### Blockers`, add a blocker comment,
  and move the task to `Blocked`.
- Append a changelog entry after user-visible or repository-changing work.
- Fail loudly when a required task, project, state, repo, permission, or secret
  is missing.
