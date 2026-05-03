-- This migration intentionally avoids an explicit transaction so indexes can be
-- built concurrently on live PM database tables.

create index concurrently if not exists tasks_project_state_rank_updated_idx
  on public.tasks (
    project_id,
    (lower(trim(coalesce(state_name, '')))),
    rank,
    updated_at desc,
    created_at desc,
    id
  );

create index concurrently if not exists tasks_public_id_idx
  on public.tasks (public_id)
  where public_id is not null;

create index concurrently if not exists task_comments_task_created_id_idx
  on pitchai_symphony.task_comments (task_id, created_at desc, id desc);

create index concurrently if not exists task_state_events_task_created_id_idx
  on pitchai_symphony.task_state_events (task_id, created_at desc, id desc);

create index concurrently if not exists task_pr_links_task_updated_id_idx
  on pitchai_symphony.task_pr_links (task_id, updated_at desc, id desc);

create index concurrently if not exists task_dependencies_blocker_relation_task_idx
  on pitchai_symphony.task_dependencies (blocker_task_id, relation_type, task_id);

create index concurrently if not exists task_dependencies_task_relation_blocker_idx
  on pitchai_symphony.task_dependencies (task_id, relation_type, blocker_task_id);

insert into pitchai_symphony.schema_migrations(version, description)
values ('008_board_click_performance_indexes', 'Add PM board and task detail indexes for fast Kanban issue opens')
on conflict (version) do nothing;
