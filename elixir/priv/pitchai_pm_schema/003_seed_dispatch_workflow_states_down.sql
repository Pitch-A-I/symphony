begin;

delete from pitchai_symphony.workflow_states
where project_id = 'ca072940-142f-4585-aed4-549eb0c4de2b'
  and metadata->>'owned_by' = 'pitchai_symphony';

delete from pitchai_symphony.schema_migrations
where version = '003_seed_dispatch_workflow_states';

commit;
