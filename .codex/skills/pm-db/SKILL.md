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
    "value_name": "Task"
  }
}
```

Use a single shared blocker task for semantically identical blockers instead of
creating duplicates with different wording.

## Rules

- Treat `public.tasks.state_name` as authoritative.
- Start implementation branches from `origin/staging` unless the task explicitly
  names another base.
- Record true blockers in the workpad `### Blockers`, add a blocker comment,
  and move the task to `Blocked`.
- Append a changelog entry after user-visible or repository-changing work.
- Fail loudly when a required task, project, state, repo, permission, or secret
  is missing.
