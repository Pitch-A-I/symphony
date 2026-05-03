begin;

drop trigger if exists validate_task_state_name on public.tasks;
drop function if exists pitchai_symphony.validate_task_state_name();

with revertable as (
  select distinct on (task_id)
    task_id,
    from_state_name,
    to_state_name
  from pitchai_symphony.task_state_normalization_events
  where migration_version = '004_task_state_registry'
  order by task_id, created_at desc, id desc
),
reverted as (
  update public.tasks t
  set state_name = r.from_state_name,
      updated_at = now()
  from revertable r
  where t.id = r.task_id
    and t.state_name = r.to_state_name
  returning t.id, r.to_state_name, r.from_state_name
)
insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
select
  id,
  to_state_name,
  from_state_name,
  'migration',
  '004_task_state_registry_down',
  '{"migration": "004_task_state_registry_down"}'::jsonb
from reverted;

drop function if exists pitchai_symphony.normalize_task_state_name(text);
drop table if exists pitchai_symphony.task_state_normalization_events;
drop table if exists pitchai_symphony.task_state_aliases;
drop table if exists pitchai_symphony.task_state_values;

delete from pitchai_symphony.schema_migrations
where version = '004_task_state_registry';

commit;
