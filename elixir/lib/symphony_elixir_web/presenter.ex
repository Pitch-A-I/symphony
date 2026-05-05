defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, PitchAIPM, StatusDashboard}

  @workpad_section_titles ["Plan", "Acceptance Criteria", "Validation", "Notes", "Blockers"]
  @checkbox_line ~r/^(\s*)-\s+\[(x|X| )\]\s+(.+)$/
  @heading_line ~r/^###\s+(.+?)\s*$/
  @description_primary_paths [
    ["request"],
    ["summary"],
    ["description"],
    ["description_text"],
    ["text"],
    ["content"],
    ["goal"],
    ["pitchai_dispatch", "task_enrichment", "payload", "summary"]
  ]
  @description_labeled_paths [
    {"Context", ["context"]},
    {"Background", ["background"]},
    {"Background", ["pitchai_dispatch", "task_enrichment", "payload", "background"]},
    {"Scope", ["scope"]},
    {"Scope", ["pitchai_dispatch", "task_enrichment", "payload", "scope"]},
    {"Expected", ["expected_behavior"]},
    {"Expected", ["expected_teacher_mental_model"]},
    {"Actual", ["actual_behavior"]},
    {"Impact", ["teacher_impact"]},
    {"Steps", ["reproduction_steps"]},
    {"Acceptance", ["acceptance"]},
    {"Acceptance", ["acceptance_criteria"]},
    {"Acceptance", ["pitchai_dispatch", "task_enrichment", "payload", "acceptance_criteria"]},
    {"Validation", ["validation"]},
    {"Notes", ["notes"]}
  ]

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    snapshot_payload(orchestrator, snapshot_timeout_ms, false)
  end

  @spec dashboard_payload(GenServer.name(), timeout()) :: map()
  def dashboard_payload(orchestrator, snapshot_timeout_ms) do
    snapshot_payload(orchestrator, snapshot_timeout_ms, true)
  end

  @spec board_payload(GenServer.name(), timeout()) :: map()
  def board_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    runtime = dashboard_payload(orchestrator, snapshot_timeout_ms)

    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        case pitchai_pm_client().board_snapshot() do
          {:ok, board} ->
            board = annotate_board_runtime(board, runtime)

            %{
              generated_at: generated_at,
              tracker: tracker_payload(),
              runtime: runtime,
              board: board,
              running_progress: running_progress_entries(board, runtime)
            }

          {:error, reason} ->
            %{
              generated_at: generated_at,
              tracker: tracker_payload(),
              runtime: runtime,
              error: %{
                code: "board_snapshot_failed",
                message: inspect(reason, pretty: false)
              }
            }
        end

      other ->
        %{
          generated_at: generated_at,
          tracker: tracker_payload(),
          runtime: runtime,
          error: %{
            code: "unsupported_board_tracker",
            message: "Kanban board requires pitchai_pm tracker, got #{other}"
          }
        }
    end
  end

  @spec board_task_detail(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, term()}
  def board_task_detail(task_id, orchestrator, snapshot_timeout_ms) when is_binary(task_id) do
    runtime = dashboard_payload(orchestrator, snapshot_timeout_ms)
    board_task_detail(task_id, runtime)
  end

  @spec board_task_detail(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def board_task_detail(task_id, runtime) when is_binary(task_id) and is_map(runtime) do
    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        with {:ok, detail} <- pitchai_pm_client().task_detail(task_id) do
          {:ok, detail |> annotate_detail_runtime(runtime) |> enrich_detail_workpad()}
        end

      other ->
        {:error, {:unsupported_board_tracker, other}}
    end
  end

  defp snapshot_payload(orchestrator, snapshot_timeout_ms, dashboard?) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        base_payload = %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload(&1, dashboard?)),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload(&1, dashboard?)),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

        if dashboard? do
          Map.merge(base_payload, %{
            polling: Map.get(snapshot, :polling),
            tracker: tracker_payload(),
            max_agents: Config.settings!().agent.max_concurrent_agents
          })
        else
          base_payload
        end

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec move_board_task(String.t(), String.t()) :: :ok | {:error, term()}
  def move_board_task(task_id, state_name), do: move_board_task(task_id, state_name, %{})

  @spec move_board_task(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def move_board_task(task_id, state_name, opts)
      when is_binary(task_id) and is_binary(state_name) and is_map(opts) do
    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        pitchai_pm_client().move_issue_on_board(task_id, state_name, Map.put_new(opts, :reason, "kanban_drag_drop"))

      other ->
        {:error, {:unsupported_board_tracker, other}}
    end
  end

  @spec cancel_board_task(String.t(), GenServer.name(), timeout(), map()) :: :ok | {:error, term()}
  def cancel_board_task(task_id, orchestrator, snapshot_timeout_ms, opts \\ %{})
      when is_binary(task_id) and is_map(opts) do
    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        with {:ok, detail} <- pitchai_pm_client().task_detail(task_id),
             :ok <-
               pitchai_pm_client().move_issue_on_board(
                 task_id,
                 "Cancelled",
                 Map.put_new(opts, :reason, "kanban_cancel")
               ) do
          cancel_orchestrator_issue(orchestrator, task_id, detail.identifier, snapshot_timeout_ms)
        end

      other ->
        {:error, {:unsupported_board_tracker, other}}
    end
  end

  defp cancel_orchestrator_issue(orchestrator, task_id, identifier, timeout) do
    case Orchestrator.cancel_issue(orchestrator, task_id, identifier, timeout) do
      :ok -> :ok
      other -> {:error, {:orchestrator_cancel_failed, other}}
    end
  end

  @spec set_board_group_collapsed(String.t(), String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_board_group_collapsed(group_by, column_state_name, group_key, collapsed?)
      when is_binary(group_by) and is_binary(column_state_name) and is_binary(group_key) and is_boolean(collapsed?) do
    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        pitchai_pm_client().set_board_group_collapsed(group_by, column_state_name, group_key, collapsed?)

      other ->
        {:error, {:unsupported_board_tracker, other}}
    end
  end

  @spec set_board_column_sort(String.t(), String.t()) :: :ok | {:error, term()}
  def set_board_column_sort(column_state_name, sort_key) when is_binary(column_state_name) and is_binary(sort_key) do
    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        pitchai_pm_client().set_board_column_sort(column_state_name, sort_key)

      other ->
        {:error, {:unsupported_board_tracker, other}}
    end
  end

  @spec create_board_task(map(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, term()}
  def create_board_task(params, orchestrator, snapshot_timeout_ms) when is_map(params) do
    runtime = dashboard_payload(orchestrator, snapshot_timeout_ms)

    case Config.settings!().tracker.kind do
      "pitchai_pm" ->
        with {:ok, detail} <- pitchai_pm_client().create_board_task(params) do
          {:ok, detail |> annotate_detail_runtime(runtime) |> enrich_detail_workpad()}
        end

      other ->
        {:error, {:unsupported_board_tracker, other}}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry, dashboard?) do
    recent_events = recent_events_payload(entry)

    base_payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: runtime_last_message(entry, recent_events),
      plan: normalize_runtime_plan(Map.get(entry, :codex_plan)),
      recent_events: recent_events,
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      runtime_seconds: Map.get(entry, :runtime_seconds),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }

    if dashboard? do
      Map.put(base_payload, :codex_app_server_pid, Map.get(entry, :codex_app_server_pid))
    else
      base_payload
    end
  end

  defp retry_entry_payload(entry, dashboard?) do
    base_payload = %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }

    if dashboard? do
      Map.put(base_payload, :due_in_ms, entry.due_in_ms)
    else
      base_payload
    end
  end

  defp running_issue_payload(running) do
    recent_events = recent_events_payload(running)

    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: runtime_last_message(running, recent_events),
      plan: normalize_runtime_plan(Map.get(running, :codex_plan)),
      recent_events: recent_events,
      last_event_at: iso8601(running.last_codex_timestamp),
      runtime_seconds: Map.get(running, :runtime_seconds),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp runtime_last_message(entry, recent_events) when is_list(recent_events) do
    case recent_events do
      [%{message: message} | _events] when is_binary(message) -> message
      [%{"message" => message} | _events] when is_binary(message) -> message
      _events -> summarize_message(entry.last_codex_message)
    end
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    events =
      case Map.get(running, :recent_codex_events, []) do
        events when is_list(events) and events != [] ->
          Enum.map(events, &runtime_event_payload/1)

        _ ->
          [
            %{
              at: iso8601(running.last_codex_timestamp),
              event: running.last_codex_event,
              method: nil,
              message: summarize_message(running.last_codex_message)
            }
          ]
          |> Enum.reject(&is_nil(&1.at))
      end

    Enum.filter(events, &assistant_runtime_event?/1)
  end

  defp runtime_event_payload(event) when is_map(event) do
    %{
      at: iso8601(Map.get(event, :timestamp) || Map.get(event, "timestamp")),
      event: Map.get(event, :event) || Map.get(event, "event"),
      method: Map.get(event, :method) || Map.get(event, "method"),
      message: Map.get(event, :message) || Map.get(event, "message"),
      stream_kind: Map.get(event, :stream_kind) || Map.get(event, "stream_kind"),
      assistant_message_kind: Map.get(event, :assistant_message_kind) || Map.get(event, "assistant_message_kind"),
      stream_text: Map.get(event, :stream_text) || Map.get(event, "stream_text")
    }
  end

  defp runtime_event_payload(_event), do: %{at: nil, event: nil, method: nil, message: nil}

  defp assistant_runtime_event?(%{stream_kind: "assistant_message"}), do: true

  defp assistant_runtime_event?(%{message: message}) when is_binary(message) do
    String.starts_with?(message, "assistant draft: ") or String.starts_with?(message, "assistant final: ")
  end

  defp assistant_runtime_event?(_event), do: false

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp tracker_payload do
    tracker = Config.settings!().tracker

    case tracker.kind do
      "pitchai_pm" ->
        %{
          kind: "pitchai_pm",
          label: "pitchai_pm:#{tracker.project_id || "n/a"}"
        }

      _ ->
        %{
          kind: tracker.kind,
          label: linear_project_label(tracker.project_slug)
        }
    end
  end

  defp linear_project_label(project_slug) when is_binary(project_slug) and project_slug != "" do
    "https://linear.app/project/#{project_slug}/issues"
  end

  defp linear_project_label(_project_slug), do: "n/a"

  defp pitchai_pm_client do
    Application.get_env(:symphony_elixir, :pitchai_pm_client_module, PitchAIPM.Client)
  end

  defp annotate_board_runtime(board, runtime) do
    running_by_id = runtime_index(Map.get(runtime, :running, []))
    retrying_by_id = runtime_index(Map.get(runtime, :retrying, []))

    board
    |> Map.update!(:columns, &annotate_columns(&1, running_by_id, retrying_by_id))
    |> Map.update!(:hidden_columns, &annotate_columns(&1, running_by_id, retrying_by_id))
  end

  defp annotate_columns(columns, running_by_id, retrying_by_id) do
    Enum.map(columns, fn column ->
      Map.update!(column, :tasks, fn tasks ->
        Enum.map(tasks, &annotate_task_runtime(&1, running_by_id, retrying_by_id))
      end)
    end)
  end

  defp annotate_task_runtime(task, running_by_id, retrying_by_id) do
    running = Map.get(running_by_id, task.id) || Map.get(running_by_id, task.identifier)
    retrying = Map.get(retrying_by_id, task.id) || Map.get(retrying_by_id, task.identifier)

    cond do
      running ->
        Map.put(task, :runtime_status, %{kind: "running", label: "Active"})

      retrying ->
        Map.put(task, :runtime_status, %{kind: "retrying", label: "Retry #{retrying.attempt}"})

      true ->
        Map.put(task, :runtime_status, nil)
    end
  end

  defp annotate_detail_runtime(detail, runtime) do
    running_by_id = runtime_index(Map.get(runtime, :running, []))
    retrying_by_id = runtime_index(Map.get(runtime, :retrying, []))
    running = Map.get(running_by_id, detail.id) || Map.get(running_by_id, detail.identifier)
    retrying = Map.get(retrying_by_id, detail.id) || Map.get(retrying_by_id, detail.identifier)

    detail
    |> Map.put(:runtime, running)
    |> Map.put(:retry, retrying)
    |> Map.put(:runtime_status, detail_runtime_status(running, retrying))
  end

  defp detail_runtime_status(running, _retrying) when is_map(running), do: %{kind: "running", label: "Active"}
  defp detail_runtime_status(nil, retrying) when is_map(retrying), do: %{kind: "retrying", label: "Retry #{retrying.attempt}"}
  defp detail_runtime_status(_running, _retrying), do: nil

  defp running_progress_entries(board, runtime) do
    running_by_id = runtime_index(Map.get(runtime, :running, []))

    board
    |> board_tasks()
    |> Enum.filter(&running_task?/1)
    |> Enum.flat_map(&running_progress_entry(&1, running_by_id, runtime))
  end

  defp board_tasks(board) do
    (Map.get(board, :columns, []) ++ Map.get(board, :hidden_columns, []))
    |> Enum.flat_map(&Map.get(&1, :tasks, []))
  end

  defp running_task?(%{runtime_status: %{kind: "running"}}), do: true
  defp running_task?(_task), do: false

  defp running_progress_entry(task, running_by_id, runtime) do
    running = Map.get(running_by_id, task.id) || Map.get(running_by_id, task.identifier)

    case pitchai_pm_client().task_detail(task.id) do
      {:ok, detail} ->
        detail = detail |> annotate_detail_runtime(runtime) |> enrich_detail_workpad()
        progress = Map.get(detail, :progress, %{done: 0, total: 0})

        [
          %{
            id: task.id,
            identifier: task.identifier,
            title: task.title,
            done: progress.done,
            total: progress.total,
            started_at: running && Map.get(running, :started_at),
            runtime_seconds: running && Map.get(running, :runtime_seconds)
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp enrich_detail_workpad(detail) do
    sections = workpad_sections(get_in(detail, [:workpad, :body]))
    runtime_plan = detail |> Map.get(:runtime) |> runtime_plan_from_entry()
    sections = maybe_insert_runtime_plan(sections, runtime_plan)

    detail
    |> Map.put(:description_text, description_text(Map.get(detail, :description)))
    |> Map.put(:workpad_sections, sections)
    |> Map.put(:blocked_reason, blocked_reason(detail, sections))
    |> Map.put(:final_assistant_message, final_assistant_message(detail, sections))
    |> Map.put(:progress, progress_summary(sections))
  end

  defp final_assistant_message(detail, sections) when is_map(detail) and is_list(sections) do
    runtime_final_assistant_message(Map.get(detail, :runtime)) ||
      persisted_final_assistant_message(Map.get(detail, :comments, [])) ||
      workpad_completion_message(detail, sections)
  end

  defp final_assistant_message(_detail, _sections), do: nil

  defp runtime_final_assistant_message(%{recent_events: events}) when is_list(events) do
    Enum.find_value(events, fn event ->
      if assistant_message_kind(event) == "final" do
        event
        |> assistant_message_detail()
        |> with_message_source("app-server")
      end
    end)
  end

  defp runtime_final_assistant_message(_runtime), do: nil

  defp persisted_final_assistant_message(comments) when is_list(comments) do
    Enum.find_value(comments, fn comment ->
      if comment_kind(comment) == "assistant_final" do
        comment
        |> comment_body()
        |> assistant_message_detail(comment_created_at(comment))
        |> with_message_source("stored app-server final")
      end
    end)
  end

  defp persisted_final_assistant_message(_comments), do: nil

  defp workpad_completion_message(detail, sections) when is_map(detail) and is_list(sections) do
    if completed_state?(Map.get(detail, :state)) do
      body = workpad_completion_body(sections)

      if is_binary(body) do
        %{
          body: body,
          at: get_in(detail, [:workpad, :updated_at]) || Map.get(detail, :updated_at),
          source: "derived from workpad"
        }
      end
    end
  end

  defp workpad_completion_message(_detail, _sections), do: nil

  defp completed_state?(state) when is_binary(state) do
    state
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["human review", "done"]))
  end

  defp completed_state?(_state), do: false

  defp workpad_completion_body(sections) do
    notes =
      sections
      |> section_text_lines("notes")
      |> take_last(3)
      |> Enum.reverse()

    validation =
      sections
      |> section_checked_items("validation")
      |> take_last(5)
      |> Enum.reverse()

    acceptance =
      sections
      |> section_checked_items("acceptance_criteria")
      |> take_last(3)

    [
      {"Recent workpad notes", notes},
      {"Validation evidence", validation},
      {"Completed acceptance criteria", acceptance}
    ]
    |> Enum.reject(fn {_title, lines} -> lines == [] end)
    |> case do
      [] ->
        nil

      groups ->
        [
          "No stored app-server final message was captured for this run. Workpad completion summary:",
          groups
          |> Enum.map_join("\n\n", fn {title, lines} -> "#{title}:\n" <> bullet_lines(lines) end)
        ]
        |> Enum.join("\n\n")
    end
  end

  defp section_text_lines(sections, key) do
    sections
    |> Enum.find_value([], fn
      %{key: ^key, text_lines: lines} when is_list(lines) -> lines
      %{"key" => ^key, "text_lines" => lines} when is_list(lines) -> lines
      _section -> nil
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp section_checked_items(sections, key) do
    sections
    |> Enum.find_value([], fn
      %{key: ^key, items: items} when is_list(items) -> checked_item_text(items)
      %{"key" => ^key, "items" => items} when is_list(items) -> checked_item_text(items)
      _section -> nil
    end)
  end

  defp checked_item_text(items) do
    items
    |> Enum.filter(fn
      %{checked: true} -> true
      %{"checked" => true} -> true
      _item -> false
    end)
    |> Enum.map(fn item -> Map.get(item, :text) || Map.get(item, "text") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp take_last(items, count) when is_list(items) and is_integer(count) and count > 0 do
    items
    |> Enum.reverse()
    |> Enum.take(count)
    |> Enum.reverse()
  end

  defp take_last(_items, _count), do: []

  defp bullet_lines(lines), do: Enum.map_join(lines, "\n", &("- " <> bullet_text(&1)))

  defp bullet_text(line) when is_binary(line) do
    line
    |> String.trim()
    |> String.replace(~r/^[-*]\s+/, "")
  end

  defp bullet_text(_line), do: ""

  defp with_message_source(nil, _source), do: nil
  defp with_message_source(message, source) when is_map(message), do: Map.put(message, :source, source)

  defp assistant_message_detail(event) when is_map(event) do
    event
    |> assistant_message_body()
    |> assistant_message_detail(Map.get(event, :at) || Map.get(event, "at"))
  end

  defp assistant_message_detail(body, at) when is_binary(body) do
    case String.trim(body) do
      "" -> nil
      text -> %{body: text, at: at}
    end
  end

  defp assistant_message_detail(_body, _at), do: nil

  defp assistant_message_kind(event) when is_map(event) do
    Map.get(event, :assistant_message_kind) || Map.get(event, "assistant_message_kind")
  end

  defp assistant_message_kind(_event), do: nil

  defp assistant_message_body(event) when is_map(event) do
    Map.get(event, :stream_text) ||
      Map.get(event, "stream_text") ||
      event
      |> Map.get(:message, Map.get(event, "message"))
      |> strip_assistant_prefix()
  end

  defp strip_assistant_prefix(message) when is_binary(message) do
    message
    |> String.replace_prefix("assistant final: ", "")
    |> String.replace_prefix("assistant draft: ", "")
  end

  defp strip_assistant_prefix(_message), do: nil

  defp comment_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp comment_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp comment_kind(_comment), do: nil

  defp comment_body(%{"body" => body}) when is_binary(body), do: body
  defp comment_body(%{body: body}) when is_binary(body), do: body
  defp comment_body(_comment), do: nil

  defp comment_created_at(%{"created_at" => created_at}), do: created_at
  defp comment_created_at(%{created_at: created_at}), do: created_at
  defp comment_created_at(_comment), do: nil

  defp runtime_plan_from_entry(%{plan: plan}), do: normalize_runtime_plan(plan)
  defp runtime_plan_from_entry(%{"plan" => plan}), do: normalize_runtime_plan(plan)
  defp runtime_plan_from_entry(_runtime), do: []

  defp maybe_insert_runtime_plan(sections, []), do: sections

  defp maybe_insert_runtime_plan(sections, runtime_plan) do
    Enum.map(sections, fn
      %{key: "plan", items: []} = section ->
        %{section | items: runtime_plan, source: "app-server"}

      section ->
        section
    end)
  end

  defp workpad_sections(body) when is_binary(body) and body != "" do
    section_map =
      body
      |> String.split("\n")
      |> Enum.reduce(initial_section_map(), &collect_workpad_line/2)
      |> Map.fetch!(:sections)

    @workpad_section_titles
    |> Enum.map(fn title -> section_map[title] end)
    |> Enum.map(&finalize_workpad_section/1)
  end

  defp workpad_sections(_body) do
    @workpad_section_titles
    |> Enum.map(fn title -> finalize_workpad_section(initial_section(title)) end)
  end

  defp initial_section_map do
    %{
      current: nil,
      sections: Map.new(@workpad_section_titles, fn title -> {title, initial_section(title)} end)
    }
  end

  defp initial_section(title), do: %{key: section_key(title), title: title, source: "workpad", lines: []}

  defp collect_workpad_line(line, acc) do
    case Regex.run(@heading_line, line) do
      [_match, title] -> %{acc | current: normalized_section_title(title)}
      _match -> append_workpad_line(acc, line)
    end
  end

  defp append_workpad_line(%{current: nil} = acc, _line), do: acc

  defp append_workpad_line(%{current: current} = acc, line) do
    update_in(acc.sections[current].lines, &(&1 ++ [line]))
  end

  defp normalized_section_title(title) do
    Enum.find(@workpad_section_titles, fn section_title ->
      String.downcase(section_title) == String.downcase(String.trim(title))
    end)
  end

  defp finalize_workpad_section(%{lines: lines} = section) do
    items = checkbox_items(lines)
    text_lines = text_section_lines(lines)

    section
    |> Map.put(:items, items)
    |> Map.put(:text_lines, text_lines)
    |> Map.delete(:lines)
  end

  defp checkbox_items(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case Regex.run(@checkbox_line, line) do
        [_match, indent, checked, text] ->
          [
            %{
              depth: checkbox_depth(indent),
              checked: checked in ["x", "X"],
              status: if(checked in ["x", "X"], do: "done", else: "pending"),
              text: String.trim(text)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp text_section_lines(lines) do
    lines
    |> Enum.reject(&(Regex.match?(@checkbox_line, &1) or String.trim(&1) == ""))
    |> Enum.map(&String.trim/1)
  end

  defp checkbox_depth(indent), do: div(String.length(String.replace(indent, "\t", "  ")), 2)

  defp section_key(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp progress_summary(sections) do
    checklist_items = Enum.flat_map(sections, & &1.items)
    total = length(checklist_items)
    done = Enum.count(checklist_items, & &1.checked)

    percent =
      if total > 0 do
        (done * 100) |> div(total)
      else
        0
      end

    %{done: done, total: total, percent: percent}
  end

  defp description_text(description) when is_map(description) do
    primary = description_primary_text(description)
    labeled = description_labeled_texts(description, primary)

    ([primary] ++ labeled)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp description_text(description) when is_binary(description), do: clean_text(description)
  defp description_text(description) when is_list(description), do: description_value_to_text(description)
  defp description_text(_description), do: nil

  defp description_primary_text(description) do
    Enum.find_value(@description_primary_paths, fn path ->
      description
      |> description_path_value(path)
      |> description_value_to_text()
    end)
  end

  defp description_labeled_texts(description, primary) do
    {parts, _seen} =
      Enum.reduce(@description_labeled_paths, {[], MapSet.new([primary])}, fn {label, path}, {parts, seen} ->
        text =
          description
          |> description_path_value(path)
          |> description_value_to_text()

        if is_nil(text) or MapSet.member?(seen, text) do
          {parts, seen}
        else
          {[description_labeled_text(label, text) | parts], MapSet.put(seen, text)}
        end
      end)

    parts
    |> Enum.reverse()
    |> Enum.take(8)
  end

  defp description_labeled_text(label, text) do
    if String.contains?(text, "\n") do
      "#{label}:\n#{text}"
    else
      "#{label}: #{text}"
    end
  end

  defp description_path_value(description, path) when is_map(description) and is_list(path) do
    Enum.reduce_while(path, description, fn key, current ->
      if is_map(current) do
        {:cont, Map.get(current, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp description_path_value(_description, _path), do: nil

  defp description_value_to_text(value) when is_binary(value), do: clean_text(value)

  defp description_value_to_text(values) when is_list(values) do
    values
    |> Enum.map(&description_value_to_text/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      [single] -> "- #{single}"
      multiple -> Enum.map_join(multiple, "\n", &"- #{&1}")
    end
  end

  defp description_value_to_text(_value), do: nil

  defp blocked_reason(detail, sections) when is_map(detail) and is_list(sections) do
    if blocked_state?(Map.get(detail, :state)) do
      clean_text(Map.get(detail, :blocked_reason)) ||
        latest_blocker_comment_body(Map.get(detail, :comments, [])) ||
        blocker_section_text(sections)
    end
  end

  defp blocked_reason(_detail, _sections), do: nil

  defp blocked_state?(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name)) == "blocked"
  end

  defp blocked_state?(_state_name), do: false

  defp latest_blocker_comment_body(comments) when is_list(comments) do
    Enum.find_value(comments, fn
      %{"body" => body} when is_binary(body) -> blocker_comment_body(body)
      %{body: body} when is_binary(body) -> blocker_comment_body(body)
      _ -> nil
    end)
  end

  defp latest_blocker_comment_body(_comments), do: nil

  defp blocker_comment_body(body) do
    cleaned_body = String.trim(body)
    normalized_body = String.downcase(cleaned_body)

    if cleaned_body != "" and (String.starts_with?(normalized_body, "blocked") or String.starts_with?(normalized_body, "true blocker")) do
      cleaned_body
    end
  end

  defp clean_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp clean_text(_value), do: nil

  defp blocker_section_text(sections) do
    sections
    |> Enum.find(&(Map.get(&1, :key) == "blockers"))
    |> case do
      %{text_lines: lines} when is_list(lines) ->
        lines
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")
        |> clean_joined_text()

      _ ->
        nil
    end
  end

  defp clean_joined_text(""), do: nil
  defp clean_joined_text(text), do: text

  defp normalize_runtime_plan(plan) when is_list(plan) do
    plan
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} -> normalize_runtime_plan_entry(entry, index) end)
  end

  defp normalize_runtime_plan(_plan), do: []

  defp normalize_runtime_plan_entry(entry, index) when is_map(entry) do
    status =
      entry
      |> map_get_any(["status", :status, "state", :state])
      |> to_string()
      |> String.downcase()

    text =
      map_get_any(entry, ["step", :step, "text", :text, "description", :description, "title", :title]) ||
        "Plan step #{index}"

    %{
      depth: 0,
      checked: status in ["complete", "completed", "done"],
      status: status,
      text: to_string(text)
    }
  end

  defp normalize_runtime_plan_entry(entry, _index) when is_binary(entry) do
    %{depth: 0, checked: false, status: "pending", text: entry}
  end

  defp normalize_runtime_plan_entry(_entry, index) do
    %{depth: 0, checked: false, status: "pending", text: "Plan step #{index}"}
  end

  defp map_get_any(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        value when not is_nil(value) -> value
        _ -> nil
      end
    end)
  end

  defp runtime_index(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      acc
      |> put_if_present(Map.get(entry, :issue_id), entry)
      |> put_if_present(Map.get(entry, :issue_identifier), entry)
    end)
  end

  defp runtime_index(_entries), do: %{}

  defp put_if_present(map, key, value) when is_binary(key) and key != "", do: Map.put(map, key, value)
  defp put_if_present(map, _key, _value), do: map
end
