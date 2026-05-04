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
  ('Backlog', 'queue', '#d1d5db', 0, false, false, 'Unprioritized or not yet ready for work.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('Symphony Ready', 'queue', '#2563eb', 40, true, false, 'Explicit handoff queue for unattended Symphony work.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('Idea', 'queue', '#a78bfa', 90, false, false, 'Idea or raw intake item.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('Open', 'queue', '#60a5fa', 100, false, false, 'Open but not otherwise classified.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('Enriched', 'queue', '#38bdf8', 110, false, false, 'Task has been enriched with additional context.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('Closed', 'terminal', '#475569', 210, false, true, 'Terminal closed state.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb)
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

delete from pitchai_symphony.task_state_aliases
where alias_name in ('Symphony Ready', 'Backlog', 'Idea', 'Open', 'Enriched', 'Closed');

insert into pitchai_symphony.task_state_aliases(alias_name, state_name, reason)
values ('Ready', 'Todo', 'Todo is the canonical generic ready/not-started state.')
on conflict (alias_name)
do update set
  state_name = excluded.state_name,
  reason = excluded.reason;

with latest_reversible_event as (
  select distinct on (task_id)
    task_id,
    from_state_name,
    to_state_name
  from pitchai_symphony.task_state_normalization_events
  where migration_version = '009_canonical_visible_board_states'
  order by task_id, created_at desc, id desc
),
reverted as (
  update public.tasks t
  set state_name = e.from_state_name,
      updated_at = now()
  from latest_reversible_event e
  where t.id = e.task_id
    and t.state_name = e.to_state_name
  returning t.id, e.to_state_name, e.from_state_name
)
insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
select
  id,
  to_state_name,
  from_state_name,
  'migration',
  '009_canonical_visible_board_states_down',
  '{"migration": "009_canonical_visible_board_states_down"}'::jsonb
from reverted;

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
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Symphony Ready', 'queue', '#2563eb', 40, true, false, true, 'In Progress', 'Explicit handoff queue for unattended Symphony work.', '{"source": "009_canonical_visible_board_states_down", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Merging', 'merge', '#059669', 50, true, false, true, 'Done', 'Human-approved work is ready for the automated merge path.', '{"source": "009_canonical_visible_board_states_down", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Rework', 'rework', '#dc2626', 60, true, false, true, 'Human Review', 'Reviewer requested changes; implementation should continue.', '{"source": "009_canonical_visible_board_states_down", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Blocked', 'blocked', '#64748b', 70, false, false, true, null, 'Task cannot proceed because a true blocker is recorded.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Done', 'terminal', '#16a34a', 200, false, true, true, null, 'Terminal state after successful completion or merge.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Cancelled', 'terminal', '#94a3b8', 220, false, true, true, null, 'Terminal cancelled state.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Duplicate', 'terminal', '#94a3b8', 230, false, true, true, null, 'Terminal duplicate state.', '{"source": "009_canonical_visible_board_states_down"}'::jsonb)
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

delete from pitchai_symphony.schema_migrations
where version = '009_canonical_visible_board_states';

commit;
