begin;

drop table if exists pitchai_symphony.github_pr_comment_responses;
drop table if exists pitchai_symphony.github_pr_comment_cursors;

delete from pitchai_symphony.schema_migrations
where version = '013_pr_review_comment_bridge';

commit;
