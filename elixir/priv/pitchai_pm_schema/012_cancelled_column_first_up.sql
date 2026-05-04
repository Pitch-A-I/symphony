begin;

update pitchai_symphony.task_state_values
set
  sort_order = -20,
  metadata = metadata || '{"source": "012_cancelled_column_first"}'::jsonb,
  updated_at = now()
where state_name = 'Cancelled';

update pitchai_symphony.workflow_states
set
  sort_order = -20,
  metadata = metadata || '{"source": "012_cancelled_column_first"}'::jsonb,
  updated_at = now()
where state_name = 'Cancelled';

insert into pitchai_symphony.schema_migrations(version, description)
values ('012_cancelled_column_first', 'Place Cancelled board column before Suggested')
on conflict (version) do nothing;

commit;
