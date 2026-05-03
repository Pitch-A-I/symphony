begin;

create table if not exists pitchai_symphony.board_group_collapse_preferences (
  board_project_id uuid not null references public.projects(id) on delete cascade,
  actor text not null default 'global',
  group_by text not null,
  column_state_name text not null,
  group_key text not null,
  collapsed boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (board_project_id, actor, group_by, column_state_name, group_key),
  constraint board_group_collapse_preferences_group_by_check
    check (group_by in ('project', 'assignee', 'priority'))
);

create index if not exists board_group_collapse_preferences_lookup_idx
  on pitchai_symphony.board_group_collapse_preferences (
    board_project_id,
    actor,
    group_by,
    column_state_name
  )
  where collapsed;

insert into pitchai_symphony.schema_migrations(version, description)
values ('007_board_group_collapse_preferences', 'Persist Symphony Kanban grouped-column collapse state')
on conflict (version) do nothing;

commit;
