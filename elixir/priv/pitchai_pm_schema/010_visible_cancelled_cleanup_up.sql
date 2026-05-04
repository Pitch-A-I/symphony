begin;

update pitchai_symphony.task_state_values
set
  sort_order = 70,
  is_active = false,
  is_terminal = true,
  description = 'Terminal cancelled state. Symphony stops active app-server work and removes matching workspaces when a task enters this state.',
  metadata = metadata || '{"source": "010_visible_cancelled_cleanup"}'::jsonb,
  updated_at = now()
where state_name = 'Cancelled';

update pitchai_symphony.workflow_states
set
  sort_order = 70,
  is_active = false,
  is_terminal = true,
  is_visible_button = true,
  next_state_name = null,
  description = 'Terminal cancelled state. Dragging here or pressing Stop/Deny stops active app-server work and removes matching workspaces.',
  metadata = metadata || '{"source": "010_visible_cancelled_cleanup"}'::jsonb,
  updated_at = now()
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name = 'Cancelled';

insert into pitchai_symphony.schema_migrations(version, description)
values ('010_visible_cancelled_cleanup', 'Show Cancelled board column and document cancellation cleanup semantics')
on conflict (version) do nothing;

commit;
