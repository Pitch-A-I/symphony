begin;

delete from pitchai_symphony.task_state_aliases
where alias_name in ('Suggestion', 'Proposed');

delete from pitchai_symphony.workflow_states
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name = 'Suggested';

delete from pitchai_symphony.task_state_values
where state_name = 'Suggested'
  and not exists (
    select 1
    from public.tasks t
    where t.state_name = 'Suggested'
  );

update pitchai_symphony.task_state_values
set sort_order = 0,
    updated_at = now()
where state_name = 'Backlog';

update pitchai_symphony.workflow_states
set sort_order = 0,
    updated_at = now()
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'::uuid
  and state_name = 'Backlog';

delete from pitchai_symphony.schema_migrations
where version = '006_suggested_and_todo_dispatch';

commit;
