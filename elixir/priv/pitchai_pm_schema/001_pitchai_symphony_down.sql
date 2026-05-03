begin;

drop table if exists pitchai_symphony.task_claims;
drop table if exists pitchai_symphony.task_pr_links;
drop table if exists pitchai_symphony.task_comments;
drop table if exists pitchai_symphony.task_workpads;
drop table if exists pitchai_symphony.task_dependencies;
drop table if exists pitchai_symphony.task_tracking;
drop table if exists pitchai_symphony.schema_migrations;
drop schema if exists pitchai_symphony;

commit;
