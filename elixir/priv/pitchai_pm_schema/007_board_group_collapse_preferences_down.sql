begin;

drop table if exists pitchai_symphony.board_group_collapse_preferences;

delete from pitchai_symphony.schema_migrations
where version = '007_board_group_collapse_preferences';

commit;
