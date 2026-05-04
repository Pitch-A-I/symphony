begin;

drop index if exists pitchai_symphony.task_state_events_done_task_created_idx;

delete from pitchai_symphony.schema_migrations
where version = '011_done_completion_sort_index';

commit;
