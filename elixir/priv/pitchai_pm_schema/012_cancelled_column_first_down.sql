begin;

update pitchai_symphony.task_state_values
set
  sort_order = 70,
  metadata = metadata || '{"source": "012_cancelled_column_first_down"}'::jsonb,
  updated_at = now()
where state_name = 'Cancelled';

update pitchai_symphony.workflow_states
set
  sort_order = 70,
  metadata = metadata || '{"source": "012_cancelled_column_first_down"}'::jsonb,
  updated_at = now()
where state_name = 'Cancelled';

delete from pitchai_symphony.schema_migrations
where version = '012_cancelled_column_first';

commit;
