begin;

create table if not exists pitchai_symphony.board_column_sort_preferences (
  board_project_id uuid not null references public.projects(id) on delete cascade,
  actor text not null default 'global',
  column_state_name text not null,
  sort_key text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (board_project_id, actor, column_state_name),
  constraint board_column_sort_preferences_sort_key_check
    check (sort_key in ('board_order', 'updated_desc', 'created_desc', 'priority_asc', 'title_asc', 'done_time_desc'))
);

create index if not exists board_column_sort_preferences_lookup_idx
  on pitchai_symphony.board_column_sort_preferences (
    board_project_id,
    actor
  );

insert into pitchai_symphony.schema_migrations(version, description)
values ('014_board_column_sort_preferences', 'Persist Symphony Kanban column sort preferences')
on conflict (version) do nothing;

commit;
