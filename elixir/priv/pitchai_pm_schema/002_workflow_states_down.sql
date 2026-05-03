begin;

delete from pitchai_symphony.schema_migrations
where version = '002_workflow_states';

drop table if exists pitchai_symphony.task_state_events;
drop table if exists pitchai_symphony.workflow_states;

commit;
