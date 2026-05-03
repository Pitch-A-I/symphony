defmodule SymphonyElixir.PitchAIPM.Client do
  @moduledoc """
  SQL client for PitchAI project-management task orchestration.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @default_limit 100
  @board_task_limit_per_state 12
  @connect_timeout 5_000
  @query_timeout 15_000

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

    fetch_tasks_by_states(settings.active_states,
      project_id: settings.project_id,
      limit: poll_limit(settings),
      assignee: settings.assignee,
      assignee_required_states: ["In Progress"]
    )
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
           {:ok, tasks} <- fetch_board_tasks(project_id, scope_project_ids) do
        columns = build_board_columns(workflow_states, state_counts, tasks)

        {:ok,
         %{
           project: project,
           scope: %{kind: "configured_project_plus_workspace_suggested", project_ids: scope_project_ids},
           project_options: projects,
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
          from pitchai_symphony.task_comments c
          where c.task_id = t.id
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
          from pitchai_symphony.task_pr_links pr
          where pr.task_id = t.id
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
          from pitchai_symphony.task_state_events e
          where e.task_id = t.id
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

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(task_id, state_name), do: update_issue_state(task_id, state_name, "tracker_update")

  @spec move_issue_on_board(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def move_issue_on_board(task_id, state_name, opts)
      when is_binary(task_id) and is_binary(state_name) and is_map(opts) do
    with clean_state when not is_nil(clean_state) <- clean_string(state_name),
         {:ok, task_context} <- fetch_board_task_context(task_id),
         {:ok, current_target_ids} <-
           fetch_ordered_board_task_ids(task_context.project_id, clean_state, task_id),
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
          and lower(coalesce(to_state, '')) = any(array['in progress', 'merging', 'rework'])
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

      case query(sql, [task_id, clean_state, String.trim(reason), clean_string(Config.settings!().tracker.assignee)]) do
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
      "update_task_state" => &tool_update_task_state/1,
      "append_changelog" => &tool_append_changelog/1,
      "get_workpad" => &tool_get_workpad/1,
      "upsert_workpad" => &tool_upsert_workpad/1,
      "add_comment" => &tool_add_comment/1,
      "attach_pr" => &tool_attach_pr/1,
      "create_task" => &tool_create_task/1
    }

    normalized_operation = String.trim(operation)

    case Map.fetch(operation_handlers, normalized_operation) do
      {:ok, handler} -> handler.(params)
      :error -> {:error, {:unsupported_pitchai_pm_operation, normalized_operation}}
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
    from public.tasks
    where (
        project_id = $1::text::uuid
        or (
          project_id::text = any($2::text[])
          and lower(trim(coalesce(state_name, ''))) = 'suggested'
        )
      )
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

  defp fetch_board_tasks(project_id, scope_project_ids) when is_list(scope_project_ids) do
    sql = """
    select
      id,
      identifier,
      title,
      state,
      value_name,
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
      pr_count,
      workpad_updated_at
    from (
      select
        t.id::text as id,
        coalesce(nullif(trim(t.public_id), ''), 'PM-' || substring(t.id::text, 1, 8)) as identifier,
        t.name as title,
        trim(t.state_name) as state,
        t.value_name,
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
        coalesce((select count(*)::integer from pitchai_symphony.task_pr_links pr where pr.task_id = t.id), 0) as pr_count,
        (select max(w.updated_at) from pitchai_symphony.task_workpads w where w.task_id = t.id) as workpad_updated_at,
        row_number() over (
          partition by lower(trim(coalesce(t.state_name, '')))
          order by t.rank asc nulls last, coalesce(tr.priority, 5), t.updated_at desc nulls last, t.created_at desc nulls last, t.name
        ) as board_rank
      from public.tasks t
      left join public.projects p on p.id = t.project_id
      left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
      where (
          t.project_id = $1::text::uuid
          or (
            t.project_id::text = any($2::text[])
            and lower(trim(coalesce(t.state_name, ''))) = 'suggested'
          )
        )
        and nullif(trim(coalesce(t.state_name, '')), '') is not null
    ) ranked
    where board_rank <= $3
    order by lower(state), board_rank
    """

    with {:ok, result} <- query(sql, [project_id, scope_project_ids, @board_task_limit_per_state]) do
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

  defp tool_update_task_state(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, state_name} <- required_string(params, "state_name"),
         :ok <- update_issue_state(task_id, state_name, string_param(params, "reason") || "tool_update_task_state"),
         {:ok, [issue]} <- fetch_issue_states_by_ids([task_id]) do
      {:ok, %{"task" => issue_to_map(issue)}}
    else
      {:ok, []} -> {:error, :task_not_found_after_update}
      {:error, reason} -> {:error, reason}
    end
  end

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
      values ($1::text::uuid, $2::text, $3::text, $4::text, $5::text, $6::jsonb)
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

  defp insert_task(params, default_state_name) when is_binary(default_state_name) do
    with {:ok, project_id} <- required_string(params, "project_id"),
         {:ok, name} <- required_string(params, "name") do
      description = map_param(params, "description") || %{}
      state_name = string_param(params, "state_name") || default_state_name
      value_name = string_param(params, "value_name") || "Task"

      sql = """
      insert into public.tasks(id, created_at, updated_at, name, description, project_id, state_name, value_name, is_bug)
      values (gen_random_uuid(), now(), now(), $1::text, $2::jsonb, $3::text::uuid, $4::text, $5::text, false)
      returning id::text
      """

      case query(sql, [name, Jason.encode!(description), project_id, state_name, value_name]) do
        {:ok, %{rows: [[task_id]]}} -> {:ok, task_id}
        {:error, reason} -> {:error, reason}
      end
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
      url: clean_string(data["url"]),
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

  defp board_task_row_to_map(columns, row) do
    data = columns |> Enum.zip(row) |> Map.new()

    %{
      id: data["id"],
      identifier: data["identifier"],
      title: data["title"],
      state: data["state"],
      value_name: clean_string(data["value_name"]) || "Task",
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
      pr_count: data["pr_count"] || 0,
      workpad_updated_at: encode_datetime(data["workpad_updated_at"])
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

  defp fetch_ordered_board_task_ids(project_id, target_state, moved_task_id) do
    sql = """
    select t.id::text
    from public.tasks t
    left join pitchai_symphony.task_tracking tr on tr.task_id = t.id
    where t.project_id = $1::text::uuid
      and lower(trim(coalesce(t.state_name, ''))) = lower(trim($2::text))
      and t.id <> $3::text::uuid
    order by t.rank asc nulls last,
      coalesce(tr.priority, 5),
      t.updated_at desc nulls last,
      t.created_at desc nulls last,
      t.name
    """

    with {:ok, result} <- query(sql, [project_id, target_state, moved_task_id]) do
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

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_datetime(nil), do: nil
  defp encode_datetime(value), do: to_string(value)
end
