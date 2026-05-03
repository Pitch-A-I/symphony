begin;

create schema if not exists pitchai_symphony;

create table if not exists pitchai_symphony.schema_migrations (
  version text primary key,
  description text not null,
  applied_at timestamptz not null default now()
);

create table if not exists pitchai_symphony.task_tracking (
  task_id uuid primary key references public.tasks(id) on delete cascade,
  priority integer,
  branch_name text,
  url text,
  assignee text,
  labels text[] not null default array[]::text[],
  repo_full_name text,
  repo_url text,
  workspace_path text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint task_tracking_priority_check check (priority is null or priority between 1 and 5)
);

create table if not exists pitchai_symphony.task_dependencies (
  task_id uuid not null references public.tasks(id) on delete cascade,
  blocker_task_id uuid not null references public.tasks(id) on delete cascade,
  relation_type text not null default 'blocked_by',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  primary key (task_id, blocker_task_id, relation_type),
  constraint task_dependencies_not_self check (task_id <> blocker_task_id),
  constraint task_dependencies_relation_type_check check (relation_type in ('blocked_by', 'related'))
);

create table if not exists pitchai_symphony.task_workpads (
  task_id uuid primary key references public.tasks(id) on delete cascade,
  body text not null,
  external_comment_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists pitchai_symphony.task_comments (
  id bigserial primary key,
  task_id uuid not null references public.tasks(id) on delete cascade,
  body text not null,
  author text not null default 'symphony',
  kind text not null default 'comment',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists pitchai_symphony.task_pr_links (
  id bigserial primary key,
  task_id uuid not null references public.tasks(id) on delete cascade,
  url text not null,
  repo_full_name text,
  branch_name text,
  state text not null default 'open',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (task_id, url)
);

create table if not exists pitchai_symphony.task_claims (
  task_id uuid primary key references public.tasks(id) on delete cascade,
  owner text not null,
  run_id uuid not null default gen_random_uuid(),
  lease_until timestamptz not null,
  workspace_path text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists task_tracking_repo_idx on pitchai_symphony.task_tracking (repo_full_name);
create index if not exists task_dependencies_blocker_idx on pitchai_symphony.task_dependencies (blocker_task_id);
create index if not exists task_comments_task_created_idx on pitchai_symphony.task_comments (task_id, created_at desc);
create index if not exists task_pr_links_task_idx on pitchai_symphony.task_pr_links (task_id);
create index if not exists task_claims_lease_idx on pitchai_symphony.task_claims (lease_until);

insert into pitchai_symphony.schema_migrations(version, description)
values ('001_pitchai_symphony', 'PitchAI Symphony orchestration extension tables')
on conflict (version) do nothing;

commit;
