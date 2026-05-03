begin;

create table if not exists pitchai_symphony.task_state_values (
  state_name text primary key,
  category text not null,
  color text,
  sort_order integer not null default 0,
  is_active boolean not null default false,
  is_terminal boolean not null default false,
  description text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint task_state_values_state_name_trimmed_check check (state_name = btrim(state_name) and state_name <> ''),
  constraint task_state_values_category_check check (
    category in ('queue', 'active', 'review', 'merge', 'rework', 'terminal', 'blocked', 'other')
  ),
  constraint task_state_values_active_terminal_check check (not (is_active and is_terminal))
);

create unique index if not exists task_state_values_state_name_lower_idx
  on pitchai_symphony.task_state_values (lower(state_name));

create table if not exists pitchai_symphony.task_state_aliases (
  alias_name text primary key,
  state_name text not null references pitchai_symphony.task_state_values(state_name)
    on update cascade
    on delete restrict,
  reason text,
  created_at timestamptz not null default now(),
  constraint task_state_aliases_alias_name_trimmed_check check (alias_name = btrim(alias_name) and alias_name <> ''),
  constraint task_state_aliases_not_self check (lower(alias_name) <> lower(state_name))
);

create unique index if not exists task_state_aliases_alias_name_lower_idx
  on pitchai_symphony.task_state_aliases (lower(alias_name));

create table if not exists pitchai_symphony.task_state_normalization_events (
  id bigserial primary key,
  task_id uuid not null references public.tasks(id) on delete cascade,
  from_state_name text not null,
  to_state_name text not null,
  reason text not null,
  migration_version text not null,
  created_at timestamptz not null default now()
);

create index if not exists task_state_normalization_events_task_idx
  on pitchai_symphony.task_state_normalization_events (task_id, created_at desc);

insert into pitchai_symphony.task_state_values (
  state_name,
  category,
  color,
  sort_order,
  is_active,
  is_terminal,
  description,
  metadata
)
values
  ('Backlog', 'queue', '#d1d5db', 0, false, false, 'Unprioritized or not yet ready for work.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Todo', 'queue', '#9ca3af', 10, false, false, 'Ready for human-managed work.', '{"source": "004_task_state_registry"}'::jsonb),
  ('In Progress', 'active', '#facc15', 20, true, false, 'Canonical active work state. Former Doing/In progress values normalize here.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Human Review', 'review', '#e85d8e', 30, false, false, 'Completed work waiting for review.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Symphony Ready', 'queue', '#2563eb', 40, true, false, 'Explicit handoff queue for Symphony.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Symphony Active', 'active', '#7c3aed', 50, true, false, 'Symphony has claimed the task and an agent is actively working.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Symphony Merging', 'merge', '#059669', 60, true, false, 'Human-approved work is ready for the automated merge path.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Symphony Rework', 'rework', '#dc2626', 70, true, false, 'Reviewer requested changes; Symphony should continue work.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Blocked', 'blocked', '#64748b', 80, false, false, 'Task cannot proceed because a true blocker is recorded.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Idea', 'queue', '#a78bfa', 90, false, false, 'Idea or raw intake item.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Open', 'queue', '#60a5fa', 100, false, false, 'Open but not otherwise classified.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Enriched', 'queue', '#38bdf8', 110, false, false, 'Task has been enriched with additional context.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Done', 'terminal', '#16a34a', 200, false, true, 'Terminal state after successful completion.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Closed', 'terminal', '#475569', 210, false, true, 'Terminal closed state.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Cancelled', 'terminal', '#94a3b8', 220, false, true, 'Terminal cancelled state.', '{"source": "004_task_state_registry"}'::jsonb),
  ('Duplicate', 'terminal', '#94a3b8', 230, false, true, 'Terminal duplicate state.', '{"source": "004_task_state_registry"}'::jsonb)
on conflict (state_name)
do update set
  category = excluded.category,
  color = excluded.color,
  sort_order = excluded.sort_order,
  is_active = excluded.is_active,
  is_terminal = excluded.is_terminal,
  description = excluded.description,
  metadata = pitchai_symphony.task_state_values.metadata || excluded.metadata,
  updated_at = now();

insert into pitchai_symphony.task_state_aliases(alias_name, state_name, reason)
values
  ('Doing', 'In Progress', 'Canonical PM active state is In Progress.'),
  ('To Do', 'Todo', 'Canonical PM queue state is Todo.'),
  ('Canceled', 'Cancelled', 'Canonical PM spelling is Cancelled.')
on conflict (alias_name)
do update set
  state_name = excluded.state_name,
  reason = excluded.reason;

create or replace function pitchai_symphony.normalize_task_state_name(raw_state text)
returns text
language plpgsql
stable
as $$
declare
  clean_state text;
  canonical_state text;
begin
  clean_state := btrim(coalesce(raw_state, ''));

  if clean_state = '' then
    return null;
  end if;

  select a.state_name
    into canonical_state
  from pitchai_symphony.task_state_aliases a
  where lower(a.alias_name) = lower(clean_state)
  limit 1;

  if canonical_state is not null then
    return canonical_state;
  end if;

  select v.state_name
    into canonical_state
  from pitchai_symphony.task_state_values v
  where lower(v.state_name) = lower(clean_state)
  limit 1;

  return canonical_state;
end;
$$;

create or replace function pitchai_symphony.validate_task_state_name()
returns trigger
language plpgsql
as $$
declare
  canonical_state text;
begin
  canonical_state := pitchai_symphony.normalize_task_state_name(new.state_name);

  if new.state_name is null then
    return new;
  end if;

  if btrim(new.state_name) = '' then
    raise exception 'invalid task state_name: blank state names are not allowed.'
      using errcode = '23514';
  end if;

  if canonical_state is null then
    raise exception 'invalid task state_name: "%". Add it to pitchai_symphony.task_state_values or use an existing canonical state.', new.state_name
      using errcode = '23514';
  end if;

  new.state_name := canonical_state;
  return new;
end;
$$;

drop trigger if exists validate_task_state_name on public.tasks;

create trigger validate_task_state_name
before insert or update of state_name on public.tasks
for each row
execute function pitchai_symphony.validate_task_state_name();

with canonicalized as (
  select
    t.id,
    t.state_name as from_state_name,
    pitchai_symphony.normalize_task_state_name(t.state_name) as to_state_name
  from public.tasks t
  where t.state_name is not null
    and btrim(t.state_name) <> ''
),
changed as (
  select *
  from canonicalized
  where to_state_name is not null
    and from_state_name <> to_state_name
),
logged as (
  insert into pitchai_symphony.task_state_normalization_events (
    task_id,
    from_state_name,
    to_state_name,
    reason,
    migration_version
  )
  select
    id,
    from_state_name,
    to_state_name,
    'Normalize aliases before enforcing task state registry',
    '004_task_state_registry'
  from changed
  returning task_id, from_state_name, to_state_name
),
updated as (
  update public.tasks t
  set state_name = l.to_state_name,
      updated_at = now()
  from logged l
  where t.id = l.task_id
  returning t.id, l.from_state_name, l.to_state_name
)
insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
select
  id,
  from_state_name,
  to_state_name,
  'migration',
  '004_task_state_registry',
  '{"migration": "004_task_state_registry"}'::jsonb
from updated;

insert into pitchai_symphony.schema_migrations(version, description)
values ('004_task_state_registry', 'Canonical PM task state registry, aliases, validation trigger, and state normalization')
on conflict (version) do nothing;

commit;
