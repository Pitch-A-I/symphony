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
  ('Todo', 'queue', '#9ca3af', 10, false, false, 'Canonical not-started state.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('In Progress', 'active', '#facc15', 20, true, false, 'Canonical active work state. Active/Symphony Active aliases normalize here.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Human Review', 'review', '#e85d8e', 30, false, false, 'Completed work waiting for review.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Symphony Ready', 'queue', '#2563eb', 40, true, false, 'Explicit handoff queue for unattended Symphony work.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Merging', 'merge', '#059669', 50, true, false, 'Human-approved work is ready for the automated merge path.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Rework', 'rework', '#dc2626', 60, true, false, 'Reviewer requested changes; implementation should continue.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Blocked', 'blocked', '#64748b', 70, false, false, 'Task cannot proceed because a true blocker is recorded.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Done', 'terminal', '#16a34a', 200, false, true, 'Terminal state after successful completion or merge.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Cancelled', 'terminal', '#94a3b8', 220, false, true, 'Terminal cancelled state.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('Duplicate', 'terminal', '#94a3b8', 230, false, true, 'Terminal duplicate state.', '{"source": "005_canonical_symphony_states"}'::jsonb)
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
  ('Not Started', 'Todo', 'Todo is the canonical not-started state.'),
  ('Ready', 'Todo', 'Todo is the canonical generic ready/not-started state.'),
  ('Active', 'In Progress', 'Active is represented by canonical In Progress.'),
  ('Symphony Active', 'In Progress', 'Symphony active work is represented by canonical In Progress.'),
  ('Merge', 'Merging', 'Canonical merge-in-progress state is Merging.'),
  ('Symphony Merging', 'Merging', 'Symphony merge work is represented by canonical Merging.'),
  ('Merged', 'Done', 'Merged work is terminal Done.'),
  ('Review', 'Human Review', 'Canonical review handoff state is Human Review.'),
  ('In Review', 'Human Review', 'Canonical review handoff state is Human Review.'),
  ('Symphony Rework', 'Rework', 'Symphony rework is represented by canonical Rework.')
on conflict (alias_name)
do update set
  state_name = excluded.state_name,
  reason = excluded.reason;

with canonicalized as (
  select
    t.id,
    t.state_name as from_state_name,
    pitchai_symphony.normalize_task_state_name(t.state_name) as to_state_name
  from public.tasks t
  where t.state_name is not null
    and btrim(t.state_name) <> ''
),
changed as (
  select *
  from canonicalized
  where to_state_name is not null
    and from_state_name <> to_state_name
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
    'Normalize Symphony state aliases to canonical task states',
    '005_canonical_symphony_states'
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
  '005_canonical_symphony_states',
  '{"migration": "005_canonical_symphony_states"}'::jsonb
from updated;

delete from pitchai_symphony.task_state_values
where state_name in ('Symphony Active', 'Symphony Merging', 'Symphony Rework')
  and not exists (
    select 1
    from public.tasks t
    where t.state_name = pitchai_symphony.task_state_values.state_name
  );

delete from pitchai_symphony.workflow_states
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name in ('Symphony Active', 'Symphony Merging', 'Symphony Rework');

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
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Todo', 'queue', '#9ca3af', 10, false, false, true, 'In Progress', 'Not started / queued for normal work.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'In Progress', 'active', '#facc15', 20, true, false, true, 'Human Review', 'Canonical active work state. Active aliases normalize here.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Human Review', 'review', '#e85d8e', 30, false, false, true, 'Merging', 'Validated output is waiting for a human review decision.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Symphony Ready', 'queue', '#2563eb', 40, true, false, true, 'In Progress', 'Explicit handoff queue for unattended Symphony work.', '{"source": "005_canonical_symphony_states", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Merging', 'merge', '#059669', 50, true, false, true, 'Done', 'Human-approved work is ready for the automated merge path.', '{"source": "005_canonical_symphony_states", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Rework', 'rework', '#dc2626', 60, true, false, true, 'Human Review', 'Reviewer requested changes; implementation should continue.', '{"source": "005_canonical_symphony_states", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Blocked', 'blocked', '#64748b', 70, false, false, true, null, 'Task cannot proceed because a true blocker is recorded.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Done', 'terminal', '#16a34a', 200, false, true, true, null, 'Terminal state after successful completion or merge.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Cancelled', 'terminal', '#94a3b8', 220, false, true, true, null, 'Terminal cancelled state.', '{"source": "005_canonical_symphony_states"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Duplicate', 'terminal', '#94a3b8', 230, false, true, true, null, 'Terminal duplicate state.', '{"source": "005_canonical_symphony_states"}'::jsonb)
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

insert into pitchai_symphony.schema_migrations(version, description)
values ('005_canonical_symphony_states', 'Canonicalize Symphony task states and collapse Active into In Progress')
on conflict (version) do nothing;

commit;
