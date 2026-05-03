defmodule SymphonyElixirWeb.BoardLive do
  @moduledoc """
  Live PM-backed Kanban board for Symphony ticket orchestration.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @board_tick_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:selected_task, nil)
      |> assign(:group_by, "project")
      |> assign(:show_hidden_columns, false)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_board_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    _result = Presenter.refresh_payload(orchestrator())
    {:noreply, reload_board(socket)}
  end

  @impl true
  def handle_event("open_task", %{"task_id" => task_id}, socket) do
    case Presenter.board_task_detail(task_id, orchestrator(), snapshot_timeout_ms()) do
      {:ok, detail} ->
        {:noreply, assign(socket, :selected_task, detail)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Task unavailable: #{inspect(reason, pretty: false)}")}
    end
  end

  @impl true
  def handle_event("close_task", _params, socket) do
    {:noreply, assign(socket, :selected_task, nil)}
  end

  @impl true
  def handle_event("set_group_by", %{"group_by" => group_by}, socket) do
    {:noreply, assign(socket, :group_by, normalize_group_by(group_by))}
  end

  @impl true
  def handle_event("toggle_hidden_columns", _params, socket) do
    {:noreply, update(socket, :show_hidden_columns, &(!&1))}
  end

  @impl true
  def handle_event("move_task", %{"task_id" => task_id, "target_state" => target_state} = params, socket) do
    if valid_board_state?(socket.assigns.payload, target_state) do
      opts = %{
        before_task_id: optional_param(params, "before_task_id"),
        after_task_id: optional_param(params, "after_task_id")
      }

      case Presenter.move_board_task(task_id, target_state, opts) do
        :ok ->
          {:noreply, reload_board(socket)}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Move failed: #{inspect(reason, pretty: false)}")
           |> reload_board()}
      end
    else
      {:noreply, put_flash(socket, :error, "Move failed: unsupported target state")}
    end
  end

  @impl true
  def handle_info(:board_tick, socket) do
    schedule_board_tick()
    {:noreply, reload_board(socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, reload_board(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="board-page">
      <div class="board-appbar">
        <nav class="board-tabs" aria-label="Board views">
          <a href="#" class="board-tab">Overview</a>
          <a href="#" class="board-tab">Updates</a>
          <a href="#" class="board-tab is-active">Issues</a>
          <a href="#" class="board-tab">+</a>
        </nav>

        <div class="board-controls">
          <form phx-change="set_group_by" class="group-control">
            <label for="board-group-by">Group</label>
            <select id="board-group-by" name="group_by">
              <option
                :for={option <- group_by_options()}
                value={option.value}
                selected={@group_by == option.value}
              >
                <%= option.label %>
              </option>
            </select>
          </form>
          <button class="text-tool" type="button" phx-click="toggle_hidden_columns">
            <%= if @show_hidden_columns, do: "Hide hidden", else: "Show hidden" %>
          </button>
          <a class="text-tool" href="/status">Status</a>
          <button class="text-tool" type="button" phx-click="refresh">Refresh</button>
        </div>
      </div>

      <%= if @payload[:error] do %>
        <div class="board-error">
          <strong>Board unavailable</strong>
          <span><%= @payload.error.code %>: <%= @payload.error.message %></span>
        </div>
      <% else %>
        <div
          id="kanban-board"
          class={["board-workspace", @show_hidden_columns && "shows-hidden-columns"]}
          phx-hook="KanbanBoard"
        >
          <div class="board-columns" role="list" aria-label="Ticket columns">
            <section
              :for={column <- @payload.board.columns}
              class="kanban-column"
              role="listitem"
              data-drop-state={column.state_name}
            >
              <header class="column-header">
                <div class="column-title">
                  <span class="state-ring" style={"--state-color: #{column.color || "#9ca3af"}"}></span>
                  <span><%= state_label(column.state_name) %></span>
                  <span class="column-count"><%= column.task_count %></span>
                </div>
                <div class="column-menu" aria-hidden="true">...</div>
                <div class="column-plus" aria-hidden="true">+</div>
              </header>

              <div class="ticket-list" data-state-name={column.state_name}>
                <div :for={group <- grouped_tasks(column.tasks, @group_by)} class="issue-group">
                  <div :if={group.label} class="issue-group-label"><%= group.label %></div>

                  <article
                    :for={task <- group.tasks}
                    class={["ticket-card", runtime_class(task)]}
                    data-task-id={task.id}
                    data-task-title={task.title}
                    data-state-name={column.state_name}
                    phx-click="open_task"
                    phx-value-task_id={task.id}
                  >
                    <div class="ticket-key"><%= task.identifier %></div>
                    <div class="ticket-title-row">
                      <%= if in_progress_task?(task, column) do %>
                        <span class="state-spinner" style={"--state-color: #{column.color || "#d5a11e"}"} aria-hidden="true"></span>
                      <% else %>
                        <span class="issue-ring" style={"--state-color: #{column.color || "#9ca3af"}"} aria-hidden="true"></span>
                      <% end %>
                      <span class="ticket-title">
                        <%= task.title %>
                      </span>
                    </div>

                    <div class="ticket-badges">
                      <span :if={visible_runtime_badge(task.runtime_status)} class={["runtime-badge", task.runtime_status.kind]}>
                        <%= visible_runtime_badge(task.runtime_status) %>
                      </span>
                      <span :if={task.priority && task.priority < 5} class="soft-badge">
                        P<%= task.priority %>
                      </span>
                      <span :if={task.pr_count > 0} class="soft-badge">PR</span>
                      <span :if={task.comment_count > 0} class="soft-badge"><%= task.comment_count %> comments</span>
                      <span :for={label <- Enum.take(visible_labels(task.labels), 2)} class="soft-badge"><%= label %></span>
                    </div>

                    <div class="ticket-meta">
                      <span>Updated <%= format_updated(task.updated_at) %></span>
                      <span :if={task.branch_name}><%= task.branch_name %></span>
                    </div>
                  </article>
                </div>

                <div :if={column.tasks == []} class="empty-column">No tickets</div>
              </div>

              <div class="add-ticket-row" aria-hidden="true">+</div>
            </section>
          </div>

          <aside :if={@show_hidden_columns} class="hidden-columns" aria-label="Hidden columns">
            <header class="hidden-title">
              <span class="caret" aria-hidden="true"></span>
              <span>Hidden columns</span>
            </header>

            <div
              :for={column <- @payload.board.hidden_columns}
              class="hidden-column-row"
              data-drop-state={column.state_name}
              data-hidden-drop="true"
            >
              <span class="state-ring" style={"--state-color: #{column.color || "#9ca3af"}"}></span>
              <span><%= state_label(column.state_name) %></span>
              <span><%= column.task_count %></span>
            </div>
          </aside>
        </div>

        <.task_detail_modal :if={@selected_task} task={@selected_task} />
      <% end %>
    </section>
    """
  end

  defp task_detail_modal(assigns) do
    ~H"""
    <div class="detail-backdrop" role="presentation">
      <section class="detail-modal" role="dialog" aria-modal="true" aria-labelledby="task-detail-title">
        <div class="detail-main">
          <header class="detail-header">
            <div class="detail-crumbs">
              <span><%= display_project_name(@task.project.name) %></span>
              <span aria-hidden="true">/</span>
              <span><%= @task.identifier %></span>
            </div>
            <button class="detail-close" type="button" phx-click="close_task" aria-label="Close task details">x</button>
          </header>

          <h1 id="task-detail-title" class="detail-title"><%= @task.title %></h1>
          <p :if={@task.description_text} class="detail-description"><%= @task.description_text %></p>

          <div class="detail-inline-meta">
            <span class={["detail-status-pill", detail_status_class(@task.runtime_status)]}>
              <span class="state-spinner mini" :if={@task.runtime_status && @task.runtime_status.kind == "running"} aria-hidden="true"></span>
              <%= @task.state || "No state" %>
            </span>
            <span :if={@task.value_name} class="detail-chip"><%= @task.value_name %></span>
            <span :if={@task.priority} class="detail-chip">P<%= @task.priority %></span>
            <span :for={label <- Enum.take(visible_labels(@task.labels), 4)} class="detail-chip"><%= label %></span>
          </div>

          <section class="agent-progress-panel" aria-label="Agent progress">
            <div class="agent-progress-heading">
              <div>
                <h2>Agent progress</h2>
                <p><%= agent_progress_subtitle(@task) %></p>
              </div>
              <strong class="progress-count">
                <span>Checklist</span>
                <%= @task.progress.done %>/<%= @task.progress.total %>
              </strong>
            </div>
            <div class="detail-progress-track" aria-hidden="true">
              <span style={"width: #{@task.progress.percent}%"}></span>
            </div>
            <div class="agent-runtime-grid">
              <div>
                <span>Session</span>
                <strong><%= runtime_value(@task.runtime, :session_id) || "n/a" %></strong>
              </div>
              <div>
                <span>Turn</span>
                <strong><%= runtime_value(@task.runtime, :turn_count) || 0 %></strong>
              </div>
              <div>
                <span>Tokens</span>
                <strong><%= token_total(@task.runtime) %></strong>
              </div>
              <div>
                <span>Last event</span>
                <strong><%= runtime_value(@task.runtime, :last_message) || "No app-server event yet" %></strong>
              </div>
            </div>
          </section>

          <section class="detail-activity" aria-label="Task activity">
            <h2>Activity</h2>

            <div :for={section <- @task.workpad_sections} class="workpad-section">
              <div class="workpad-section-heading">
                <h3><%= section.title %></h3>
                <span :if={section.source == "app-server"}>live app-server</span>
              </div>

              <div class={["workpad-section-body", section.key == "plan" && "is-plan-scroll"]}>
                <div :if={section.items != []} class="checklist">
                  <div
                    :for={item <- section.items}
                    class={["checklist-item", item.checked && "is-checked"]}
                    style={"--depth: #{item.depth}"}
                  >
                    <span class="checkmark" aria-hidden="true"></span>
                    <span><%= item.text %></span>
                  </div>
                </div>

                <div :if={section.items == [] && section.text_lines == []} class="detail-empty-line">
                  <%= empty_section_label(section, @task) %>
                </div>

                <p :for={line <- section.text_lines} class="detail-note-line"><%= line %></p>
              </div>
            </div>
          </section>
        </div>

        <aside class="detail-sidebar" aria-label="Task properties">
          <div class="detail-side-actions">
            <span><%= @task.identifier %></span>
            <button type="button" phx-click="close_task" aria-label="Close task details">x</button>
          </div>

          <dl class="detail-properties">
            <div>
              <dt>Status</dt>
              <dd><%= @task.state || "No state" %></dd>
            </div>
            <div>
              <dt>Assignee</dt>
              <dd><%= @task.assignee || "Unassigned" %></dd>
            </div>
            <div>
              <dt>Project</dt>
              <dd><%= display_project_name(@task.project.name, "n/a") %></dd>
            </div>
            <div>
              <dt>Updated</dt>
              <dd><%= format_updated(@task.updated_at) %></dd>
            </div>
            <div>
              <dt>Workspace</dt>
              <dd><%= @task.workspace_path || runtime_value(@task.runtime, :workspace_path) || "n/a" %></dd>
            </div>
          </dl>

          <section class="detail-side-section">
            <h3>Resources</h3>
            <a :if={@task.url} href={@task.url} target="_blank" rel="noreferrer">Tracking link</a>
            <span :if={!@task.url && @task.prs == []}>No links yet</span>
            <a :for={pr <- Enum.take(@task.prs, 4)} href={pr["url"]} target="_blank" rel="noreferrer">
              <%= pr["repo_full_name"] || pr["url"] %>
            </a>
          </section>

          <section class="detail-side-section">
            <h3>Recent app-server events</h3>
            <div :if={@task.runtime && @task.runtime.recent_events != []} class="runtime-events">
              <div :for={event <- @task.runtime.recent_events}>
                <span><%= format_updated(event.at) %></span>
                <strong><%= event.message || event.method || event.event %></strong>
              </div>
            </div>
            <span :if={!@task.runtime || @task.runtime.recent_events == []}>No live events yet</span>
          </section>

          <section class="detail-side-section">
            <h3>State history</h3>
            <div class="state-events">
              <div :for={event <- Enum.take(@task.state_events, 5)}>
                <span><%= event["from_state"] || "new" %> -> <%= event["to_state"] %></span>
                <small><%= event["reason"] || event["actor"] %></small>
              </div>
              <span :if={@task.state_events == []}>No state changes recorded yet</span>
            </div>
          </section>
        </aside>
      </section>
    </div>
    """
  end

  defp load_payload do
    Presenter.board_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp reload_board(socket) do
    socket
    |> assign(:payload, load_payload())
    |> refresh_selected_task()
  end

  defp refresh_selected_task(%{assigns: %{selected_task: %{id: task_id}}} = socket) when is_binary(task_id) do
    case Presenter.board_task_detail(task_id, orchestrator(), snapshot_timeout_ms()) do
      {:ok, detail} -> assign(socket, :selected_task, detail)
      {:error, _reason} -> assign(socket, :selected_task, nil)
    end
  end

  defp refresh_selected_task(socket), do: socket

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp state_label("Symphony " <> rest), do: rest
  defp state_label(state_name), do: state_name

  defp runtime_class(%{runtime_status: %{kind: "running"}}), do: "is-running"
  defp runtime_class(%{runtime_status: %{kind: "retrying"}}), do: "is-retrying"
  defp runtime_class(_task), do: nil

  defp visible_runtime_badge(%{kind: "running"}), do: nil
  defp visible_runtime_badge(%{label: label}) when is_binary(label), do: label
  defp visible_runtime_badge(_runtime_status), do: nil

  defp visible_labels(labels) when is_list(labels) do
    Enum.reject(labels, &(String.downcase(to_string(&1)) == "symphony"))
  end

  defp visible_labels(_labels), do: []

  defp group_by_options do
    [
      %{value: "project", label: "Project"},
      %{value: "assignee", label: "Assignee"},
      %{value: "priority", label: "Priority"},
      %{value: "none", label: "None"}
    ]
  end

  defp normalize_group_by(value) when value in ["project", "assignee", "priority", "none"], do: value
  defp normalize_group_by(_value), do: "project"

  defp grouped_tasks(tasks, "none"), do: [%{label: nil, tasks: tasks}]
  defp grouped_tasks([], _group_by), do: []

  defp grouped_tasks(tasks, group_by) do
    groups =
      tasks
      |> Enum.map(&task_group_label(&1, group_by))
      |> Enum.uniq()

    Enum.map(groups, fn label ->
      %{label: label, tasks: Enum.filter(tasks, &(task_group_label(&1, group_by) == label))}
    end)
  end

  defp task_group_label(task, "project"), do: display_project_name(Map.get(task, :project_name), "No project")
  defp task_group_label(task, "assignee"), do: Map.get(task, :assignee) || "Unassigned"
  defp task_group_label(task, "priority"), do: "P#{Map.get(task, :priority) || 5}"
  defp task_group_label(task, _group_by), do: display_project_name(Map.get(task, :project_name), "No project")

  defp display_project_name(project_name, fallback \\ "Project")

  defp display_project_name(project_name, fallback) when is_binary(project_name) do
    display_name =
      project_name
      |> String.trim()
      |> String.replace_prefix("Repo: ", "")

    if display_name == "", do: fallback, else: display_name
  end

  defp display_project_name(_project_name, fallback), do: fallback

  defp in_progress_task?(_task, %{state_name: "In Progress"}), do: true
  defp in_progress_task?(%{state: "In Progress"}, _column), do: true
  defp in_progress_task?(_task, _column), do: false

  defp detail_status_class(%{kind: kind}), do: kind
  defp detail_status_class(_status), do: nil

  defp agent_progress_subtitle(%{runtime_status: %{kind: "running"}}), do: "Codex app-server is actively working this task."
  defp agent_progress_subtitle(%{runtime_status: %{kind: "retrying"}}), do: "Work is queued for retry."
  defp agent_progress_subtitle(_task), do: "No live agent is attached right now."

  defp runtime_value(nil, _key), do: nil
  defp runtime_value(runtime, key) when is_map(runtime), do: Map.get(runtime, key) || Map.get(runtime, to_string(key))

  defp token_total(nil), do: 0

  defp token_total(runtime) when is_map(runtime) do
    case runtime_value(runtime, :tokens) do
      %{total_tokens: total} -> total || 0
      %{"total_tokens" => total} -> total || 0
      _ -> 0
    end
  end

  defp empty_section_label(%{key: "plan"}, %{runtime_status: %{kind: "running"}}), do: "Waiting for the app-server plan update."
  defp empty_section_label(%{key: "plan"}, _task), do: "No plan recorded yet."
  defp empty_section_label(_section, _task), do: "No entries recorded yet."

  defp valid_board_state?(%{board: board}, target_state) when is_binary(target_state) do
    target_key = normalize_state(target_state)

    (Map.get(board, :columns, []) ++ Map.get(board, :hidden_columns, []))
    |> Enum.any?(fn column -> normalize_state(Map.get(column, :state_name)) == target_key end)
  end

  defp valid_board_state?(_payload, _target_state), do: false

  defp optional_param(params, key) do
    params
    |> Map.get(key)
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp normalize_state(state_name) do
    state_name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp format_updated(value) when is_binary(value) do
    date =
      value
      |> String.slice(0, 10)
      |> Date.from_iso8601()

    case date do
      {:ok, parsed} -> Calendar.strftime(parsed, "%b %d")
      _ -> String.slice(value, 0, 10)
    end
  end

  defp format_updated(_value), do: "unknown"

  defp schedule_board_tick do
    Process.send_after(self(), :board_tick, @board_tick_ms)
  end
end
