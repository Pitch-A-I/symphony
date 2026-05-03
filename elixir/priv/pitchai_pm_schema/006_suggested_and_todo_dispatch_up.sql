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
  ('Suggested', 'queue', '#8b5cf6', -10, false, false, 'Suggested intake item. Promote to Todo when it should be picked up.', '{"source": "006_suggested_and_todo_dispatch"}'::jsonb)
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

update pitchai_symphony.task_state_values
set sort_order = 0,
    updated_at = now()
where state_name = 'Backlog';

insert into pitchai_symphony.task_state_aliases(alias_name, state_name, reason)
values
  ('Suggestion', 'Suggested', 'Canonical suggested intake state is Suggested.'),
  ('Proposed', 'Suggested', 'Canonical suggested intake state is Suggested.')
on conflict (alias_name)
do update set
  state_name = excluded.state_name,
  reason = excluded.reason;

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
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Suggested',
    'queue',
    '#8b5cf6',
    -10,
    false,
    false,
    true,
    'Todo',
    'Suggested intake item. Promote to Todo when it should be picked up by Symphony.',
    '{"source": "006_suggested_and_todo_dispatch"}'::jsonb
  )
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

update pitchai_symphony.workflow_states
set sort_order = 0,
    updated_at = now()
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name = 'Backlog';

insert into pitchai_symphony.schema_migrations(version, description)
values ('006_suggested_and_todo_dispatch', 'Add Suggested state and enable Todo as the default Symphony dispatch queue')
on conflict (version) do nothing;

commit;
