defmodule SymphonyElixir.PitchAIPM.Client do
  @moduledoc """
  SQL client for PitchAI project-management task orchestration.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PitchAIPM.BlockerReconciler

  @default_limit 100
  @board_task_limit_per_state 1_000
  @connect_timeout 5_000
  @query_timeout 15_000
  @blocker_reconciler_source "pitchai_symphony_blocker_reconciler"
  @blocker_task_labels ["auto-blocker", "blocker", "symphony"]
  @blocker_reconciliation_agent_kind "blocker_reconciliation_agent"
  @blocker_reconciliation_agent_labels ["blocker-reconciliation", "meta-agent", "symphony"]

  @board_default_states [
    %{
      state_name: "Suggested",
      category: "queue",
      color: "#8b5cf6",
      sort_order: -10,
      is_active: false,
      is_terminal: false,
      is_visible_button: true
    },
    %{
      state_name: "Todo",
      category: "queue",
      color: "#9ca3af",
      sort_order: 10,
      is_active: false,
      is_terminal: false,
      is_visible_button: true
    },
    %{
      state_name: "In Progress",
      category: "active",
      color: "#facc15",
      sort_order: 30,
      is_active: false,
      is_terminal: false,
      is_visible_button: true
    },
    %{
      state_name: "Human Review",
      category: "review",
      color: "#e85d8e",
      sort_order: 40,
      is_active: false,
      is_terminal: false,
      is_visible_button: true
    },
    %{
      state_name: "Symphony Ready",
      category: "queue",
      color: "#2563eb",
      sort_order: 50,
      is_active: true,
      is_terminal: false,
      is_visible_button: true
    },
    %{
      state_name: "Merging",
      category: "merge",
      color: "#059669",
      sort_order: 60,
      is_active: true,
      is_terminal: false,
      is_visible_button: false
    },
    %{
      state_name: "Rework",
      category: "rework",
      color: "#dc2626",
      sort_order: 70,
      is_active: true,
      is_terminal: false,
      is_visible_button: false
    },
    %{
      state_name: "Blocked",
      category: "blocked",
      color: "#64748b",
      sort_order: 80,
      is_active: false,
      is_terminal: false,
      is_visible_button: true
    },
    %{
      state_name: "Done",
      category: "terminal",
      color: "#6366f1",
      sort_order: 100,
      is_active: false,
      is_terminal: true,
      is_visible_button: false
    },
    %{
      state_name: "Cancelled",
      category: "terminal",
      color: "#94a3b8",
      sort_order: 110,
      is_active: false,
      is_terminal: true,
      is_visible_button: false
    },
    %{
      state_name: "Canceled",
      category: "terminal",
      color: "#94a3b8",
      sort_order: 111,
      is_active: false,
      is_terminal: true,
      is_visible_button: false
    },
    %{
      state_name: "Duplicate",
      category: "terminal",
      color: "#94a3b8",
      sort_order: 112,
      is_active: false,
      is_terminal: true,
      is_visible_button: false
    }
  ]

  @state_sort_orders %{
    "backlog" => 0,
    "suggested" => -10,
    "todo" => 10,
    "in progress" => 30,
    "human review" => 40,
    "symphony ready" => 50,
    "merging" => 60,
    "rework" => 70,
    "blocked" => 80,
    "idea" => 90,
    "open" => 100,
    "done" => 100,
    "enriched" => 110,
    "cancelled" => 110,
    "canceled" => 111,
    "duplicate" => 112
  }

  @task_select """
  select
    t.id::text as id,
    coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
    t.name as title,
    coalesce(t.description::text, '') as description,
    t.state_name as state,
    tr.priority as priority,
    tr.branch_name as branch_name,
    coalesce(tr.url, '') as url,
    tr.assignee as assignee_id,
    coalesce(tr.labels, array[]::text[]) as labels,
    t.created_at as created_at,
    t.updated_at as updated_at,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', blocker.id::text,
          'identifier', coalesce(nullif(trim(blocker.public_id), ''), 'PM-' || substring(blocker.id::text, 1, 8)),
          'state', blocker.state_name
        )
      ) filter (where blocker.id is not null),
      '[]'::jsonb
    )::text as blocked_by_json
  from public.tasks t
  left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
  left join pitchai_symphony.task_dependencies dep
    on dep.task_id = t.id
   and dep.relation_type = 'blocked_by'
  left join public.tasks blocker on blocker.id = dep.blocker_task_id
  """

  @task_group """
  group by
    t.id,
    t.public_id,
    t.name,
    t.description,
    t.state_name,
    tr.priority,
    tr.branch_name,
    tr.url,
    tr.assignee,
    tr.labels,
    t.created_at,
    t.updated_at
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    settings = Config.settings!().tracker

    with {:ok, project} <- fetch_board_project(settings.project_id),
         {:ok, projects} <- fetch_board_scope_projects(project) do
      fetch_candidate_tasks_by_scope(settings.active_states,
        project_id: settings.project_id,
        scope_project_ids: Enum.map(projects, & &1.id),
        limit: poll_limit(settings),
        assignee: settings.assignee,
        assignee_required_states: ["In Progress"]
      )
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    settings = Config.settings!().tracker
    fetch_tasks_by_states(state_names, project_id: settings.project_id, limit: poll_limit(settings))
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(task_ids) when is_list(task_ids) do
    ids = task_ids |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if ids == [] do
      {:ok, []}
    else
      sql =
        @task_select <>
          """
          where t.id::text = any($1::text[])
          """ <>
          @task_group <>
          """
          order by coalesce(tr.priority, 5), t.created_at nulls last, t.name
          """

      with {:ok, result} <- query(sql, [ids]) do
        {:ok, Enum.map(result.rows, &row_to_issue(result.columns, &1))}
      end
    end
  end

  @spec board_snapshot() :: {:ok, map()} | {:error, term()}
  def board_snapshot do
    project_id = Config.settings!().tracker.project_id |> clean_string()

    if is_nil(project_id) do
      {:error, :missing_pitchai_pm_project_id}
    else
      with {:ok, project} <- fetch_board_project(project_id),
           {:ok, projects} <- fetch_board_scope_projects(project),
           scope_project_ids = Enum.map(projects, & &1.id),
           {:ok, state_counts} <- fetch_board_state_counts(project_id, scope_project_ids),
           {:ok, workflow_states} <- fetch_board_workflow_states(project_id),
           {:ok, tasks} <- fetch_board_tasks(project_id, scope_project_ids),
           {:ok, collapsed_groups} <- fetch_board_collapsed_groups(project_id) do
        columns = build_board_columns(workflow_states, state_counts, tasks)

        {:ok,
         %{
           project: project,
           scope: %{kind: "configured_project_plus_repo_scope_all_tasks", project_ids: scope_project_ids},
           project_options: projects,
           collapsed_groups: collapsed_groups,
           columns: Enum.reject(columns, & &1.hidden?),
           hidden_columns: Enum.filter(columns, & &1.hidden?),
           task_limit_per_column: @board_task_limit_per_state
         }}
      end
    end
  end

  @spec task_detail(String.t()) :: {:ok, map()} | {:error, term()}
  def task_detail(task_id) when is_binary(task_id) do
    sql = """
    select
      t.id::text as id,
      coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
      t.name as title,
      coalesce(t.description::text, '{}') as description_json,
      t.state_name as state,
      t.value_name,
      t.rank,
      t.created_at,
      t.updated_at,
      t.project_id::text as project_id,
      p.name as project_name,
      tr.priority,
      tr.branch_name,
      coalesce(tr.url, '') as url,
      tr.assignee,
      coalesce(tr.labels, array[]::text[]) as labels,
      tr.repo_full_name,
      tr.repo_url,
      tr.workspace_path,
      tr.metadata::text as tracking_metadata_json,
      w.body as workpad_body,
      w.updated_at as workpad_updated_at,
      (
        select c.body
        from pitchai_symphony.task_comments c
        where c.task_id = t.id
          and lower(trim(coalesce(t.state_name, ''))) = 'blocked'
          and lower(trim(coalesce(c.body, ''))) like any(array['blocked%', 'true blocker%'])
        order by c.created_at desc, c.id desc
        limit 1
      ) as blocked_reason,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', c.id,
              'body', c.body,
              'author', c.author,
              'kind', c.kind,
              'metadata', c.metadata,
              'created_at', to_char(c.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            )
            order by c.created_at desc, c.id desc
          )
          from (
            select c.*
            from pitchai_symphony.task_comments c
            where c.task_id = t.id
            order by c.created_at desc, c.id desc
            limit 50
          ) c
        ),
        '[]'::jsonb
      )::text as comments_json,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', pr.id,
              'url', pr.url,
              'repo_full_name', pr.repo_full_name,
              'branch_name', pr.branch_name,
              'state', pr.state,
              'metadata', pr.metadata,
              'created_at', to_char(pr.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
              'updated_at', to_char(pr.updated_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            )
            order by pr.updated_at desc, pr.id desc
          )
          from (
            select pr.*
            from pitchai_symphony.task_pr_links pr
            where pr.task_id = t.id
            order by pr.updated_at desc, pr.id desc
            limit 20
          ) pr
        ),
        '[]'::jsonb
      )::text as prs_json,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', e.id,
              'from_state', e.from_state,
              'to_state', e.to_state,
              'actor', e.actor,
              'reason', e.reason,
              'metadata', e.metadata,
              'created_at', to_char(e.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            )
            order by e.created_at desc, e.id desc
          )
          from (
            select e.*
            from pitchai_symphony.task_state_events e
            where e.task_id = t.id
            order by e.created_at desc, e.id desc
            limit 20
          ) e
        ),
        '[]'::jsonb
      )::text as state_events_json,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', blocker.id::text,
              'identifier', coalesce(nullif(trim(blocker.public_id), ''), 'PM-' || substring(blocker.id::text, 1, 8)),
              'title', blocker.name,
              'state', blocker.state_name
            )
            order by blocker.name
          )
          from pitchai_symphony.task_dependencies dep
          join public.tasks blocker on blocker.id = dep.blocker_task_id
          where dep.task_id = t.id
            and dep.relation_type = 'blocked_by'
        ),
        '[]'::jsonb
      )::text as blockers_json
    from public.tasks t
    left join public.projects p on p.id = t.project_id
    left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    left join pitchai_symphony.task_workpads w on w.task_id = t.id
    where t.id = $1::text::uuid
    """

    case query(sql, [task_id]) do
      {:ok, %{rows: [row], columns: columns}} -> {:ok, task_detail_row_to_map(columns, row)}
      {:ok, %{rows: []}} -> {:error, :task_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_board_task(map()) :: {:ok, map()} | {:error, term()}
  def create_board_task(params) when is_map(params) do
    with {:ok, task_id} <- insert_task(params, "Suggested") do
      task_detail(task_id)
    end
  end

  @spec set_board_group_collapsed(String.t(), String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_board_group_collapsed(group_by, column_state_name, group_key, collapsed?)
      when is_binary(group_by) and is_binary(column_state_name) and is_binary(group_key) and is_boolean(collapsed?) do
    with {:ok, params} <- board_group_collapse_params(group_by, column_state_name, group_key) do
      if collapsed? do
        persist_board_group_collapsed(params.project_id, params.group_by, params.column_state_name, params.group_key)
      else
        clear_board_group_collapsed(params.project_id, params.group_by, params.column_state_name, params.group_key)
      end
    end
  end

  defp board_group_collapse_params(group_by, column_state_name, group_key) do
    with {:ok, project_id} <- board_project_id(),
         {:ok, group_by} <- board_group_by(group_by),
         {:ok, column_state_name} <- required_clean_string(column_state_name, :missing_column_state_name),
         {:ok, group_key} <- required_clean_string(group_key, :missing_group_key) do
      {:ok, %{project_id: project_id, group_by: group_by, column_state_name: column_state_name, group_key: group_key}}
    end
  end

  defp board_project_id do
    case Config.settings!().tracker.project_id |> clean_string() do
      nil -> {:error, :missing_pitchai_pm_project_id}
      project_id -> {:ok, project_id}
    end
  end

  defp board_group_by(group_by) do
    case clean_string(group_by) do
      value when value in ["project", "assignee", "priority"] -> {:ok, value}
      value -> {:error, {:unsupported_board_group_by, value}}
    end
  end

  defp required_clean_string(value, error) do
    case clean_string(value) do
      nil -> {:error, error}
      cleaned -> {:ok, cleaned}
    end
  end

  @spec reconcile_blocked_tasks() :: {:ok, map()} | {:error, term()}
  def reconcile_blocked_tasks do
    with {:ok, project_id} <- board_project_id(),
         {:ok, project} <- fetch_board_project(project_id),
         {:ok, projects} <- fetch_board_scope_projects(project),
         {:ok, released_count} <- release_resolved_blocked_tasks(Enum.map(projects, & &1.id)),
         {:ok, blocked_tasks} <- fetch_blocked_tasks(Enum.map(projects, & &1.id)) do
      with {:ok, result} <- reconcile_blocked_task_groups(blocked_tasks) do
        {:ok, Map.put(result, :released_resolved_blocked_tasks, released_count)}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(task_id, body) when is_binary(task_id) and is_binary(body) do
    sql = """
    insert into pitchai_symphony.task_comments(task_id, body, author, kind)
    values ($1::text::uuid, $2::text, 'symphony', 'comment')
    """

    case query(sql, [task_id, body]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec upsert_assistant_final_message(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def upsert_assistant_final_message(task_id, body, metadata)
      when is_binary(task_id) and is_binary(body) and is_map(metadata) do
    sql = """
    with updated as (
      update pitchai_symphony.task_comments
      set body = $2::text,
          author = 'symphony',
          metadata = $3::text::jsonb,
          created_at = now()
      where task_id = $1::text::uuid
        and kind = 'assistant_final'
      returning id
    )
    insert into pitchai_symphony.task_comments(task_id, body, author, kind, metadata)
    select $1::text::uuid, $2::text, 'symphony', 'assistant_final', $3::text::jsonb
    where not exists (select 1 from updated)
    """

    case query(sql, [task_id, body, Jason.encode!(metadata)]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_blocked_tasks(scope_project_ids) when is_list(scope_project_ids) do
    sql = """
    select
      t.id::text as id,
      coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
      t.name as title,
      t.project_id::text as project_id,
      p.name as project_name,
      tr.repo_full_name,
      tr.workspace_path,
      coalesce(tr.labels, array[]::text[]) as labels,
      (
        select c.body
        from pitchai_symphony.task_comments c
        where c.task_id = t.id
          and lower(trim(coalesce(c.body, ''))) like any(array['blocked%', 'true blocker%'])
        order by c.created_at desc, c.id desc
        limit 1
      ) as blocked_reason,
      w.body as workpad_body,
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', blocker.id::text,
              'identifier', coalesce(nullif(trim(blocker.public_id), ''), 'PM-' || substring(blocker.id::text, 1, 8)),
              'title', blocker.name,
              'state', blocker.state_name,
              'metadata', coalesce(blocker_tracking.metadata, '{}'::jsonb)
            )
            order by blocker.name
          )
          from pitchai_symphony.task_dependencies dep
          join public.tasks blocker on blocker.id = dep.blocker_task_id
          left join pitchai_symphony.task_tracking blocker_tracking on blocker_tracking.task_id = blocker.id
          where dep.task_id = t.id
            and dep.relation_type = 'blocked_by'
        ),
        '[]'::jsonb
      )::text as blockers_json
    from public.tasks t
    left join public.projects p on p.id = t.project_id
    left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    left join pitchai_symphony.task_workpads w on w.task_id = t.id
    where t.project_id::text = any($1::text[])
      and lower(trim(coalesce(t.state_name, ''))) = 'blocked'
    order by p.name, t.updated_at desc nulls last, t.created_at desc nulls last, t.name
    """

    with {:ok, result} <- query(sql, [scope_project_ids]) do
      {:ok, Enum.map(result.rows, &blocked_task_row_to_map(result.columns, &1))}
    end
  end

  defp release_resolved_blocked_tasks(scope_project_ids) when is_list(scope_project_ids) do
    sql = """
    with candidates as (
      select t.id, t.state_name
      from public.tasks t
      where t.project_id::text = any($1::text[])
        and lower(trim(coalesce(t.state_name, ''))) = 'blocked'
        and exists (
          select 1
          from pitchai_symphony.task_dependencies dep
          where dep.task_id = t.id
            and dep.relation_type = 'blocked_by'
        )
        and not exists (
          select 1
          from pitchai_symphony.task_dependencies dep
          join public.tasks blocker on blocker.id = dep.blocker_task_id
          where dep.task_id = t.id
            and dep.relation_type = 'blocked_by'
            and not (lower(trim(coalesce(blocker.state_name, ''))) = any($2::text[]))
        )
    ),
    updated_tasks as (
      update public.tasks t
      set state_name = 'Todo',
          updated_at = now()
      from candidates c
      where t.id = c.id
      returning t.id, c.state_name as from_state, t.state_name as to_state
    ),
    state_events as (
      insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
      select
        id,
        from_state,
        to_state,
        'symphony',
        'resolved_blocker_release',
        jsonb_build_object('source', $3::text)
      from updated_tasks
      where from_state is distinct from to_state
      returning task_id
    ),
    comments as (
      insert into pitchai_symphony.task_comments(task_id, body, author, kind, metadata)
      select
        id,
        'Moved back to Todo because every linked blocker task is now terminal.',
        'symphony',
        'blocker_release',
        jsonb_build_object('source', $3::text)
      from updated_tasks
      returning task_id
    )
    select count(*)::integer
    from updated_tasks
    """

    case query(sql, [scope_project_ids, terminal_state_keys(), @blocker_reconciler_source]) do
      {:ok, %{rows: [[released_count]]}} -> {:ok, released_count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_blocker_tasks(scope_project_ids) when is_list(scope_project_ids) do
    sql = """
    select
      t.id::text as id,
      coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
      t.name as title,
      t.state_name as state,
      t.project_id::text as project_id,
      p.name as project_name,
      coalesce(tr.priority, 5) as priority,
      coalesce(tr.labels, array[]::text[]) as labels,
      tr.metadata::text as metadata_json,
      coalesce(
        (
          select count(distinct dep.task_id)::integer
          from pitchai_symphony.task_dependencies dep
          join public.tasks dependent on dependent.id = dep.task_id
          where dep.blocker_task_id = t.id
            and dep.relation_type = 'blocked_by'
            and not (lower(trim(coalesce(dependent.state_name, ''))) = any($2::text[]))
        ),
        0
      ) as downstream_count
    from public.tasks t
    left join public.projects p on p.id = t.project_id
    join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where t.project_id::text = any($1::text[])
      and coalesce(
        tr.metadata->>'symphony_kind',
        case when jsonb_typeof(tr.metadata) = 'string' then ((tr.metadata #>> '{}')::jsonb)->>'symphony_kind' end
      ) = 'blocker_task'
    order by p.name, coalesce(tr.priority, 5), t.updated_at desc nulls last, t.name
    """

    with {:ok, result} <- query(sql, [scope_project_ids, terminal_state_keys()]) do
      {:ok, Enum.map(result.rows, &blocker_task_row_to_map(result.columns, &1))}
    end
  end

  defp reconcile_blocked_task_groups(blocked_tasks) when is_list(blocked_tasks) do
    groups = BlockerReconciler.group_blocked_tasks(blocked_tasks)

    with {:ok, result} <- maybe_reconcile_blocker_groups(groups) do
      ensure_blocker_reconciliation_agent(groups, result)
    end
  end

  defp maybe_reconcile_blocker_groups(groups) do
    if deterministic_blocker_reconcile?() do
      reconcile_blocker_groups(groups)
    else
      {:ok, blocker_reconcile_base_result(groups)}
    end
  end

  defp deterministic_blocker_reconcile? do
    System.get_env("PITCHAI_SYMPHONY_DETERMINISTIC_BLOCKER_RECONCILE") == "1"
  end

  defp reconcile_blocker_groups(groups) when is_list(groups) do
    Enum.reduce_while(groups, {:ok, blocker_reconcile_base_result(groups)}, fn group, {:ok, acc} ->
      case reconcile_blocker_group(group) do
        {:ok, group_result} ->
          {:cont, {:ok, merge_blocker_reconcile_result(acc, group_result)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp blocker_reconcile_base_result(groups) when is_list(groups) do
    %{
      groups: length(groups),
      blocked_tasks: Enum.sum(Enum.map(groups, &length(&1.tasks))),
      created_blocker_tasks: 0,
      reopened_blocker_tasks: 0,
      merged_duplicate_blocker_tasks: 0,
      linked_dependencies: 0,
      created_reconciliation_agent_tasks: 0,
      updated_reconciliation_agent_tasks: 0,
      skipped_reconciliation_agent_tasks: 0,
      blocker_task_ids: [],
      reconciliation_agent_task_ids: []
    }
  end

  defp ensure_blocker_reconciliation_agent([], result), do: {:ok, result}

  defp ensure_blocker_reconciliation_agent(groups, result) when is_list(groups) and is_map(result) do
    settings = Config.settings!().tracker
    project_id = clean_string(settings.project_id)
    snapshot = blocker_reconciliation_agent_snapshot(groups)
    snapshot_hash = blocker_reconciliation_snapshot_hash(snapshot)

    with {:ok, existing_tasks} <- fetch_blocker_reconciliation_agent_tasks(project_id) do
      existing_tasks
      |> pick_blocker_reconciliation_agent_action(snapshot_hash)
      |> apply_blocker_reconciliation_agent_action(project_id, snapshot, snapshot_hash, result)
    end
  end

  defp apply_blocker_reconciliation_agent_action({:update, task}, _project_id, snapshot, snapshot_hash, result) do
    with :ok <- refresh_blocker_reconciliation_agent_task(task, snapshot, snapshot_hash) do
      {:ok, Map.update!(result, :updated_reconciliation_agent_tasks, &(&1 + 1))}
    end
  end

  defp apply_blocker_reconciliation_agent_action(:skip, _project_id, _snapshot, _snapshot_hash, result) do
    {:ok, Map.update!(result, :skipped_reconciliation_agent_tasks, &(&1 + 1))}
  end

  defp apply_blocker_reconciliation_agent_action(:create, project_id, snapshot, snapshot_hash, result) do
    with {:ok, task_id} <- insert_blocker_reconciliation_agent_task(project_id, snapshot, snapshot_hash) do
      {:ok,
       result
       |> Map.update!(:created_reconciliation_agent_tasks, &(&1 + 1))
       |> Map.update!(:reconciliation_agent_task_ids, &Enum.uniq([task_id | &1]))}
    end
  end

  defp blocker_reconciliation_agent_snapshot(groups) do
    %{
      "blocked_task_count" => Enum.sum(Enum.map(groups, &length(&1.tasks))),
      "group_count" => length(groups),
      "groups" => Enum.map(groups, &blocker_reconciliation_agent_group/1)
    }
  end

  defp blocker_reconciliation_agent_group(group) do
    %{
      "project_id" => group.project_id,
      "project_name" => group.project_name,
      "blocker_key" => group.blocker_key,
      "summary" => group.summary,
      "reason_samples" => group.reason_samples,
      "blocked_tasks" => Enum.map(group.tasks, &blocked_task_tool_map/1)
    }
  end

  defp blocker_reconciliation_snapshot_hash(snapshot) when is_map(snapshot) do
    snapshot
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fetch_blocker_reconciliation_agent_tasks(project_id) when is_binary(project_id) do
    sql = """
    select
      t.id::text,
      coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
      t.state_name,
      coalesce(
        tr.metadata->>'blocker_snapshot_hash',
        case when jsonb_typeof(tr.metadata) = 'string' then ((tr.metadata #>> '{}')::jsonb)->>'blocker_snapshot_hash' end
      ) as blocker_snapshot_hash
    from public.tasks t
    join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where t.project_id = $1::text::uuid
      and coalesce(
        tr.metadata->>'symphony_kind',
        case when jsonb_typeof(tr.metadata) = 'string' then ((tr.metadata #>> '{}')::jsonb)->>'symphony_kind' end
      ) = $2::text
    order by t.updated_at desc nulls last, t.created_at desc nulls last
    limit 10
    """

    with {:ok, result} <- query(sql, [project_id, @blocker_reconciliation_agent_kind]) do
      {:ok,
       Enum.map(result.rows, fn [id, identifier, state, snapshot_hash] ->
         %{id: id, identifier: identifier, state: state, snapshot_hash: snapshot_hash}
       end)}
    end
  end

  defp fetch_blocker_reconciliation_agent_tasks(_project_id), do: {:ok, []}

  defp pick_blocker_reconciliation_agent_action(existing_tasks, snapshot_hash) do
    terminal_states = terminal_state_keys()

    active_task =
      Enum.find(existing_tasks, fn task ->
        normalize_state_key(task.state) not in terminal_states
      end)

    cond do
      is_map(active_task) and active_task.snapshot_hash == snapshot_hash ->
        :skip

      is_map(active_task) ->
        {:update, active_task}

      Enum.any?(existing_tasks, fn task -> task.snapshot_hash == snapshot_hash end) ->
        :skip

      true ->
        :create
    end
  end

  defp insert_blocker_reconciliation_agent_task(project_id, snapshot, snapshot_hash) do
    insert_task(
      %{
        "project_id" => project_id,
        "name" => blocker_reconciliation_agent_title(snapshot),
        "state_name" => "Todo",
        "value_name" => "Task",
        "description" => blocker_reconciliation_agent_description(snapshot, snapshot_hash),
        "priority" => 1,
        "assignee" => clean_string(Config.settings!().tracker.assignee) || "symphony",
        "labels" => @blocker_reconciliation_agent_labels,
        "metadata" => blocker_reconciliation_agent_metadata(snapshot, snapshot_hash)
      },
      "Todo"
    )
  end

  defp refresh_blocker_reconciliation_agent_task(task, snapshot, snapshot_hash) do
    sql = """
    with updated_task as (
      update public.tasks
      set
        name = $2::text,
        description = $3::text::jsonb,
        updated_at = now()
      where id = $1::text::uuid
      returning id
    )
    insert into pitchai_symphony.task_tracking(task_id, priority, assignee, labels, metadata)
    select id, 1, $4::text, $5::text[], $6::text::jsonb
    from updated_task
    on conflict (task_id)
    do update set
      priority = excluded.priority,
      assignee = excluded.assignee,
      labels = (
        select array_agg(distinct label order by label)
        from unnest(coalesce(pitchai_symphony.task_tracking.labels, array[]::text[]) || excluded.labels) label
      ),
      metadata = pitchai_symphony.task_tracking.metadata || excluded.metadata,
      updated_at = now()
    """

    params = [
      task.id,
      blocker_reconciliation_agent_title(snapshot),
      Jason.encode!(blocker_reconciliation_agent_description(snapshot, snapshot_hash)),
      clean_string(Config.settings!().tracker.assignee) || "symphony",
      @blocker_reconciliation_agent_labels,
      Jason.encode!(blocker_reconciliation_agent_metadata(snapshot, snapshot_hash))
    ]

    case query(sql, params) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp blocker_reconciliation_agent_title(snapshot) do
    "Reconcile #{snapshot["blocked_task_count"]} blocked PM task(s)"
  end

  defp blocker_reconciliation_agent_description(snapshot, snapshot_hash) do
    %{
      "request" =>
        "Run an app-server PM blocker reconciliation pass. Use the pitchai_pm tool to inspect blocked tasks, create or update canonical Suggested blocker tasks, merge duplicate blocker tasks, and link every blocked task to the right canonical blocker.",
      "instructions" => [
        "Call list_blocked_tasks first and compare it with this snapshot.",
        "Use semantic judgment to unify equivalent blockers even when their text differs.",
        "Create one canonical Suggested blocker task per distinct unresolved true blocker.",
        "Never reopen a terminal canonical blocker task. Terminal blocker states mean that blocker was resolved.",
        "If a blocked task only points to terminal blocker tasks, move that task back to Todo instead of reopening the blocker.",
        "If a task is blocked again by a new reason after an old blocker was resolved, create or link a new canonical blocker task for the new blocker.",
        "Use link_task_dependency so every blocked task points at its canonical blocker task.",
        "Use merge_duplicate_blocker_task when multiple blocker tasks describe the same blocker.",
        "Do not mark this reconciliation task Done until dependencies and duplicate states are written."
      ],
      "snapshot_hash" => snapshot_hash,
      "snapshot" => snapshot,
      "orchestration" => %{
        "source" => @blocker_reconciler_source,
        "symphony_kind" => @blocker_reconciliation_agent_kind
      }
    }
  end

  defp blocker_reconciliation_agent_metadata(snapshot, snapshot_hash) do
    %{
      "managed_by" => "pitchai_symphony",
      "source" => @blocker_reconciler_source,
      "symphony_kind" => @blocker_reconciliation_agent_kind,
      "blocker_snapshot_hash" => snapshot_hash,
      "blocked_task_count" => snapshot["blocked_task_count"],
      "group_count" => snapshot["group_count"]
    }
  end

  defp reconcile_blocker_group(group) when is_map(group) do
    with {:ok, blocker_task, created?, reopened?, duplicate_count} <- fetch_or_create_blocker_task(group),
         {:ok, linked_count} <- link_blocked_tasks_to_blocker(group, blocker_task) do
      {:ok,
       %{
         created_blocker_tasks: if(created?, do: 1, else: 0),
         reopened_blocker_tasks: if(reopened?, do: 1, else: 0),
         merged_duplicate_blocker_tasks: duplicate_count,
         linked_dependencies: linked_count,
         blocker_task_ids: [blocker_task.id]
       }}
    end
  end

  defp fetch_or_create_blocker_task(group) do
    case fetch_existing_blocker_tasks(group.project_id, group.blocker_key) do
      {:ok, []} ->
        with {:ok, blocker_task} <- insert_blocker_task(group) do
          {:ok, blocker_task, true, false, 0}
        end

      {:ok, [canonical_task | duplicate_tasks]} ->
        with {:ok, duplicate_count} <- merge_duplicate_blocker_tasks(canonical_task, duplicate_tasks),
             {:ok, refreshed_task, reopened?} <- refresh_blocker_task(canonical_task, group) do
          {:ok, refreshed_task, false, reopened?, duplicate_count}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_existing_blocker_tasks(project_id, blocker_key) do
    sql = """
    select
      t.id::text as id,
      coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
      t.state_name as state
    from public.tasks t
    join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where t.project_id = $1::text::uuid
      and not (lower(trim(coalesce(t.state_name, ''))) = any($3::text[]))
      and coalesce(
        tr.metadata->>'symphony_kind',
        case when jsonb_typeof(tr.metadata) = 'string' then ((tr.metadata #>> '{}')::jsonb)->>'symphony_kind' end
      ) = 'blocker_task'
      and coalesce(
        tr.metadata->>'blocker_key',
        case when jsonb_typeof(tr.metadata) = 'string' then ((tr.metadata #>> '{}')::jsonb)->>'blocker_key' end
      ) = $2::text
    order by
      t.updated_at desc nulls last,
      t.created_at desc nulls last
    """

    case query(sql, [project_id, blocker_key, terminal_state_keys()]) do
      {:ok, result} ->
        {:ok,
         Enum.map(result.rows, fn [id, identifier, state] ->
           %{id: id, identifier: identifier, state: state}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_blocker_task(group) do
    description = blocker_description(group)
    metadata = blocker_tracking_metadata(group)
    comment_body = blocker_task_comment_body(group)

    sql = """
    with inserted_task as (
      insert into public.tasks(id, created_at, updated_at, name, description, project_id, state_name, value_name, is_bug)
      values (gen_random_uuid(), now(), now(), $1::text, $2::text::jsonb, $3::text::uuid, 'Suggested', 'Task', false)
      returning id, public_id, state_name
    ),
    tracking as (
      insert into pitchai_symphony.task_tracking(task_id, priority, assignee, labels, metadata)
      select id, 1, 'symphony', $4::text[], $5::text::jsonb
      from inserted_task
      on conflict (task_id)
      do update set
        priority = excluded.priority,
        assignee = excluded.assignee,
        labels = (
          select array_agg(distinct label order by label)
          from unnest(coalesce(pitchai_symphony.task_tracking.labels, array[]::text[]) || excluded.labels) label
        ),
        metadata = pitchai_symphony.task_tracking.metadata || excluded.metadata,
        updated_at = now()
      returning task_id
    ),
    comment as (
      insert into pitchai_symphony.task_comments(task_id, body, author, kind, metadata)
      select id, $6::text, 'symphony', 'blocker', $7::text::jsonb
      from inserted_task
      returning task_id
    )
    select
      id::text,
      coalesce(nullif(trim(public_id), ''), 'PM-' || substring(id::text, 1, 8)) as identifier,
      state_name
    from inserted_task
    """

    params = [
      blocker_title(group),
      Jason.encode!(description),
      group.project_id,
      @blocker_task_labels,
      Jason.encode!(metadata),
      comment_body,
      Jason.encode!(%{"source" => @blocker_reconciler_source, "blocker_key" => group.blocker_key})
    ]

    case query(sql, params) do
      {:ok, %{rows: [[id, identifier, state]]}} -> {:ok, %{id: id, identifier: identifier, state: state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_blocker_task(blocker_task, group) do
    description = blocker_description(group)
    metadata = blocker_tracking_metadata(group)

    sql = """
    with current_task as (
      select id, state_name
      from public.tasks
      where id = $1::text::uuid
    ),
    updated_task as (
      update public.tasks t
      set description = coalesce(t.description, '{}'::jsonb) || $2::text::jsonb,
          updated_at = now()
      from current_task c
      where t.id = c.id
      returning
        t.id,
        coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
        c.state_name as from_state,
        t.state_name as to_state
    ),
    tracking as (
      insert into pitchai_symphony.task_tracking(task_id, priority, assignee, labels, metadata)
      select id, 1, 'symphony', $3::text[], $4::text::jsonb
      from updated_task
      on conflict (task_id)
      do update set
        priority = excluded.priority,
        assignee = excluded.assignee,
        labels = (
          select array_agg(distinct label order by label)
          from unnest(coalesce(pitchai_symphony.task_tracking.labels, array[]::text[]) || excluded.labels) label
        ),
        metadata = pitchai_symphony.task_tracking.metadata || excluded.metadata,
        updated_at = now()
      returning task_id
    )
    select
      id::text,
      identifier,
      to_state,
      false as reopened
    from updated_task
    """

    params = [
      blocker_task.id,
      Jason.encode!(description),
      @blocker_task_labels,
      Jason.encode!(metadata)
    ]

    case query(sql, params) do
      {:ok, %{rows: [[id, identifier, state, reopened?]]}} ->
        {:ok, %{id: id, identifier: identifier, state: state}, reopened?}

      {:ok, %{rows: []}} ->
        {:error, :blocker_task_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_duplicate_blocker_tasks(_canonical_task, []), do: {:ok, 0}

  defp merge_duplicate_blocker_tasks(canonical_task, duplicate_tasks) do
    Enum.reduce_while(duplicate_tasks, {:ok, 0}, fn duplicate_task, {:ok, count} ->
      case merge_duplicate_blocker_task(canonical_task, duplicate_task) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp merge_duplicate_blocker_task(canonical_task, duplicate_task) do
    sql = """
    with current_canonical as (
      select id
      from public.tasks
      where id = $1::text::uuid
    ),
    moved_dependencies as (
      insert into pitchai_symphony.task_dependencies(task_id, blocker_task_id, relation_type, metadata)
      select
        dep.task_id,
        $1::text::uuid,
        dep.relation_type,
        dep.metadata || jsonb_build_object(
          'source', $3::text,
          'merged_from_blocker_task_id', $2::text
        )
      from pitchai_symphony.task_dependencies dep
      where dep.blocker_task_id = $2::text::uuid
        and dep.task_id <> $1::text::uuid
        and exists(select 1 from current_canonical)
      on conflict (task_id, blocker_task_id, relation_type)
      do update set metadata = pitchai_symphony.task_dependencies.metadata || excluded.metadata
      returning task_id
    ),
    removed_duplicate_dependencies as (
      delete from pitchai_symphony.task_dependencies dep
      where dep.blocker_task_id = $2::text::uuid
        and exists(select 1 from current_canonical)
      returning task_id
    ),
    current_duplicate as (
      select id, state_name
      from public.tasks
      where id = $2::text::uuid
    ),
    updated_duplicate as (
      update public.tasks t
      set state_name = 'Duplicate',
          updated_at = now()
      from current_duplicate c
      where t.id = c.id
        and exists(select 1 from current_canonical)
      returning t.id, c.state_name as from_state, t.state_name as to_state
    ),
    state_event as (
      insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason, metadata)
      select
        id,
        from_state,
        to_state,
        'symphony',
        'blocker_reconciler_duplicate_merged',
        jsonb_build_object(
          'source', $3::text,
          'canonical_blocker_task_id', $1::text,
          'duplicate_blocker_task_id', $2::text
        )
      from updated_duplicate
      where from_state is distinct from to_state
      returning task_id
    )
    select
      (select count(*)::integer from current_canonical) as canonical_count,
      (select count(*)::integer from current_duplicate) as duplicate_count,
      (select count(*)::integer from updated_duplicate) as updated_duplicate_count
    """

    case query(sql, [canonical_task.id, duplicate_task.id, @blocker_reconciler_source]) do
      {:ok, %{rows: [[0, _duplicate_count, _updated_duplicate_count]]}} ->
        {:error, :canonical_blocker_task_not_found}

      {:ok, %{rows: [[_canonical_count, 0, _updated_duplicate_count]]}} ->
        {:error, :duplicate_blocker_task_not_found}

      {:ok, %{rows: [[_canonical_count, _duplicate_count, 0]]}} ->
        {:error, :duplicate_blocker_task_not_updated}

      {:ok, %{rows: [[_canonical_count, _duplicate_count, _updated_duplicate_count]]}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_blocked_tasks_to_blocker(group, blocker_task) do
    task_ids =
      group.tasks
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&(&1 in [nil, blocker_task.id]))

    if task_ids == [] do
      {:ok, 0}
    else
      dependency_metadata = %{
        "source" => @blocker_reconciler_source,
        "blocker_key" => group.blocker_key,
        "reason_summary" => group.summary
      }

      comment_metadata = %{
        "source" => @blocker_reconciler_source,
        "blocker_task_id" => blocker_task.id,
        "blocker_key" => group.blocker_key
      }

      sql = """
      with inserted_dependency as (
        insert into pitchai_symphony.task_dependencies(task_id, blocker_task_id, relation_type, metadata)
        select source.task_id::uuid, $2::text::uuid, 'blocked_by', $3::text::jsonb
        from unnest($1::text[]) as source(task_id)
        where source.task_id::uuid <> $2::text::uuid
        on conflict (task_id, blocker_task_id, relation_type) do nothing
        returning task_id
      ),
      inserted_comment as (
        insert into pitchai_symphony.task_comments(task_id, body, author, kind, metadata)
        select task_id, $4::text, 'symphony', 'blocker_link', $5::text::jsonb
        from inserted_dependency
        returning task_id
      )
      select count(*)::integer
      from inserted_dependency
      """

      params = [
        task_ids,
        blocker_task.id,
        Jason.encode!(dependency_metadata),
        linked_blocker_comment_body(blocker_task, group),
        Jason.encode!(comment_metadata)
      ]

      case query(sql, params) do
        {:ok, %{rows: [[linked_count]]}} -> {:ok, linked_count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp merge_blocker_reconcile_result(acc, result) do
    acc
    |> Map.update!(:created_blocker_tasks, &(&1 + result.created_blocker_tasks))
    |> Map.update!(:reopened_blocker_tasks, &(&1 + result.reopened_blocker_tasks))
    |> Map.update!(:merged_duplicate_blocker_tasks, &(&1 + result.merged_duplicate_blocker_tasks))
    |> Map.update!(:linked_dependencies, &(&1 + result.linked_dependencies))
    |> Map.update!(:blocker_task_ids, &Enum.uniq(&1 ++ result.blocker_task_ids))
  end

  defp blocker_title(group) do
    group.summary
    |> then(&"Unblock: #{&1}")
    |> truncate_string(180)
  end

  defp blocker_description(group) do
    %{
      "request" =>
        "Resolve this shared blocker so Symphony can resume the dependent PM tasks. If this duplicates another blocker task, keep one canonical blocker and keep dependencies linked to that canonical task.",
      "summary" => group.summary,
      "blocker_key" => group.blocker_key,
      "blocked_task_count" => length(group.tasks),
      "blocked_tasks" => group.tasks |> Enum.take(25) |> Enum.map(&BlockerReconciler.task_descriptor/1),
      "reason_samples" => group.reason_samples,
      "orchestration" => %{
        "source" => @blocker_reconciler_source,
        "symphony_kind" => "blocker_task"
      }
    }
  end

  defp blocker_tracking_metadata(group) do
    %{
      "managed_by" => "pitchai_symphony",
      "source" => @blocker_reconciler_source,
      "symphony_kind" => "blocker_task",
      "blocker_key" => group.blocker_key,
      "blocked_task_count" => length(group.tasks),
      "reason_samples" => group.reason_samples
    }
  end

  defp blocker_task_comment_body(group) do
    """
    Auto-created blocker task.

    Blocker key: #{group.blocker_key}
    Impact: #{length(group.tasks)} blocked downstream task(s)
    Summary: #{group.summary}

    Dependent tasks:
    #{blocked_task_comment_lines(group.tasks)}
    """
    |> String.trim()
  end

  defp linked_blocker_comment_body(blocker_task, group) do
    "Linked to blocker task #{blocker_task.identifier}: #{group.summary}"
  end

  defp blocked_task_comment_lines(tasks) do
    tasks
    |> Enum.take(20)
    |> Enum.map_join("\n", fn task -> "- #{Map.get(task, :identifier)}: #{Map.get(task, :title)}" end)
  end

  defp blocked_task_row_to_map(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      project_id: data["project_id"],
      project_name: clean_string(data["project_name"]),
      repo_full_name: clean_string(data["repo_full_name"]),
      workspace_path: clean_string(data["workspace_path"]),
      labels: labels(data["labels"]),
      blocked_reason: clean_string(data["blocked_reason"]),
      workpad_body: clean_string(data["workpad_body"]),
      blockers: decode_json_array(data["blockers_json"])
    }
  end

  defp blocker_task_row_to_map(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      "id" => data["id"],
      "identifier" => data["identifier"],
      "title" => data["title"],
      "state" => data["state"],
      "project_id" => data["project_id"],
      "project_name" => clean_string(data["project_name"]),
      "priority" => data["priority"],
      "labels" => labels(data["labels"]),
      "metadata" => decode_json_object(data["metadata_json"]),
      "downstream_count" => data["downstream_count"] || 0
    }
  end

  defp blocked_task_tool_map(task) when is_map(task) do
    %{
      "id" => Map.get(task, :id),
      "identifier" => Map.get(task, :identifier),
      "title" => Map.get(task, :title),
      "project_id" => Map.get(task, :project_id),
      "project_name" => Map.get(task, :project_name),
      "blocker_reason" => Map.get(task, :blocker_reason),
      "blocker_key" => Map.get(task, :blocker_key),
      "repo_full_name" => Map.get(task, :repo_full_name),
      "workspace_path" => Map.get(task, :workspace_path),
      "labels" => Map.get(task, :labels) || [],
      "current_blockers" => Map.get(task, :blockers) || []
    }
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name), do: update_issue_state(task_id, state_name, "tracker_update")

  @spec move_issue_on_board(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def move_issue_on_board(task_id, state_name, opts)
      when is_binary(task_id) and is_binary(state_name) and is_map(opts) do
    with clean_state when not is_nil(clean_state) <- clean_string(state_name),
         {:ok, _task_context} <- fetch_board_task_context(task_id),
         {:ok, current_target_ids} <-
           fetch_ordered_board_task_ids(clean_state, task_id),
         {:ok, ordered_target_ids} <-
           insert_board_task_id(
             current_target_ids,
             task_id,
             clean_string(Map.get(opts, :before_task_id) || Map.get(opts, "before_task_id")),
             clean_string(Map.get(opts, :after_task_id) || Map.get(opts, "after_task_id"))
           ),
         :ok <- update_issue_state(task_id, clean_state, clean_string(Map.get(opts, :reason)) || "kanban_drag_drop"),
         :ok <- persist_board_task_ranks(ordered_target_ids) do
      :ok
    else
      nil -> {:error, :missing_state_name}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name, reason)
      when is_binary(task_id) and is_binary(state_name) and is_binary(reason) do
    clean_state = String.trim(state_name)

    if clean_state == "" do
      {:error, :missing_state_name}
    else
      sql = """
      with current_task as (
        select id, state_name
        from public.tasks
        where id = $1::text::uuid
      ),
      updated_task as (
        update public.tasks t
        set state_name = $2::text,
            updated_at = now()
        from current_task c
        where t.id = c.id
        returning t.id, c.state_name as from_state, t.state_name as to_state
      ),
      symphony_tracking as (
        insert into pitchai_symphony.task_tracking(task_id, assignee, labels, metadata)
        select
          id,
          $4::text,
          array['symphony']::text[],
          jsonb_build_object('managed_by', 'pitchai_symphony')
        from updated_task
        where $4::text is not null
          and lower(trim(coalesce(to_state, ''))) = any($5::text[])
        on conflict (task_id)
        do update set
          assignee = excluded.assignee,
          labels = (
            select array_agg(distinct label order by label)
            from unnest(coalesce(pitchai_symphony.task_tracking.labels, array[]::text[]) || excluded.labels) label
          ),
          metadata = pitchai_symphony.task_tracking.metadata || excluded.metadata,
          updated_at = now()
        returning task_id
      )
      insert into pitchai_symphony.task_state_events(task_id, from_state, to_state, actor, reason)
      select id, from_state, to_state, 'symphony', $3::text
      from updated_task
      returning task_id::text
      """

      case query(sql, [
             task_id,
             clean_state,
             String.trim(reason),
             clean_string(Config.settings!().tracker.assignee),
             managed_state_keys()
           ]) do
        {:ok, %{rows: [[_updated_task_id]]}} -> :ok
        {:ok, %{rows: []}} -> {:error, :task_not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec tool_operation(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def tool_operation(operation, params) when is_binary(operation) and is_map(params) do
    operation_handlers = %{
      "get_task" => &tool_get_task/1,
      "list_tasks" => &tool_list_tasks/1,
      "list_workflow_states" => &tool_list_workflow_states/1,
      "list_blocked_tasks" => &tool_list_blocked_tasks/1,
      "list_blocker_tasks" => &tool_list_blocker_tasks/1,
      "update_task_state" => &tool_update_task_state/1,
      "append_changelog" => &tool_append_changelog/1,
      "get_workpad" => &tool_get_workpad/1,
      "upsert_workpad" => &tool_upsert_workpad/1,
      "add_comment" => &tool_add_comment/1,
      "attach_pr" => &tool_attach_pr/1,
      "create_task" => &tool_create_task/1,
      "link_task_dependency" => &tool_link_task_dependency/1,
      "merge_duplicate_blocker_task" => &tool_merge_duplicate_blocker_task/1
    }

    normalized_operation = String.trim(operation)

    case Map.fetch(operation_handlers, normalized_operation) do
      {:ok, handler} -> handler.(params)
      :error -> {:error, {:unsupported_pitchai_pm_operation, normalized_operation}}
    end
  end

  defp fetch_candidate_tasks_by_scope(state_names, opts) do
    normalized_states = normalize_states(state_names)
    project_id = Keyword.fetch!(opts, :project_id)
    scope_project_ids = Keyword.fetch!(opts, :scope_project_ids)
    limit = Keyword.get(opts, :limit, @default_limit)
    assignee = opts |> Keyword.get(:assignee) |> clean_string()
    assignee_required_states = Keyword.get(opts, :assignee_required_states, []) |> normalize_states()

    cond do
      not is_binary(project_id) or String.trim(project_id) == "" ->
        {:error, :missing_pitchai_pm_project_id}

      not is_list(scope_project_ids) ->
        {:error, :invalid_pitchai_pm_project_scope}

      normalized_states == [] ->
        {:ok, []}

      true ->
        sql =
          @task_select <>
            """
            where t.project_id::text = any($1::text[])
              and lower(trim(coalesce(t.state_name, ''))) = any($2::text[])
              and (
                $3::text is null
                or not (lower(trim(coalesce(t.state_name, ''))) = any($4::text[]))
                or tr.assignee = $3::text
              )
            """ <>
            @task_group <>
            """
            order by coalesce(tr.priority, 5), t.created_at nulls last, t.name
            limit $5
            """

        params = [scope_project_ids, normalized_states, assignee, assignee_required_states, limit]

        with {:ok, result} <- query(sql, params) do
          {:ok, Enum.map(result.rows, &row_to_issue(result.columns, &1))}
        end
    end
  end

  defp fetch_tasks_by_states(state_names, opts) do
    normalized_states = normalize_states(state_names)
    project_id = Keyword.fetch!(opts, :project_id)
    limit = Keyword.get(opts, :limit, @default_limit)
    assignee = opts |> Keyword.get(:assignee) |> clean_string()
    assignee_required_states = Keyword.get(opts, :assignee_required_states, []) |> normalize_states()

    cond do
      not is_binary(project_id) or String.trim(project_id) == "" ->
        {:error, :missing_pitchai_pm_project_id}

      normalized_states == [] ->
        {:ok, []}

      true ->
        sql =
          @task_select <>
            """
            where t.project_id = $1::text::uuid
              and lower(trim(coalesce(t.state_name, ''))) = any($2::text[])
              and (
                $4::text is null
                or not (lower(trim(coalesce(t.state_name, ''))) = any($5::text[]))
                or tr.assignee = $4::text
              )
            """ <>
            @task_group <>
            """
            order by coalesce(tr.priority, 5), t.created_at nulls last, t.name
            limit $3
            """

        with {:ok, result} <- query(sql, [project_id, normalized_states, limit, assignee, assignee_required_states]) do
          {:ok, Enum.map(result.rows, &row_to_issue(result.columns, &1))}
        end
    end
  end

  defp fetch_board_project(project_id) do
    sql = """
    select id::text, name, workspace_id::text
    from public.projects
    where id = $1::text::uuid
    """

    case query(sql, [project_id]) do
      {:ok, %{rows: [[id, name, workspace_id]]}} -> {:ok, %{id: id, name: name, workspace_id: workspace_id}}
      {:ok, %{rows: []}} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_board_scope_projects(%{id: project_id, workspace_id: workspace_id})
       when is_binary(project_id) and is_binary(workspace_id) do
    sql = """
    select p.id::text, p.name
    from public.projects p
    left join pitchai_dispatch.project_git_repos gr on gr.project_id = p.id
    where p.id = $1::text::uuid
       or (p.workspace_id = $2::text::uuid and gr.project_id is not null)
    group by p.id, p.name
    order by lower(regexp_replace(coalesce(p.name, ''), '^Repo: ', '')), p.id::text
    """

    with {:ok, result} <- query(sql, [project_id, workspace_id]) do
      {:ok, Enum.map(result.rows, fn [id, name] -> %{id: id, name: name} end)}
    end
  end

  defp fetch_board_scope_projects(%{id: project_id, name: name}) when is_binary(project_id),
    do: {:ok, [%{id: project_id, name: name}]}

  defp fetch_board_state_counts(project_id, scope_project_ids) when is_list(scope_project_ids) do
    sql = """
    select trim(state_name) as state_name, count(*)::integer as task_count
    from public.tasks t
    left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where #{board_visible_task_condition_sql()}
      and nullif(trim(coalesce(state_name, '')), '') is not null
    group by trim(state_name)
    """

    with {:ok, result} <- query(sql, [project_id, scope_project_ids]) do
      {:ok,
       result.rows
       |> Enum.map(fn [state_name, task_count] -> {state_name, task_count} end)
       |> Map.new()}
    end
  end

  defp board_visible_task_condition_sql do
    """
    (
        $1::text is not null
        and t.project_id::text = any($2::text[])
      )
    """
  end

  defp fetch_board_workflow_states(project_id) do
    sql = """
    select
      state_name,
      category,
      color,
      sort_order,
      is_active,
      is_terminal,
      is_visible_button,
      next_state_name,
      description,
      metadata::text
    from pitchai_symphony.workflow_states
    where project_id = $1::text::uuid
    order by sort_order, state_name
    """

    with {:ok, result} <- query(sql, [project_id]) do
      {:ok, Enum.map(result.rows, &workflow_state_row_to_board_state(result.columns, &1))}
    end
  end

  defp fetch_board_collapsed_groups(project_id) do
    sql = """
    select group_by, column_state_name, group_key
    from pitchai_symphony.board_group_collapse_preferences
    where board_project_id = $1::text::uuid
      and actor = 'global'
      and collapsed
    order by group_by, column_state_name, group_key
    """

    with {:ok, result} <- query(sql, [project_id]) do
      {:ok,
       Enum.map(result.rows, fn [group_by, column_state_name, group_key] ->
         %{group_by: group_by, column_state_name: column_state_name, group_key: group_key}
       end)}
    end
  end

  defp persist_board_group_collapsed(project_id, group_by, column_state_name, group_key) do
    sql = """
    insert into pitchai_symphony.board_group_collapse_preferences(
      board_project_id,
      actor,
      group_by,
      column_state_name,
      group_key,
      collapsed,
      metadata
    )
    values ($1::text::uuid, 'global', $2::text, $3::text, $4::text, true, $5::text::jsonb)
    on conflict (board_project_id, actor, group_by, column_state_name, group_key)
    do update set
      collapsed = true,
      metadata = excluded.metadata,
      updated_at = now()
    """

    metadata = Jason.encode!(%{"source" => "symphony_board_live"})

    case query(sql, [project_id, group_by, column_state_name, group_key, metadata]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_board_group_collapsed(project_id, group_by, column_state_name, group_key) do
    sql = """
    delete from pitchai_symphony.board_group_collapse_preferences
    where board_project_id = $1::text::uuid
      and actor = 'global'
      and group_by = $2::text
      and column_state_name = $3::text
      and group_key = $4::text
    """

    case query(sql, [project_id, group_by, column_state_name, group_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_board_tasks(project_id, scope_project_ids) when is_list(scope_project_ids) do
    sql = """
    select
      id,
      identifier,
      title,
      state,
      value_name,
      project_id,
      project_name,
      assignee,
      priority,
      labels,
      branch_name,
      url,
      rank,
      created_at,
      updated_at,
      comment_count,
      blocked_reason,
      pr_count,
      workpad_updated_at,
      downstream_count
    from (
      select
        t.id::text as id,
        coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
        t.name as title,
        trim(t.state_name) as state,
        t.value_name,
        t.project_id::text as project_id,
        p.name as project_name,
        tr.assignee,
        coalesce(tr.priority, 5) as priority,
        coalesce(tr.labels, array[]::text[]) as labels,
        tr.branch_name,
        coalesce(tr.url, '') as url,
        t.rank as rank,
        t.created_at,
        t.updated_at,
        coalesce((select count(*)::integer from pitchai_symphony.task_comments c where c.task_id = t.id), 0) as comment_count,
        (
          select c.body
          from pitchai_symphony.task_comments c
          where c.task_id = t.id
            and lower(trim(coalesce(t.state_name, ''))) = 'blocked'
            and lower(trim(coalesce(c.body, ''))) like any(array['blocked%', 'true blocker%'])
          order by c.created_at desc, c.id desc
          limit 1
        ) as blocked_reason,
        coalesce((select count(*)::integer from pitchai_symphony.task_pr_links pr where pr.task_id = t.id), 0) as pr_count,
        (select max(w.updated_at) from pitchai_symphony.task_workpads w where w.task_id = t.id) as workpad_updated_at,
        coalesce(
          (
            with recursive downstream(dependent_id) as (
              select dep.task_id
              from pitchai_symphony.task_dependencies dep
              where dep.blocker_task_id = t.id
                and dep.relation_type = 'blocked_by'
              union
              select dep.task_id
              from downstream d
              join pitchai_symphony.task_dependencies dep
                on dep.blocker_task_id = d.dependent_id
               and dep.relation_type = 'blocked_by'
            )
            select count(distinct d.dependent_id)::integer
            from downstream d
            join public.tasks dependent on dependent.id = d.dependent_id
            where d.dependent_id <> t.id
              and not (lower(trim(coalesce(dependent.state_name, ''))) = any($4::text[]))
          ),
          0
        ) as downstream_count,
        row_number() over (
          partition by lower(trim(coalesce(t.state_name, '')))
          order by t.rank asc nulls last, coalesce(tr.priority, 5), t.updated_at desc nulls last, t.created_at desc nulls last, t.name
        ) as board_rank
      from public.tasks t
      left join public.projects p on p.id = t.project_id
      left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
      where #{board_visible_task_condition_sql()}
        and nullif(trim(coalesce(t.state_name, '')), '') is not null
    ) ranked
    where board_rank <= $3
    order by lower(state), board_rank
    """

    params = [project_id, scope_project_ids, @board_task_limit_per_state, terminal_state_keys()]

    with {:ok, result} <- query(sql, params) do
      {:ok, Enum.map(result.rows, &board_task_row_to_map(result.columns, &1))}
    end
  end

  defp tool_get_task(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, [issue]} <- fetch_issue_states_by_ids([task_id]) do
      {:ok, %{"task" => issue_to_map(issue)}}
    else
      {:ok, []} -> {:error, :task_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_list_tasks(params) do
    states = Map.get(params, "states") || Map.get(params, :states) || Config.settings!().tracker.active_states
    project_id = string_param(params, "project_id") || Config.settings!().tracker.project_id
    limit = integer_param(params, "limit") || poll_limit(Config.settings!().tracker)

    with {:ok, issues} <- fetch_tasks_by_states(states, project_id: project_id, limit: min(max(limit, 1), 500)) do
      {:ok, %{"tasks" => Enum.map(issues, &issue_to_map/1)}}
    end
  end

  defp tool_list_workflow_states(params) do
    project_id = string_param(params, "project_id") || Config.settings!().tracker.project_id

    sql = """
    select
      state_name,
      category,
      color,
      sort_order,
      is_active,
      is_terminal,
      is_visible_button,
      next_state_name,
      description,
      metadata::text
    from pitchai_symphony.workflow_states
    where project_id = $1::text::uuid
    order by sort_order, state_name
    """

    with {:ok, result} <- query(sql, [project_id]) do
      {:ok, %{"states" => Enum.map(result.rows, &workflow_state_row_to_map(result.columns, &1))}}
    end
  end

  defp tool_list_blocked_tasks(params) do
    project_id = string_param(params, "project_id") || Config.settings!().tracker.project_id

    with {:ok, project} <- fetch_board_project(project_id),
         {:ok, projects} <- fetch_board_scope_projects(project),
         {:ok, blocked_tasks} <- fetch_blocked_tasks(Enum.map(projects, & &1.id)) do
      groups = BlockerReconciler.group_blocked_tasks(blocked_tasks)

      {:ok,
       %{
         "blocked_tasks" =>
           blocked_tasks
           |> Enum.map(&BlockerReconciler.enrich_blocked_task/1)
           |> Enum.map(&blocked_task_tool_map/1),
         "groups" => Enum.map(groups, &blocker_reconciliation_agent_group/1)
       }}
    end
  end

  defp tool_list_blocker_tasks(params) do
    project_id = string_param(params, "project_id") || Config.settings!().tracker.project_id

    with {:ok, project} <- fetch_board_project(project_id),
         {:ok, projects} <- fetch_board_scope_projects(project),
         {:ok, blocker_tasks} <- fetch_blocker_tasks(Enum.map(projects, & &1.id)) do
      {:ok, %{"blocker_tasks" => blocker_tasks}}
    end
  end

  defp tool_update_task_state(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, state_name} <- required_string(params, "state_name"),
         :ok <- validate_tool_state_transition(task_id, state_name),
         :ok <- update_issue_state(task_id, state_name, string_param(params, "reason") || "tool_update_task_state"),
         {:ok, [issue]} <- fetch_issue_states_by_ids([task_id]) do
      {:ok, %{"task" => issue_to_map(issue)}}
    else
      {:ok, []} -> {:error, :task_not_found_after_update}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tool_state_transition(task_id, state_name) when is_binary(task_id) and is_binary(state_name) do
    target_state = normalize_state_key(state_name)

    if target_state in terminal_state_keys() do
      :ok
    else
      validate_non_terminal_tool_state_transition(task_id)
    end
  end

  defp validate_non_terminal_tool_state_transition(task_id) do
    sql = """
    select
      t.state_name,
      coalesce(
        tr.metadata->>'symphony_kind',
        case when jsonb_typeof(tr.metadata) = 'string' then ((tr.metadata #>> '{}')::jsonb)->>'symphony_kind' end
      ) as symphony_kind
    from public.tasks t
    left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where t.id = $1::text::uuid
    """

    case query(sql, [task_id]) do
      {:ok, %{rows: rows}} -> validate_non_terminal_tool_state_rows(rows)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_non_terminal_tool_state_rows([[current_state, "blocker_task"]]) do
    case normalize_state_key(current_state) in terminal_state_keys() do
      true -> {:error, :cannot_reopen_terminal_blocker_task}
      false -> :ok
    end
  end

  defp validate_non_terminal_tool_state_rows([[_current_state, _symphony_kind]]), do: :ok
  defp validate_non_terminal_tool_state_rows([]), do: {:error, :task_not_found}

  defp tool_append_changelog(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, summary} <- required_string(params, "summary") do
      sql = """
      update public.tasks
      set description = jsonb_set(
            coalesce(description, '{}'::jsonb),
            '{changelog}',
            coalesce(description->'changelog', '[]'::jsonb)
              || jsonb_build_array(jsonb_build_object(
                'ts_utc', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                'summary', $2::text,
                'source', 'pitchai_symphony'
              )),
            true
          ),
          updated_at = now()
      where id = $1::text::uuid
      """

      case query(sql, [task_id, summary]) do
        {:ok, %{num_rows: 1}} -> {:ok, %{"ok" => true}}
        {:ok, %{num_rows: 0}} -> {:error, :task_not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp tool_get_workpad(params) do
    with {:ok, task_id} <- required_string(params, "task_id") do
      sql = """
      select body, updated_at
      from pitchai_symphony.task_workpads
      where task_id = $1::text::uuid
      """

      case query(sql, [task_id]) do
        {:ok, %{rows: [[body, updated_at]]}} ->
          {:ok, %{"task_id" => task_id, "body" => body, "updated_at" => encode_datetime(updated_at)}}

        {:ok, %{rows: []}} ->
          {:ok, %{"task_id" => task_id, "body" => nil, "updated_at" => nil}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp tool_upsert_workpad(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, body} <- required_string(params, "body") do
      sql = """
      insert into pitchai_symphony.task_workpads(task_id, body)
      values ($1::text::uuid, $2::text)
      on conflict (task_id)
      do update set body = excluded.body, updated_at = now()
      returning body, updated_at
      """

      case query(sql, [task_id, body]) do
        {:ok, %{rows: [[saved_body, updated_at]]}} ->
          {:ok, %{"task_id" => task_id, "body" => saved_body, "updated_at" => encode_datetime(updated_at)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp tool_add_comment(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, body} <- required_string(params, "body") do
      kind = string_param(params, "kind") || "comment"

      sql = """
      insert into pitchai_symphony.task_comments(task_id, body, author, kind)
      values ($1::text::uuid, $2::text, 'symphony', $3::text)
      returning id, created_at
      """

      case query(sql, [task_id, body, kind]) do
        {:ok, %{rows: [[id, created_at]]}} ->
          {:ok, %{"id" => id, "task_id" => task_id, "created_at" => encode_datetime(created_at)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp tool_attach_pr(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, url} <- required_string(params, "url") do
      repo_full_name = string_param(params, "repo_full_name")
      branch_name = string_param(params, "branch_name")
      state = string_param(params, "state") || "open"
      metadata = map_param(params, "metadata") || %{}

      sql = """
      insert into pitchai_symphony.task_pr_links(task_id, url, repo_full_name, branch_name, state, metadata)
      values ($1::text::uuid, $2::text, $3::text, $4::text, $5::text, $6::text::jsonb)
      on conflict (task_id, url)
      do update set
        repo_full_name = excluded.repo_full_name,
        branch_name = excluded.branch_name,
        state = excluded.state,
        metadata = excluded.metadata,
        updated_at = now()
      returning id
      """

      case query(sql, [task_id, url, repo_full_name, branch_name, state, Jason.encode!(metadata)]) do
        {:ok, %{rows: [[id]]}} -> {:ok, %{"id" => id, "task_id" => task_id, "url" => url}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp tool_create_task(params) do
    with {:ok, task_id} <- insert_task(params, "Backlog") do
      tool_get_task(%{"task_id" => task_id})
    end
  end

  defp tool_link_task_dependency(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, blocker_task_id} <- required_string(params, "blocker_task_id"),
         :ok <- validate_distinct_tasks(task_id, blocker_task_id) do
      relation_type = string_param(params, "relation_type") || "blocked_by"
      metadata = map_param(params, "metadata") || %{}

      sql = """
      insert into pitchai_symphony.task_dependencies(task_id, blocker_task_id, relation_type, metadata)
      values ($1::text::uuid, $2::text::uuid, $3::text, $4::text::jsonb)
      on conflict (task_id, blocker_task_id, relation_type)
      do update set metadata = pitchai_symphony.task_dependencies.metadata || excluded.metadata
      returning task_id::text, blocker_task_id::text, relation_type
      """

      dependency_metadata =
        Map.merge(metadata, %{
          "source" => @blocker_reconciler_source,
          "linked_by" => @blocker_reconciliation_agent_kind
        })

      case query(sql, [task_id, blocker_task_id, relation_type, Jason.encode!(dependency_metadata)]) do
        {:ok, %{rows: [[linked_task_id, linked_blocker_task_id, linked_relation_type]]}} ->
          {:ok,
           %{
             "task_id" => linked_task_id,
             "blocker_task_id" => linked_blocker_task_id,
             "relation_type" => linked_relation_type
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp tool_merge_duplicate_blocker_task(params) do
    with {:ok, canonical_task_id} <- required_string(params, "canonical_task_id"),
         {:ok, duplicate_task_id} <- required_string(params, "duplicate_task_id"),
         :ok <- validate_distinct_tasks(canonical_task_id, duplicate_task_id),
         :ok <- merge_duplicate_blocker_task(%{id: canonical_task_id}, %{id: duplicate_task_id}) do
      {:ok, %{"canonical_task_id" => canonical_task_id, "duplicate_task_id" => duplicate_task_id}}
    end
  end

  defp insert_task(params, default_state_name) when is_binary(default_state_name) do
    with {:ok, insert_params} <- task_insert_params(params, default_state_name),
         {:ok, task_id} <- insert_public_task(insert_params),
         :ok <- maybe_upsert_task_tracking(task_id, params) do
      {:ok, task_id}
    end
  end

  defp task_insert_params(params, default_state_name) do
    with {:ok, project_id} <- required_string(params, "project_id"),
         {:ok, name} <- required_string(params, "name") do
      {:ok,
       %{
         description: map_param(params, "description") || %{},
         name: name,
         project_id: project_id,
         state_name: string_param(params, "state_name") || default_state_name,
         value_name: string_param(params, "value_name") || "Task"
       }}
    end
  end

  defp insert_public_task(params) when is_map(params) do
    sql = """
    insert into public.tasks(id, created_at, updated_at, name, description, project_id, state_name, value_name, is_bug)
    values (gen_random_uuid(), now(), now(), $1::text, $2::text::jsonb, $3::text::uuid, $4::text, $5::text, false)
    returning id::text
    """

    case query(sql, [
           params.name,
           Jason.encode!(params.description),
           params.project_id,
           params.state_name,
           params.value_name
         ]) do
      {:ok, %{rows: [[task_id]]}} -> {:ok, task_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_distinct_tasks(task_id, task_id), do: {:error, :duplicate_task_matches_canonical_task}
  defp validate_distinct_tasks(_canonical_task_id, _duplicate_task_id), do: :ok

  defp maybe_upsert_task_tracking(task_id, params) do
    priority = integer_param(params, "priority")
    assignee = string_param(params, "assignee")
    labels = string_list_param(params, "labels")
    metadata = map_param(params, "metadata") || %{}

    if is_nil(priority) and is_nil(assignee) and labels == [] and metadata == %{} do
      :ok
    else
      upsert_task_tracking(task_id, priority, assignee, labels, metadata)
    end
  end

  defp upsert_task_tracking(task_id, priority, assignee, labels, metadata) do
    sql = """
    insert into pitchai_symphony.task_tracking(task_id, priority, assignee, labels, metadata)
    values ($1::text::uuid, $2::integer, $3::text, $4::text[], $5::text::jsonb)
    on conflict (task_id)
    do update set
      priority = coalesce(excluded.priority, pitchai_symphony.task_tracking.priority),
      assignee = coalesce(excluded.assignee, pitchai_symphony.task_tracking.assignee),
      labels = (
        select array_agg(distinct label order by label)
        from unnest(coalesce(pitchai_symphony.task_tracking.labels, array[]::text[]) || excluded.labels) label
      ),
      metadata = pitchai_symphony.task_tracking.metadata || excluded.metadata,
      updated_at = now()
    """

    case query(sql, [task_id, priority, assignee, labels, Jason.encode!(metadata)]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp query(sql, params) when is_binary(sql) and is_list(params) do
    with {:ok, conn} <- Postgrex.start_link(database_opts()) do
      try do
        Postgrex.query(conn, sql, params, timeout: @query_timeout)
      after
        if Process.alive?(conn), do: GenServer.stop(conn)
      end
    end
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp database_opts do
    settings = Config.settings!().tracker
    url = clean_string(settings.database_url) || clean_string(System.get_env("PITCHAI_PM_DATABASE_URL"))

    if is_nil(url) do
      raise ArgumentError, "missing PitchAI PM database URL"
    end

    url
    |> database_opts_from_url()
    |> Keyword.merge(connect_timeout: @connect_timeout)
  end

  defp database_opts_from_url(url) do
    uri = URI.parse(url)
    database = database_from_path(uri.path)
    {username, password} = credentials_from_userinfo(uri.userinfo)

    cond do
      uri.scheme not in ["postgres", "postgresql"] ->
        raise ArgumentError, "PitchAI PM database URL must use postgres:// or postgresql://"

      clean_string(uri.host) == nil ->
        raise ArgumentError, "PitchAI PM database URL is missing a host"

      database == nil ->
        raise ArgumentError, "PitchAI PM database URL is missing a database name"

      username == nil ->
        raise ArgumentError, "PitchAI PM database URL is missing a username"

      password == nil ->
        raise ArgumentError, "PitchAI PM database URL is missing a password"

      true ->
        [
          hostname: uri.host,
          port: uri.port || 5432,
          username: username,
          password: password,
          database: database
        ]
    end
  end

  defp database_from_path(nil), do: nil

  defp database_from_path(path) do
    path
    |> String.trim_leading("/")
    |> URI.decode()
    |> clean_string()
  end

  defp credentials_from_userinfo(nil), do: {nil, nil}

  defp credentials_from_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> {decode_userinfo(username), decode_userinfo(password)}
      [username] -> {decode_userinfo(username), nil}
    end
  end

  defp decode_userinfo(value) do
    value
    |> URI.decode()
    |> clean_string()
  end

  defp row_to_issue(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %Issue{
      id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      description: data["description"],
      priority: data["priority"],
      state: data["state"],
      branch_name: clean_string(data["branch_name"]),
      url: issue_url(data["id"], data["url"]),
      assignee_id: clean_string(data["assignee_id"]),
      blocked_by: decode_blockers(data["blocked_by_json"]),
      labels: labels(data["labels"]),
      assigned_to_worker: assigned_to_worker?(data["assignee_id"], data["state"]),
      created_at: data["created_at"],
      updated_at: data["updated_at"]
    }
  end

  defp issue_to_map(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => issue.state,
      "branch_name" => issue.branch_name,
      "url" => issue.url,
      "assignee_id" => issue.assignee_id,
      "labels" => issue.labels,
      "blocked_by" => issue.blocked_by,
      "created_at" => encode_datetime(issue.created_at),
      "updated_at" => encode_datetime(issue.updated_at)
    }
  end

  defp workflow_state_row_to_map(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      "state_name" => data["state_name"],
      "category" => data["category"],
      "color" => data["color"],
      "sort_order" => data["sort_order"],
      "is_active" => data["is_active"],
      "is_terminal" => data["is_terminal"],
      "is_visible_button" => data["is_visible_button"],
      "next_state_name" => data["next_state_name"],
      "description" => data["description"],
      "metadata" => decode_json_object(data["metadata"])
    }
  end

  defp workflow_state_row_to_board_state(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      state_name: data["state_name"],
      category: data["category"],
      color: data["color"],
      sort_order: data["sort_order"],
      is_active: data["is_active"],
      is_terminal: data["is_terminal"],
      is_visible_button: data["is_visible_button"],
      next_state_name: clean_string(data["next_state_name"]),
      description: clean_string(data["description"]),
      metadata: decode_json_object(data["metadata"])
    }
  end

  defp issue_url(task_id, tracking_url) do
    clean_string(tracking_url) || task_modal_url(task_id)
  end

  defp task_modal_url(task_id) do
    with task_id when is_binary(task_id) <- clean_string(task_id),
         board_url when is_binary(board_url) <- Config.public_board_url() do
      "#{String.trim_trailing(board_url, "/")}/?task_id=#{URI.encode_www_form(task_id)}"
    else
      _missing -> nil
    end
  end

  defp board_task_row_to_map(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      state: data["state"],
      value_name: clean_string(data["value_name"]) || "Task",
      project_id: clean_string(data["project_id"]),
      project_name: clean_string(data["project_name"]),
      assignee: clean_string(data["assignee"]),
      priority: data["priority"],
      rank: data["rank"],
      labels: labels(data["labels"]),
      branch_name: clean_string(data["branch_name"]),
      url: clean_string(data["url"]),
      created_at: encode_datetime(data["created_at"]),
      updated_at: encode_datetime(data["updated_at"]),
      comment_count: data["comment_count"] || 0,
      blocked_reason: clean_string(data["blocked_reason"]),
      pr_count: data["pr_count"] || 0,
      workpad_updated_at: encode_datetime(data["workpad_updated_at"]),
      downstream_count: data["downstream_count"] || 0
    }
  end

  defp task_detail_row_to_map(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      description: decode_json_object(data["description_json"]),
      state: data["state"],
      value_name: clean_string(data["value_name"]) || "Task",
      rank: data["rank"],
      priority: data["priority"],
      labels: labels(data["labels"]),
      branch_name: clean_string(data["branch_name"]),
      url: clean_string(data["url"]),
      assignee: clean_string(data["assignee"]),
      repo_full_name: clean_string(data["repo_full_name"]),
      repo_url: clean_string(data["repo_url"]),
      workspace_path: clean_string(data["workspace_path"]),
      tracking_metadata: decode_json_object(data["tracking_metadata_json"]),
      blocked_reason: clean_string(data["blocked_reason"]),
      project: %{
        id: data["project_id"],
        name: data["project_name"]
      },
      workpad: %{
        body: clean_string(data["workpad_body"]),
        updated_at: encode_datetime(data["workpad_updated_at"])
      },
      comments: decode_json_array(data["comments_json"]),
      prs: decode_json_array(data["prs_json"]),
      state_events: decode_json_array(data["state_events_json"]),
      blockers: decode_json_array(data["blockers_json"]),
      created_at: encode_datetime(data["created_at"]),
      updated_at: encode_datetime(data["updated_at"])
    }
  end

  defp build_board_columns(workflow_states, state_counts, tasks) do
    states =
      @board_default_states
      |> Enum.reduce(%{}, fn state, acc -> Map.put(acc, normalize_state_key(state.state_name), state) end)
      |> merge_workflow_states(workflow_states)
      |> merge_task_states(Map.keys(state_counts))

    tasks_by_state = Enum.group_by(tasks, &normalize_state_key(&1.state))
    terminal_states = Config.settings!().tracker.terminal_states |> normalize_states() |> MapSet.new()

    states
    |> Map.values()
    |> Enum.map(fn state ->
      state_name = state.state_name
      task_count = Map.get(state_counts, state_name, 0)
      task_cards = Map.get(tasks_by_state, normalize_state_key(state_name), [])

      state
      |> Map.put(:task_count, task_count)
      |> Map.put(:tasks, task_cards)
      |> Map.put(:hidden?, hidden_board_state?(state, terminal_states))
    end)
    |> Enum.sort_by(fn state -> {state.sort_order || 500, String.downcase(state.state_name)} end)
  end

  defp merge_workflow_states(states, workflow_states) do
    Enum.reduce(workflow_states, states, fn workflow_state, acc ->
      key = normalize_state_key(workflow_state.state_name)

      Map.update(acc, key, workflow_state, &merge_workflow_state(&1, workflow_state))
    end)
  end

  defp merge_workflow_state(default_state, workflow_state) do
    default_state
    |> Map.merge(workflow_state, &prefer_workflow_value/3)
    |> Map.put(:sort_order, default_state.sort_order)
    |> Map.put(:is_visible_button, default_state.is_visible_button)
    |> Map.put(:category, default_state.category)
  end

  defp prefer_workflow_value(_key, default_value, nil), do: default_value
  defp prefer_workflow_value(_key, _default_value, workflow_value), do: workflow_value

  defp merge_task_states(states, state_names) do
    Enum.reduce(state_names, states, fn state_name, acc ->
      key = normalize_state_key(state_name)

      Map.put_new(acc, key, %{
        state_name: state_name,
        category: "project",
        color: "#64748b",
        sort_order: inferred_state_sort_order(state_name),
        is_active: false,
        is_terminal: false,
        is_visible_button: true,
        next_state_name: nil,
        description: nil,
        metadata: %{}
      })
    end)
  end

  defp fetch_board_task_context(task_id) do
    sql = """
    select id::text, project_id::text
    from public.tasks
    where id = $1::text::uuid
    """

    case query(sql, [task_id]) do
      {:ok, %{rows: [[id, project_id]]}} when is_binary(project_id) ->
        {:ok, %{id: id, project_id: project_id}}

      {:ok, %{rows: [[_id, nil]]}} ->
        {:error, :task_has_no_project}

      {:ok, %{rows: []}} ->
        {:error, :task_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_ordered_board_task_ids(target_state, moved_task_id) do
    sql = """
    select t.id::text
    from public.tasks t
    left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where #{board_visible_task_condition_sql()}
      and lower(trim(coalesce(t.state_name, ''))) = lower(trim($3::text))
      and t.id <> $4::text::uuid
    order by t.rank asc nulls last,
      coalesce(tr.priority, 5),
      t.updated_at desc nulls last,
      t.created_at desc nulls last,
      t.name
    """

    settings = Config.settings!().tracker

    with {:ok, project} <- fetch_board_project(settings.project_id),
         {:ok, projects} <- fetch_board_scope_projects(project),
         {:ok, result} <-
           query(sql, [
             settings.project_id,
             Enum.map(projects, & &1.id),
             target_state,
             moved_task_id
           ]) do
      {:ok, Enum.map(result.rows, fn [id] -> id end)}
    end
  end

  defp insert_board_task_id(existing_ids, task_id, before_task_id, after_task_id) do
    ids = Enum.reject(existing_ids, &(&1 == task_id))

    cond do
      is_binary(before_task_id) ->
        insert_before_board_task_id(ids, task_id, before_task_id)

      is_binary(after_task_id) ->
        insert_after_board_task_id(ids, task_id, after_task_id)

      true ->
        {:ok, ids ++ [task_id]}
    end
  end

  defp insert_before_board_task_id(ids, task_id, before_task_id) do
    case Enum.split_while(ids, &(&1 != before_task_id)) do
      {_, []} -> {:error, {:board_neighbor_not_found, before_task_id}}
      {before_ids, [neighbor | after_ids]} -> {:ok, before_ids ++ [task_id, neighbor | after_ids]}
    end
  end

  defp insert_after_board_task_id(ids, task_id, after_task_id) do
    case Enum.split_while(ids, &(&1 != after_task_id)) do
      {_, []} -> {:error, {:board_neighbor_not_found, after_task_id}}
      {before_ids, [neighbor | after_ids]} -> {:ok, before_ids ++ [neighbor, task_id | after_ids]}
    end
  end

  defp persist_board_task_ranks(task_ids) when is_list(task_ids) do
    ranks =
      task_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {_task_id, index} -> index * 1024.0 end)

    sql = """
    update public.tasks t
    set rank = ranked.rank
    from unnest($1::text[], $2::float8[]) as ranked(id, rank)
    where t.id = ranked.id::uuid
    """

    case query(sql, [task_ids, ranks]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp hidden_board_state?(state, terminal_states) do
    category =
      case clean_string(state.category) do
        nil -> "project"
        value -> String.downcase(value)
      end

    normalize_state_key(state.state_name) in terminal_states or
      state.is_terminal == true or
      state.is_visible_button == false or
      category in ["merge", "rework", "terminal"]
  end

  defp inferred_state_sort_order(state_name) do
    Map.get(@state_sort_orders, normalize_state_key(state_name), 500)
  end

  defp decode_blockers(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, blockers} when is_list(blockers) -> blockers
      _ -> []
    end
  end

  defp decode_blockers(_), do: []

  defp decode_json_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json_object(_), do: %{}

  defp decode_json_array(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end

  defp decode_json_array(_), do: []

  defp labels(labels) when is_list(labels), do: Enum.map(labels, &to_string/1)
  defp labels(_), do: []

  defp assigned_to_worker?(assignee, state_name) do
    case {clean_string(Config.settings!().tracker.assignee), normalize_state_key(state_name)} do
      {nil, _state} -> true
      {_wanted, state} when state in ["todo", "symphony ready", "merging", "rework"] -> true
      {wanted, _state} -> clean_string(assignee) == wanted
    end
  end

  defp managed_state_keys do
    ["todo", "symphony ready", "in progress", "human review", "blocked", "merging", "rework"]
  end

  defp terminal_state_keys do
    Config.settings!().tracker.terminal_states
    |> normalize_states()
  end

  defp poll_limit(settings) do
    case settings.poll_limit do
      limit when is_integer(limit) and limit > 0 -> min(limit, 1_000)
      _ -> @default_limit
    end
  end

  defp normalize_states(states) when is_list(states) do
    states
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp normalize_states(_), do: []

  defp normalize_state_key(state_name) do
    state_name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp required_string(params, key) do
    case string_param(params, key) do
      nil -> {:error, {:missing_param, key}}
      value -> {:ok, value}
    end
  end

  defp string_param(params, key) do
    Map.get(params, key)
    |> case do
      nil -> Map.get(params, String.to_atom(key))
      value -> value
    end
    |> clean_string()
  end

  defp integer_param(params, key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _ -> nil
    end
  end

  defp map_param(params, key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp string_list_param(params, key) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      values when is_list(values) ->
        values
        |> Enum.map(&clean_string/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&clean_string/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp parse_integer(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_string(nil), do: nil
  defp clean_string(value), do: value |> to_string() |> clean_string()

  defp truncate_string(value, limit) when is_binary(value) and byte_size(value) <= limit, do: value

  defp truncate_string(value, limit) when is_binary(value) do
    value
    |> binary_part(0, limit)
    |> String.replace(~r/\s+\S*$/, "")
    |> Kernel.<>("...")
  end

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_datetime(nil), do: nil
  defp encode_datetime(value), do: to_string(value)
end
