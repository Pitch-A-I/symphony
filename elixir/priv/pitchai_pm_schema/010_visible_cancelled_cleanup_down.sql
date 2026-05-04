begin;

update pitchai_symphony.task_state_values
set
  sort_order = 80,
  is_active = false,
  is_terminal = true,
  description = 'Terminal cancelled state.',
  metadata = metadata || '{"source": "010_visible_cancelled_cleanup_down"}'::jsonb,
  updated_at = now()
where state_name = 'Cancelled';

update pitchai_symphony.workflow_states
set
  sort_order = 80,
  is_active = false,
  is_terminal = true,
  is_visible_button = false,
  next_state_name = null,
  description = 'Terminal cancelled state.',
  metadata = metadata || '{"source": "010_visible_cancelled_cleanup_down"}'::jsonb,
  updated_at = now()
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name = 'Cancelled';

delete from pitchai_symphony.schema_migrations
where version = '010_visible_cancelled_cleanup';

commit;
