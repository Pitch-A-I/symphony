-- This migration intentionally avoids an explicit transaction so indexes can be
-- dropped concurrently on live PM database tables.

drop index concurrently if exists pitchai_symphony.task_dependencies_task_relation_blocker_idx;
drop index concurrently if exists pitchai_symphony.task_dependencies_blocker_relation_task_idx;
drop index concurrently if exists pitchai_symphony.task_pr_links_task_updated_id_idx;
drop index concurrently if exists pitchai_symphony.task_state_events_task_created_id_idx;
drop index concurrently if exists pitchai_symphony.task_comments_task_created_id_idx;
drop index concurrently if exists public.tasks_public_id_idx;
drop index concurrently if exists public.tasks_project_state_rank_updated_idx;

delete from pitchai_symphony.schema_migrations
where version = '008_board_click_performance_indexes';
