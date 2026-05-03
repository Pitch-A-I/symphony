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
  ('Symphony Active', 'active', '#7c3aed', 50, true, false, 'Symphony has claimed the task and an agent is actively working.', '{"source": "005_canonical_symphony_states_down"}'::jsonb),
  ('Symphony Merging', 'merge', '#059669', 60, true, false, 'Human-approved work is ready for the automated merge path.', '{"source": "005_canonical_symphony_states_down"}'::jsonb),
  ('Symphony Rework', 'rework', '#dc2626', 70, true, false, 'Reviewer requested changes; Symphony should continue work.', '{"source": "005_canonical_symphony_states_down"}'::jsonb)
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

with revertable as (
  select distinct on (task_id)
    task_id,
    from_state_name,
    to_state_name
  from pitchai_symphony.task_state_normalization_events
  where migration_version = '005_canonical_symphony_states'
  order by task_id, created_at desc, id desc
),
reverted as (
  update public.tasks t
  set state_name = r.from_state_name,
      updated_at = now()
  from revertable r
  where t.id = r.task_id
    and t.state_name = r.to_state_name
  returning t.id, r.to_state_name, r.from_state_name
)
insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
select
  id,
  to_state_name,
  from_state_name,
  'migration',
  '005_canonical_symphony_states_down',
  '{"migration": "005_canonical_symphony_states_down"}'::jsonb
from reverted;

delete from pitchai_symphony.task_state_aliases
where alias_name in (
  'Not Started',
  'Ready',
  'Active',
  'Symphony Active',
  'Merge',
  'Symphony Merging',
  'Merged',
  'Review',
  'In Review',
  'Symphony Rework'
);

delete from pitchai_symphony.workflow_states
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name in ('Merging', 'Rework');

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
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Symphony Active', 'active', '#7c3aed', 20, true, false, true, 'Human Review', 'Symphony has claimed the task and an agent is actively working.', '{"source": "005_canonical_symphony_states_down", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Symphony Merging', 'merge', '#059669', 40, true, false, true, 'Done', 'Human-approved work is ready for the automated merge path.', '{"source": "005_canonical_symphony_states_down", "owned_by": "pitchai_symphony"}'::jsonb),
  ('ca072940-142f-4585-aed4-549eb0c4de2b', 'Symphony Rework', 'rework', '#dc2626', 50, true, false, true, 'Human Review', 'Reviewer requested changes; Symphony should continue work.', '{"source": "005_canonical_symphony_states_down", "owned_by": "pitchai_symphony"}'::jsonb)
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
where version = '005_canonical_symphony_states';

commit;
