defmodule SymphonyElixirWeb.BoardLive do
  @moduledoc """
  Live PM-backed Kanban board for Symphony ticket orchestration.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.BoardForecast
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @board_tick_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:selected_task, nil)
      |> assign(:create_task_form, nil)
      |> assign(:group_by, "project")
      |> assign(:show_hidden_columns, false)
      |> assign(:board_reload_generation, 0)
      |> assign(:board_reload_task, nil)
      |> assign(:forecast_state, BoardForecast.new_state())
      |> refresh_forecast()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_board_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case optional_param(params, "task_id") do
      nil ->
        {:noreply, assign(socket, :selected_task, nil)}

      task_id ->
        case Presenter.board_task_detail(task_id, current_runtime(socket)) do
          {:ok, detail} ->
            {:noreply, assign(socket, :selected_task, detail)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:selected_task, nil)
             |> put_flash(:error, "Task unavailable: #{inspect(reason, pretty: false)}")}
        end
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    _result = Presenter.refresh_payload(orchestrator())
    {:noreply, reload_board(socket)}
  end

  @impl true
  def handle_event("open_task", %{"task_id" => task_id}, socket) do
    case Presenter.board_task_detail(task_id, current_runtime(socket)) do
      {:ok, detail} ->
        {:noreply,
         socket
         |> assign(:selected_task, detail)
         |> push_patch(to: task_detail_path(task_id))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Task unavailable: #{inspect(reason, pretty: false)}")}
    end
  end

  @impl true
  def handle_event("close_task", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> push_patch(to: "/")}
  end

  @impl true
  def handle_event("open_create_task", params, socket) do
    state_name = optional_param(params, "state_name")

    {:noreply, assign(socket, :create_task_form, new_create_task_form(socket.assigns.payload, state_name))}
  end

  @impl true
  def handle_event("close_create_task", _params, socket) do
    {:noreply, assign(socket, :create_task_form, nil)}
  end

  @impl true
  def handle_event("create_task", %{"task" => raw_form}, socket) do
    case validate_create_task_form(raw_form, socket.assigns.payload) do
      {:ok, params} ->
        case Presenter.create_board_task(params, orchestrator(), snapshot_timeout_ms()) do
          {:ok, detail} ->
            socket =
              socket
              |> assign(:create_task_form, nil)
              |> reload_board()
              |> assign(:selected_task, detail)

            {:noreply, socket}

          {:error, reason} ->
            form = create_task_form_with_errors(raw_form, %{form: create_error(reason)})

            {:noreply, assign(socket, :create_task_form, form)}
        end

      {:error, form} ->
        {:noreply, assign(socket, :create_task_form, form)}
    end
  end

  @impl true
  def handle_event("set_group_by", %{"group_by" => group_by}, socket) do
    {:noreply, assign(socket, :group_by, normalize_group_by(group_by))}
  end

  @impl true
  def handle_event("toggle_issue_group", params, socket) do
    group_by = params |> Map.get("group_by") |> normalize_group_by()
    column_state_name = optional_param(params, "column_state_name")
    group_key = optional_param(params, "group_key")
    collapsed? = Map.get(params, "collapsed") == "true"

    if group_by == "none" or is_nil(column_state_name) or is_nil(group_key) do
      {:noreply, put_flash(socket, :error, "Group toggle failed: invalid group")}
    else
      case Presenter.set_board_group_collapsed(group_by, column_state_name, group_key, collapsed?) do
        :ok ->
          {:noreply, reload_board(socket)}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Group toggle failed: #{inspect(reason, pretty: false)}")
           |> reload_board()}
      end
    end
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
  def handle_event("move_task_to_todo", %{"task_id" => task_id}, socket) do
    target_state = "Todo"

    if valid_board_state?(socket.assigns.payload, target_state) do
      case Presenter.move_board_task(task_id, target_state, %{reason: "modal_move_to_todo"}) do
        :ok ->
          {:noreply, reload_board(socket)}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "Move to Todo failed: #{inspect(reason, pretty: false)}")
           |> reload_board()}
      end
    else
      {:noreply, put_flash(socket, :error, "Move to Todo failed: Todo column unavailable")}
    end
  end

  @impl true
  def handle_event("focus_task_card", %{"task_id" => task_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> push_event("focus-task-card", %{task_id: task_id})}
  end

  @impl true
  def handle_info(:board_tick, socket) do
    schedule_board_tick()
    {:noreply, start_async_board_reload(socket)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, start_async_board_reload(socket)}
  end

  @impl true
  def handle_info({ref, {:board_payload, generation, payload}}, %{assigns: %{board_reload_task: %{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])

    socket =
      socket
      |> assign(:board_reload_task, nil)
      |> apply_async_board_payload(generation, payload)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{board_reload_task: %{ref: ref}}} = socket) do
    {:noreply, assign(socket, :board_reload_task, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="board-page">
      <div class="agent-eta-line" aria-label="Agent completion forecast">
        <span class={["eta-live-dot", forecast_idle?(@forecast) && "is-idle"]} aria-hidden="true"></span>
        <strong><%= forecast_summary(@forecast) %></strong>
        <span class="eta-rate"><%= forecast_rate(@forecast) %></span>
        <span class="eta-milestones">
          <span :for={milestone <- forecast_milestones(@forecast)}>
            <%= milestone.count %>: <%= eta_time(milestone.eta_at) %>
          </span>
        </span>
      </div>

      <div class="board-appbar">
        <nav class="board-tabs" aria-label="Board views">
          <a href="#" class="board-tab">Overview</a>
          <a href="#" class="board-tab">Updates</a>
          <a href="#" class="board-tab is-active">Issues</a>
          <button
            class="board-tab board-tab-add"
            type="button"
            phx-click="open_create_task"
            aria-label="Create ticket"
          >
            +
          </button>
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
                <button
                  class="column-plus"
                  type="button"
                  phx-click="open_create_task"
                  phx-value-state_name={column.state_name}
                  aria-label={"Create ticket in #{state_label(column.state_name)}"}
                >
                  +
                </button>
              </header>

              <div class="ticket-list" data-state-name={column.state_name}>
                <div
                  :for={group <- grouped_tasks(column.tasks, @group_by, collapsed_group_keys(@payload, @group_by, column.state_name))}
                  class={["issue-group", group.collapsed && "is-collapsed"]}
                >
                  <button
                    :if={group.label}
                    class="issue-group-label"
                    type="button"
                    phx-click="toggle_issue_group"
                    phx-value-group_by={@group_by}
                    phx-value-column_state_name={column.state_name}
                    phx-value-group_key={group.key}
                    phx-value-collapsed={to_string(!group.collapsed)}
                    aria-expanded={to_string(!group.collapsed)}
                    aria-label={group_toggle_label(group)}
                  >
                    <span class={["group-chevron", group.collapsed && "is-collapsed"]} aria-hidden="true"></span>
                    <span class="issue-group-name"><%= group.label %></span>
                    <span :if={group.collapsed} class="issue-group-count"><%= length(group.tasks) %></span>
                  </button>

                  <article
                    :if={!group.collapsed}
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

                    <div :if={blocked_reason(task)} class="ticket-blocked-reason">
                      <strong>Blocked</strong>
                      <span><%= blocked_reason(task) %></span>
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
                      <span
                        :if={dependency_descendant_label(task)}
                        class="dependency-badge"
                        title={dependency_descendant_title(task)}
                      >
                        <%= dependency_descendant_label(task) %>
                      </span>
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

              <button
                class="add-ticket-row"
                type="button"
                phx-click="open_create_task"
                phx-value-state_name={column.state_name}
                aria-label={"Create ticket in #{state_label(column.state_name)}"}
              >
                +
              </button>
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
        <.create_task_modal :if={@create_task_form} form={@create_task_form} payload={@payload} />
      <% end %>
    </section>
    """
  end

  defp create_task_modal(assigns) do
    ~H"""
    <div id="create-task-backdrop" class="detail-backdrop create-backdrop" role="presentation" phx-hook="ModalScrollLock">
      <section class="create-modal" role="dialog" aria-modal="true" aria-labelledby="create-ticket-title" tabindex="-1">
        <header class="create-header">
          <h2 id="create-ticket-title">New ticket</h2>
          <button type="button" phx-click="close_create_task" aria-label="Close new ticket form">x</button>
        </header>

        <form id="create-ticket-form" class="create-form" phx-submit="create_task">
          <div class="create-grid">
            <label>
              <span>Project</span>
              <select name="task[project_id]" required>
                <option :for={project <- create_project_options(@payload)} value={project.id} selected={project.id == @form.project_id}>
                  <%= display_project_name(project.name) %>
                </option>
              </select>
              <small :if={@form.errors[:project_id]}><%= @form.errors.project_id %></small>
            </label>

            <label>
              <span>Column</span>
              <select name="task[state_name]" required>
                <option :for={state <- create_state_options(@payload)} value={state.state_name} selected={state.state_name == @form.state_name}>
                  <%= state_label(state.state_name) %>
                </option>
              </select>
              <small :if={@form.errors[:state_name]}><%= @form.errors.state_name %></small>
            </label>
          </div>

          <label>
            <span>Title</span>
            <input name="task[name]" type="text" value={@form.name} required maxlength="180" autocomplete="off" />
            <small :if={@form.errors[:name]}><%= @form.errors.name %></small>
          </label>

          <label>
            <span>Prompt</span>
            <textarea name="task[prompt]" required rows="5"><%= @form.prompt %></textarea>
            <small :if={@form.errors[:prompt]}><%= @form.errors.prompt %></small>
          </label>

          <small :if={@form.errors[:form]} class="create-form-error"><%= @form.errors.form %></small>

          <div class="create-actions">
            <button type="button" class="create-secondary" phx-click="close_create_task">Cancel</button>
            <button type="submit" class="create-primary">Create</button>
          </div>
        </form>
      </section>
    </div>
    """
  end

  defp task_detail_modal(assigns) do
    ~H"""
    <div id="task-detail-backdrop" class="detail-backdrop" role="presentation" phx-hook="ModalScrollLock">
      <section class="detail-modal" role="dialog" aria-modal="true" aria-labelledby="task-detail-title" tabindex="-1">
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

          <% detail_chips = detail_chips(@task) %>
          <% blocker_refs = task_blocker_refs(@task) %>
          <div :if={detail_chips != [] or blocker_refs != [] or show_move_to_todo?(@task)} class="detail-quick-row">
            <div class="detail-inline-meta">
              <span :for={chip <- detail_chips} class="detail-chip"><%= chip %></span>
              <span :if={blocker_refs != []} class="detail-inline-label">Blocked by</span>
              <button
                :for={blocker <- blocker_refs}
                type="button"
                class="blocker-ref-chip"
                data-focus-task-id={blocker.id}
                phx-click="focus_task_card"
                phx-value-task_id={blocker.id}
                title={blocker.title}
              >
                <span><%= blocker.identifier %></span>
                <small><%= state_label(blocker.state) %></small>
              </button>
            </div>
            <button
              :if={show_move_to_todo?(@task)}
              type="button"
              class="detail-todo-action"
              phx-click="move_task_to_todo"
              phx-value-task_id={@task.id}
            >
              Move to Todo
            </button>
          </div>

          <section :if={blocked_reason(@task)} class="blocked-reason-panel" aria-label="Blocked reason">
            <strong>Blocked</strong>
            <p><%= blocked_reason(@task) %></p>
          </section>

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

            <div :for={section <- visible_workpad_sections(@task)} class="workpad-section">
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
            <span :if={!@task.runtime || @task.runtime.recent_events == []}>No assistant messages yet</span>
          </section>

          <section :if={@task.final_assistant_message} class="detail-side-section assistant-final-message">
            <h3>Final assistant message</h3>
            <span :if={@task.final_assistant_message.at}><%= format_updated(@task.final_assistant_message.at) %></span>
            <div class="assistant-final-message-body"><%= @task.final_assistant_message.body %></div>
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
    |> bump_board_reload_generation()
    |> assign(:payload, load_payload())
    |> refresh_forecast()
    |> refresh_selected_task()
  end

  defp refresh_selected_task(%{assigns: %{selected_task: %{id: task_id}}} = socket) when is_binary(task_id) do
    case Presenter.board_task_detail(task_id, current_runtime(socket)) do
      {:ok, detail} -> assign(socket, :selected_task, detail)
      {:error, _reason} -> assign(socket, :selected_task, nil)
    end
  end

  defp refresh_selected_task(socket), do: socket

  defp refresh_forecast(socket) do
    {forecast_state, forecast} =
      socket.assigns
      |> Map.get(:forecast_state, BoardForecast.new_state())
      |> BoardForecast.update(Map.get(socket.assigns.payload, :running_progress, []), DateTime.utc_now())

    socket
    |> assign(:forecast_state, forecast_state)
    |> assign(:forecast, forecast)
  end

  defp start_async_board_reload(%{assigns: %{board_reload_task: %Task{}}} = socket), do: socket

  defp start_async_board_reload(socket) do
    generation = Map.get(socket.assigns, :board_reload_generation, 0)

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        {:board_payload, generation, load_payload()}
      end)

    assign(socket, :board_reload_task, task)
  end

  defp apply_async_board_payload(socket, generation, payload) do
    if generation == Map.get(socket.assigns, :board_reload_generation, 0) do
      socket
      |> assign(:payload, payload)
      |> refresh_forecast()
      |> refresh_selected_task()
    else
      socket
    end
  end

  defp bump_board_reload_generation(socket) do
    generation = Map.get(socket.assigns, :board_reload_generation, 0)
    assign(socket, :board_reload_generation, generation + 1)
  end

  defp current_runtime(socket) do
    socket.assigns
    |> Map.get(:payload, %{})
    |> Map.get(:runtime, %{})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp task_detail_path(task_id), do: "/?task_id=#{URI.encode_www_form(task_id)}"

  defp state_label("Symphony " <> rest), do: rest
  defp state_label(state_name), do: state_name

  defp runtime_class(%{runtime_status: %{kind: "running"}}), do: "is-running"
  defp runtime_class(%{runtime_status: %{kind: "retrying"}}), do: "is-retrying"
  defp runtime_class(_task), do: nil

  defp visible_runtime_badge(%{kind: "running"}), do: nil
  defp visible_runtime_badge(%{label: label}) when is_binary(label), do: label
  defp visible_runtime_badge(_runtime_status), do: nil

  defp visible_labels(labels) when is_list(labels) do
    hidden_labels =
      MapSet.new(["auto-blocker", "blocker", "blocker-reconciliation", "meta-agent", "symphony"])

    Enum.reject(labels, &(String.downcase(to_string(&1)) in hidden_labels))
  end

  defp visible_labels(_labels), do: []

  defp forecast_idle?(%{running_count: 0}), do: true
  defp forecast_idle?(_forecast), do: false

  defp forecast_summary(%{running_count: 0}), do: "Agents idle"

  defp forecast_summary(%{running_count: running_count, measured_count: 0}) do
    "#{running_count} active - ETA learning"
  end

  defp forecast_summary(%{running_count: running_count, measured_count: measured_count}) do
    "#{measured_count}/#{running_count} measured"
  end

  defp forecast_summary(_forecast), do: "Agents idle"

  defp forecast_rate(%{running_count: 0}), do: "no active checklists"
  defp forecast_rate(%{measured_count: 0}), do: "checklist speed pending"

  defp forecast_rate(%{throughput_items_per_minute: speed}) when is_number(speed) do
    "#{format_speed(speed)} items/min"
  end

  defp forecast_rate(_forecast), do: "checklist speed pending"

  defp forecast_milestones(%{milestones: milestones}) when is_list(milestones), do: milestones
  defp forecast_milestones(_forecast), do: []

  defp eta_time(%DateTime{} = eta_at), do: Calendar.strftime(eta_at, "%H:%MZ")
  defp eta_time(_eta_at), do: "--"

  defp format_speed(speed) when speed < 1, do: :erlang.float_to_binary(speed, decimals: 2)
  defp format_speed(speed), do: :erlang.float_to_binary(speed, decimals: 1)

  defp new_create_task_form(payload, state_name) do
    %{
      project_id: default_create_project_id(payload),
      state_name: default_create_state_name(payload, state_name),
      name: "",
      prompt: "",
      errors: %{}
    }
  end

  defp create_task_form_with_errors(form, errors) do
    %{
      project_id: string_value(form, "project_id"),
      state_name: string_value(form, "state_name"),
      name: string_value(form, "name"),
      prompt: string_value(form, "prompt"),
      errors: errors
    }
  end

  defp validate_create_task_form(form, payload) when is_map(form) do
    errors =
      %{}
      |> require_known_project(form, payload)
      |> require_known_state(form, payload)
      |> require_nonempty(form, "name", :name, "Title is required.")
      |> require_nonempty(form, "prompt", :prompt, "Prompt is required.")

    if errors == %{} do
      {:ok,
       %{
         "project_id" => string_value(form, "project_id"),
         "state_name" => string_value(form, "state_name"),
         "name" => string_value(form, "name"),
         "description" => %{"request" => string_value(form, "prompt")},
         "value_name" => "Task"
       }}
    else
      {:error, create_task_form_with_errors(form, errors)}
    end
  end

  defp create_error(reason), do: "Create failed: #{inspect(reason, pretty: false)}"

  defp require_known_project(errors, form, payload) do
    project_id = string_value(form, "project_id")

    if Enum.any?(create_project_options(payload), &(&1.id == project_id)) do
      errors
    else
      Map.put(errors, :project_id, "Choose a project.")
    end
  end

  defp require_known_state(errors, form, payload) do
    state_name = string_value(form, "state_name")

    if Enum.any?(create_state_options(payload), &(&1.state_name == state_name)) do
      errors
    else
      Map.put(errors, :state_name, "Choose a column.")
    end
  end

  defp require_nonempty(errors, form, field, key, message) do
    if string_value(form, field) == "", do: Map.put(errors, key, message), else: errors
  end

  defp create_project_options(%{board: %{project_options: projects}}) when is_list(projects) do
    Enum.filter(projects, &(is_binary(Map.get(&1, :id)) and is_binary(Map.get(&1, :name))))
  end

  defp create_project_options(%{board: %{project: project}}) when is_map(project), do: [project]
  defp create_project_options(_payload), do: []

  defp create_state_options(%{board: %{columns: columns}}) when is_list(columns), do: columns
  defp create_state_options(_payload), do: []

  defp default_create_project_id(payload) do
    board_project_id = get_in(payload, [:board, :project, :id])
    project_options = create_project_options(payload)

    if Enum.any?(project_options, &(&1.id == board_project_id)) do
      board_project_id
    else
      first_project_id(project_options)
    end
  end

  defp first_project_id([%{id: project_id} | _projects]), do: project_id
  defp first_project_id([]), do: nil

  defp default_create_state_name(payload, requested_state_name) do
    requested_state_name = normalize_optional_string(requested_state_name)

    cond do
      state_option?(payload, requested_state_name) ->
        requested_state_name

      state_option?(payload, "Suggested") ->
        "Suggested"

      true ->
        case create_state_options(payload) do
          [%{state_name: state_name} | _columns] -> state_name
          [] -> nil
        end
    end
  end

  defp state_option?(payload, state_name) when is_binary(state_name) do
    Enum.any?(create_state_options(payload), &(&1.state_name == state_name))
  end

  defp state_option?(_payload, _state_name), do: false

  defp string_value(form, key) do
    form
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

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

  @spec grouped_tasks([map()], String.t(), [String.t()]) :: [map()]
  defp grouped_tasks(tasks, "none", _collapsed_keys), do: [%{key: "all", label: nil, tasks: tasks, collapsed: false}]
  defp grouped_tasks([], _group_by, _collapsed_keys), do: []

  defp grouped_tasks(tasks, group_by, collapsed_keys) do
    groups =
      tasks
      |> Enum.map(&task_group(&1, group_by))
      |> Enum.uniq_by(& &1.key)

    Enum.map(groups, fn group ->
      group_tasks = Enum.filter(tasks, &(task_group(&1, group_by).key == group.key))

      group
      |> Map.put(:tasks, group_tasks)
      |> Map.put(:collapsed, group_collapsed?(collapsed_keys, group.key))
    end)
  end

  @spec group_collapsed?([String.t()], String.t()) :: boolean()
  defp group_collapsed?(collapsed_keys, group_key), do: group_key in collapsed_keys

  defp task_group(task, "project") do
    label = display_project_name(Map.get(task, :project_name), "No project")

    %{
      key: group_key("project", Map.get(task, :project_id), label),
      label: label
    }
  end

  defp task_group(task, "assignee") do
    label = Map.get(task, :assignee) || "Unassigned"

    %{
      key: group_key("assignee", label),
      label: label
    }
  end

  defp task_group(task, "priority") do
    priority = Map.get(task, :priority) || 5

    %{
      key: "priority:#{priority}",
      label: "P#{priority}"
    }
  end

  defp task_group(task, _group_by), do: task_group(task, "project")

  defp group_key("project", project_id, _label) when is_binary(project_id) and project_id != "",
    do: "project:#{project_id}"

  defp group_key("project", _project_id, label), do: group_key("project-name", label)

  defp group_key(prefix, label) do
    normalized =
      label
      |> to_string()
      |> String.trim()
      |> String.downcase()

    "#{prefix}:#{normalized}"
  end

  defp collapsed_group_keys(payload, group_by, column_state_name) do
    payload
    |> get_in([:board, :collapsed_groups])
    |> case do
      groups when is_list(groups) ->
        groups
        |> Enum.filter(&(Map.get(&1, :group_by) == group_by and Map.get(&1, :column_state_name) == column_state_name))
        |> Enum.map(&Map.get(&1, :group_key))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _groups ->
        []
    end
  end

  defp group_toggle_label(%{collapsed: true, label: label, tasks: tasks}) do
    "Expand #{label}, #{length(tasks)} #{issue_count_label(tasks)}"
  end

  defp group_toggle_label(%{label: label}), do: "Collapse #{label}"

  defp issue_count_label([_task]), do: "ticket"
  defp issue_count_label(_tasks), do: "tickets"

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

  defp blocked_reason(task) when is_map(task) do
    task
    |> Map.get(:blocked_reason)
    |> normalize_optional_string()
  end

  defp blocked_reason(_task), do: nil

  defp dependency_descendant_label(task) when is_map(task) do
    case downstream_dependency_count(task) do
      count when count > 0 -> "#{count} downstream"
      _count -> nil
    end
  end

  defp dependency_descendant_label(_task), do: nil

  defp dependency_descendant_title(task) when is_map(task) do
    "#{downstream_dependency_count(task)} downstream dependent tickets are blocked by this ticket or its descendants."
  end

  defp dependency_descendant_title(_task), do: nil

  defp downstream_dependency_count(task) when is_map(task) do
    case Map.get(task, :downstream_count) || Map.get(task, "downstream_count") do
      count when is_integer(count) -> count
      count when is_binary(count) -> parse_positive_integer(count)
      _count -> 0
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> 0
    end
  end

  defp visible_workpad_sections(%{workpad_sections: sections} = task) when is_list(sections) do
    Enum.reject(sections, &empty_optional_blockers_section?(&1, task))
  end

  defp visible_workpad_sections(_task), do: []

  defp empty_optional_blockers_section?(%{key: "blockers", items: [], text_lines: []}, task) do
    is_nil(blocked_reason(task))
  end

  defp empty_optional_blockers_section?(_section, _task), do: false

  defp agent_progress_subtitle(%{runtime_status: %{kind: "running"}}), do: "Codex app-server is actively working this task."
  defp agent_progress_subtitle(%{runtime_status: %{kind: "retrying"}}), do: "Work is queued for retry."
  defp agent_progress_subtitle(_task), do: "No live agent is attached right now."

  defp detail_chips(task) when is_map(task) do
    priority_chip =
      case Map.get(task, :priority) do
        priority when is_integer(priority) -> ["P#{priority}"]
        _priority -> []
      end

    priority_chip ++ Enum.take(visible_labels(Map.get(task, :labels)), 4)
  end

  defp task_blocker_refs(%{blockers: blockers}) when is_list(blockers) do
    blockers
    |> Enum.map(&normalize_task_ref/1)
    |> Enum.reject(&is_nil/1)
  end

  defp task_blocker_refs(_task), do: []

  defp normalize_task_ref(blocker) when is_map(blocker) do
    id = blocker |> map_value(:id) |> normalize_optional_string()

    if is_nil(id) do
      nil
    else
      %{
        id: id,
        identifier: blocker |> map_value(:identifier) |> normalize_optional_string() || short_task_identifier(id),
        title: blocker |> map_value(:title) |> normalize_optional_string() || "Blocked task",
        state: blocker |> map_value(:state) |> normalize_optional_string() || "No state"
      }
    end
  end

  defp normalize_task_ref(_blocker), do: nil

  defp show_move_to_todo?(task) when is_map(task) do
    normalize_state(Map.get(task, :state)) != "todo"
  end

  defp show_move_to_todo?(_task), do: false

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp short_task_identifier(task_id) when is_binary(task_id), do: "PM-" <> String.slice(task_id, 0, 8)

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

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

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
