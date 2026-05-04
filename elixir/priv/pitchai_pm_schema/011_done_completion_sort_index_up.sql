begin;

create index if not exists task_state_events_done_task_created_idx
  on pitchai_symphony.task_state_events (task_id, created_at desc)
  where lower(trim(coalesce(to_state, ''))) = 'done';

insert into pitchai_symphony.schema_migrations(version, description)
values ('011_done_completion_sort_index', 'Index task Done transition timestamps for board sorting')
on conflict (version) do nothing;

commit;
