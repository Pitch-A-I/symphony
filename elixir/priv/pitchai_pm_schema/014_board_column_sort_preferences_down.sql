begin;

drop table if exists pitchai_symphony.board_column_sort_preferences;

delete from pitchai_symphony.schema_migrations
where version = '014_board_column_sort_preferences';

commit;
