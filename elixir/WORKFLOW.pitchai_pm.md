---
tracker:
  kind: pitchai_pm
  project_id: "ca072940-142f-4585-aed4-549eb0c4de2b"
  assignee: "symphony"
  active_states:
    - Todo
    - Symphony Ready
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: /root/code/pitchai_symphony_workspaces
hooks:
  timeout_ms: 300000
  after_create: |
    sh /root/code/pitchai_symphony/elixir/priv/scripts/bootstrap_pitchai_pm_workspace.sh
  before_run: |
    sh /root/code/pitchai_symphony/elixir/priv/scripts/bootstrap_pitchai_pm_workspace.sh
agent:
  max_concurrent_agents: 20
  max_turns: 6
  max_concurrent_agents_by_state:
    Merging: 1
codex:
  command: codex --yolo --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  read_timeout_ms: 30000
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
  turn_sandbox_policy:
    type: dangerFullAccess
server:
  host: 127.0.0.1
  port: 4021
---

You are working on a PitchAI project-management task.

Task context:
ID: {{ issue.id }}
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Use the `pitchai_pm` tool for project-management task reads/writes.
3. Only stop early for a true blocker: missing required auth, permissions, secrets, source checkout, or a required external service. Record the blocker in the workpad `### Blockers`, add a `pitchai_pm.add_comment` blocker summary, and move the task to `Blocked`.
4. Final message must report completed actions and blockers only. Do not include vague next steps for the user.
5. Work only in the provided workspace.

## Tool Contract

Use `pitchai_pm` with JSON input:

```json
{"operation": "get_task", "params": {"task_id": "{{ issue.id }}" }}
```

Supported operations:

- `get_task`
- `list_tasks`
- `update_task_state`
- `list_workflow_states`
- `list_blocked_tasks`
- `list_blocker_tasks`
- `append_changelog`
- `get_workpad`
- `upsert_workpad`
- `add_comment`
- `attach_pr`
- `create_task`
- `link_task_dependency`
- `merge_duplicate_blocker_task`

## Status Map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Suggested` -> intake/proposal; do not work until it is promoted to `Todo`.
- `Todo` or `Not Started` -> queued for Symphony; immediately transition to `In Progress` before active work.
- `Symphony Ready` -> unattended Symphony queue; immediately transition to `In Progress` before active work.
- `Active` or `Symphony Active` -> aliases for `In Progress`; implementation is actively underway.
- `In Progress` -> implementation actively underway. The orchestrator only dispatches In Progress tasks assigned to `symphony`.
- `Human Review` -> PR is attached and validated; waiting on human approval. Do not code.
- `Merging` -> approved by human; execute the `land` skill flow.
- `Rework` -> reviewer requested changes; planning and implementation required.
- `Blocked` -> true blocker recorded; do not continue until unblocked.
- `Done` -> terminal state; no further action required.

## Blocker Reconciliation Agent

If this task description or orchestration metadata has `symphony_kind = blocker_reconciliation_agent`, this is a meta orchestration task rather than product implementation:

1. Run `pitchai_pm.list_blocked_tasks` first.
2. Run `pitchai_pm.list_blocker_tasks` and compare existing canonical blocker tasks with the blocked-task snapshot.
3. Use semantic judgment to unify equivalent blockers even when different blocked tasks describe the same root cause with different wording.
4. Never reopen a terminal canonical blocker task. Terminal blocker states mean that blocker was resolved.
5. If a blocked task only points to terminal blocker tasks, move that task back to `Todo` instead of reopening the blocker.
6. If a task is blocked again by a new reason after an old blocker was resolved, create or link a new canonical blocker task for the new blocker.
7. For each distinct unresolved true blocker, reuse the best existing nonterminal canonical blocker task or create one with `pitchai_pm.create_task` using `state_name = Suggested`, labels `["auto-blocker", "blocker", "symphony"]`, and metadata including `{"managed_by":"pitchai_symphony","symphony_kind":"blocker_task","blocker_key":"<stable-key>"}`.
8. Use `pitchai_pm.link_task_dependency` so every blocked task depends on exactly the right canonical blocker task.
9. Use `pitchai_pm.merge_duplicate_blocker_task` for duplicate blocker tasks. Keep the clearest task as canonical.
10. Append a changelog summary to this reconciliation task and move it to `Done` only after the PM DB writes are complete.

## Required Start Sequence

1. Fetch the task by explicit ID using `pitchai_pm`.
2. Read the current state.
3. If current state is `Todo`, `Not Started`, or `Symphony Ready`, call `pitchai_pm.update_task_state` to set it to `In Progress`.
4. Find the existing workpad with `pitchai_pm.get_workpad`.
5. If missing or outdated, write a `## Codex Workpad` using `pitchai_pm.upsert_workpad`.
6. Start by writing or updating a concrete hierarchical plan in that workpad.
7. Add acceptance criteria and validation checkboxes to the same workpad.
8. Reproduce or inspect the current behavior before code changes whenever the task involves a defect or user-facing behavior.
9. Keep the workpad current after each meaningful milestone.

## Merge Handling

When the task state is `Merging`, open and follow `.codex/skills/land/SKILL.md`. Do not call `gh pr merge` directly. Keep working until the PR is merged or a true blocker is recorded. After merge, call:

```json
{"operation": "update_task_state", "params": {"task_id": "{{ issue.id }}", "state_name": "Done"}}
```

Then append a changelog entry summarizing the merge.

## Completion Bar

Before moving to `Human Review` or `Done`, verify:

- Workpad plan is current.
- Acceptance criteria are checked or explicitly blocked.
- Validation evidence is recorded.
- PR link is attached when a PR exists.
- Changelog entry is appended for user-visible or repo changes.

## Workpad Template

```md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria

- [ ] Criterion

### Validation

- [ ] targeted proof: `<command>`

### Notes

- <timestamped progress note>

### Blockers

- <only include true blockers>
```
