begin;

insert into pitchai_symphony.task_state_values (
  state_name,
  category,
  color,
  sort_order,
  is_active,
  is_terminal,
  description,
  metadata
)
values
  ('Suggested', 'queue', '#8b5cf6', -10, false, false, 'Suggested intake item. Promote to Todo when it should be picked up.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Todo', 'queue', '#9ca3af', 10, false, false, 'Canonical not-started queue state.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('In Progress', 'active', '#facc15', 20, true, false, 'Canonical active work state. Active/Symphony Active aliases normalize here.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Human Review', 'review', '#e85d8e', 30, false, false, 'Validated output is waiting for a human review decision.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Merging', 'merge', '#059669', 40, true, false, 'Human-approved work is ready for the automated merge path.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Blocked', 'blocked', '#64748b', 50, false, false, 'Task cannot proceed because a true blocker is recorded.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Done', 'terminal', '#16a34a', 60, false, true, 'Terminal state after successful completion or merge.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Rework', 'rework', '#dc2626', 70, true, false, 'Reviewer requested changes; implementation should continue.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Cancelled', 'terminal', '#94a3b8', 80, false, true, 'Terminal cancelled state.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('Duplicate', 'terminal', '#94a3b8', 90, false, true, 'Terminal duplicate state.', '{"source": "009_canonical_visible_board_states"}'::jsonb)
on conflict (state_name)
do update set
  category = excluded.category,
  color = excluded.color,
  sort_order = excluded.sort_order,
  is_active = excluded.is_active,
  is_terminal = excluded.is_terminal,
  description = excluded.description,
  metadata = pitchai_symphony.task_state_values.metadata || excluded.metadata,
  updated_at = now();

insert into pitchai_symphony.task_state_aliases(alias_name, state_name, reason)
values
  ('Ready', 'Todo', 'Ready is a legacy alias; Todo is the only canonical queued work state.'),
  ('Symphony Ready', 'Todo', 'Symphony Ready is a legacy alias; Todo is the only Symphony dispatch queue state.'),
  ('Backlog', 'Suggested', 'Backlog is retired; Suggested is the canonical intake state.'),
  ('Idea', 'Suggested', 'Idea is retired; Suggested is the canonical intake state.'),
  ('Open', 'Suggested', 'Open is retired; Suggested is the canonical intake state.'),
  ('Enriched', 'Suggested', 'Enriched is retired; Suggested is the canonical intake state.'),
  ('Closed', 'Done', 'Closed is retired; Done is the canonical completed state.')
on conflict (alias_name)
do update set
  state_name = excluded.state_name,
  reason = excluded.reason;

with changed as (
  select
    t.id,
    t.state_name as from_state_name,
    case lower(trim(coalesce(t.state_name, '')))
      when 'ready' then 'Todo'
      when 'symphony ready' then 'Todo'
      when 'backlog' then 'Suggested'
      when 'idea' then 'Suggested'
      when 'open' then 'Suggested'
      when 'enriched' then 'Suggested'
      when 'closed' then 'Done'
    end as to_state_name
  from public.tasks t
  where lower(trim(coalesce(t.state_name, ''))) in (
    'ready',
    'symphony ready',
    'backlog',
    'idea',
    'open',
    'enriched',
    'closed'
  )
),
logged as (
  insert into pitchai_symphony.task_state_normalization_events (
    task_id,
    from_state_name,
    to_state_name,
    reason,
    migration_version
  )
  select
    id,
    from_state_name,
    to_state_name,
    'Normalize retired task state to canonical board state',
    '009_canonical_visible_board_states'
  from changed
  returning task_id, from_state_name, to_state_name
),
updated as (
  update public.tasks t
  set state_name = l.to_state_name,
      updated_at = now()
  from logged l
  where t.id = l.task_id
  returning t.id, l.from_state_name, l.to_state_name
)
insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
select
  id,
  from_state_name,
  to_state_name,
  'migration',
  '009_canonical_visible_board_states',
  '{"migration": "009_canonical_visible_board_states"}'::jsonb
from updated;

delete from pitchai_symphony.workflow_states
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name = 'Symphony Ready';

insert into pitchai_symphony.workflow_states (
  project_id,
  state_name,
  category,
  color,
  sort_order,
  is_active,
  is_terminal,
  is_visible_button,
  next_state_name,
  description,
  metadata
)
values
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Suggested', 'queue', '#8b5cf6', -10, false, false, true, 'Todo', 'Suggested intake item. Promote to Todo when it should be picked up by Symphony.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Todo', 'queue', '#9ca3af', 10, false, false, true, 'In Progress', 'Not started / queued for normal work.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'In Progress', 'active', '#facc15', 20, true, false, true, 'Human Review', 'Canonical active work state. Active aliases normalize here.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Human Review', 'review', '#e85d8e', 30, false, false, true, 'Merging', 'Validated output is waiting for a human review decision.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Merging', 'merge', '#059669', 40, true, false, true, 'Done', 'Human-approved work is ready for the automated merge path.', '{"source": "009_canonical_visible_board_states", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Blocked', 'blocked', '#64748b', 50, false, false, true, null, 'Task cannot proceed because a true blocker is recorded.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Done', 'terminal', '#16a34a', 60, false, true, true, null, 'Terminal state after successful completion or merge.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Rework', 'rework', '#dc2626', 70, true, false, false, 'Human Review', 'Reviewer requested changes; implementation should continue.', '{"source": "009_canonical_visible_board_states", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Cancelled', 'terminal', '#94a3b8', 80, false, true, false, null, 'Terminal cancelled state.', '{"source": "009_canonical_visible_board_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Duplicate', 'terminal', '#94a3b8', 90, false, true, false, null, 'Terminal duplicate state.', '{"source": "009_canonical_visible_board_states"}'::jsonb)
on conflict (project_id, state_name)
do update set
  category = excluded.category,
  color = excluded.color,
  sort_order = excluded.sort_order,
  is_active = excluded.is_active,
  is_terminal = excluded.is_terminal,
  is_visible_button = excluded.is_visible_button,
  next_state_name = excluded.next_state_name,
  description = excluded.description,
  metadata = pitchai_symphony.workflow_states.metadata || excluded.metadata,
  updated_at = now();

delete from pitchai_symphony.task_state_values
where state_name in ('Backlog', 'Symphony Ready', 'Idea', 'Open', 'Enriched', 'Closed');

insert into pitchai_symphony.schema_migrations(version, description)
values ('009_canonical_visible_board_states', 'Remove Ready board state and show canonical Done/Merging columns')
on conflict (version) do nothing;

commit;
