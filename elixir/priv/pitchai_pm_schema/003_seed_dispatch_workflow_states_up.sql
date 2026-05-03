begin;

insert into pitchai_symphony.workflow_states (
  project_id,
  state_name,
  category,
  color,
  sort_order,
  is_active,
  is_terminal,
  is_visible_button,
  next_state_name,
  description,
  metadata
)
values
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Symphony Ready',
    'queue',
    '#2563eb',
    10,
    true,
    false,
    true,
    'Symphony Active',
    'Explicit handoff queue for Symphony. The orchestrator only starts tasks placed here.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  ),
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Symphony Active',
    'active',
    '#7c3aed',
    20,
    true,
    false,
    true,
    'Human Review',
    'Symphony has claimed the task and an agent is actively working.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  ),
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Human Review',
    'review',
    '#f59e0b',
    30,
    false,
    false,
    true,
    'Symphony Merging',
    'Validated output is waiting for a human review decision.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  ),
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Symphony Merging',
    'merge',
    '#059669',
    40,
    true,
    false,
    true,
    'Done',
    'Human-approved work is ready for the automated merge path.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  ),
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Symphony Rework',
    'rework',
    '#dc2626',
    50,
    true,
    false,
    true,
    'Human Review',
    'Reviewer requested changes; Symphony should continue work and return to review.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  ),
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Done',
    'terminal',
    '#16a34a',
    90,
    false,
    true,
    true,
    null,
    'Terminal state after successful completion.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  ),
  (
    'ca072940-142f-4585-aed4-549eb0c4de2b',
    'Blocked',
    'blocked',
    '#64748b',
    100,
    false,
    false,
    true,
    null,
    'Task cannot proceed because a true blocker is recorded.',
    '{"owned_by": "pitchai_symphony"}'::jsonb
  )
on conflict (project_id, state_name)
do update set
  category = excluded.category,
  color = excluded.color,
  sort_order = excluded.sort_order,
  is_active = excluded.is_active,
  is_terminal = excluded.is_terminal,
  is_visible_button = excluded.is_visible_button,
  next_state_name = excluded.next_state_name,
  description = excluded.description,
  metadata = excluded.metadata,
  updated_at = now();

insert into pitchai_symphony.schema_migrations(version, description)
values ('003_seed_dispatch_workflow_states', 'Seed Dispatcher Symphony workflow state buttons')
on conflict (version) do nothing;

commit;
