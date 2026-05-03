begin;

create table if not exists pitchai_symphony.workflow_states (
  project_id uuid not null references public.projects(id) on delete cascade,
  state_name text not null,
  category text not null,
  color text,
  sort_order integer not null default 0,
  is_active boolean not null default false,
  is_terminal boolean not null default false,
  is_visible_button boolean not null default true,
  next_state_name text,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (project_id, state_name),
  constraint workflow_states_category_check check (
    category in ('queue', 'active', 'review', 'merge', 'rework', 'terminal', 'blocked')
  ),
  constraint workflow_states_active_terminal_check check (not (is_active and is_terminal))
);

create table if not exists pitchai_symphony.task_state_events (
  id bigserial primary key,
  task_id uuid not null references public.tasks(id) on delete cascade,
  from_state text,
  to_state text not null,
  actor text not null default 'symphony',
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists workflow_states_project_sort_idx
  on pitchai_symphony.workflow_states (project_id, sort_order, state_name);

create index if not exists task_state_events_task_created_idx
  on pitchai_symphony.task_state_events (task_id, created_at desc);

insert into pitchai_symphony.schema_migrations(version, description)
values ('002_workflow_states', 'PitchAI Symphony project workflow states and transition audit')
on conflict (version) do nothing;

commit;
