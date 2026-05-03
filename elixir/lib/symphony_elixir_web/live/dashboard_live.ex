defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="terminal-page">
      <div class="terminal-scroll" role="region" aria-label="Symphony status terminal">
        <div class="terminal-frame">
          <div class="terminal-topline">
            <div class="terminal-line terminal-title">
              <span class="terminal-rail">╭─</span>
              <span>SYMPHONY STATUS</span>
            </div>
          </div>

          <%= if @payload[:error] do %>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-error">Orchestrator snapshot unavailable</span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Reason:</span>
              <span class="terminal-error"><%= @payload.error.code %>: <%= @payload.error.message %></span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Next refresh:</span>
              <span class="terminal-cyan">live</span>
            </div>
            <div class="terminal-line terminal-title">
              <span class="terminal-rail">╰─</span>
            </div>
          <% else %>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Agents:</span>
              <span class="terminal-green"><%= @payload.counts.running %></span><span class="terminal-muted">/</span><span class="terminal-muted"><%= @payload.max_agents %></span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Throughput:</span>
              <span class="terminal-cyan">0 tps</span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Runtime:</span>
              <span class="terminal-magenta"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Tokens:</span>
              <span class="terminal-yellow">in <%= format_int(@payload.codex_totals.input_tokens) %></span>
              <span class="terminal-muted"> | </span>
              <span class="terminal-yellow">out <%= format_int(@payload.codex_totals.output_tokens) %></span>
              <span class="terminal-muted"> | </span>
              <span class="terminal-yellow">total <%= format_int(@payload.codex_totals.total_tokens) %></span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Rate Limits:</span>
              <span class="terminal-muted"><%= format_rate_limits(@payload.rate_limits) %></span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Project:</span>
              <span class="terminal-cyan"><%= @payload.tracker.label %></span>
            </div>
            <div class="terminal-line">
              <span class="terminal-rail">│</span>
              <span class="terminal-label">Next refresh:</span>
              <span class="terminal-cyan"><%= format_next_refresh(@payload.polling) %></span>
            </div>

            <div class="terminal-line terminal-section-title">
              <span class="terminal-rail">├─</span>
              <span>Running</span>
            </div>
            <div class="terminal-line"><span class="terminal-rail">│</span></div>

            <table class="terminal-table terminal-running-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>STAGE</th>
                  <th>PID</th>
                  <th>AGE / TURN</th>
                  <th>TOKENS</th>
                  <th>SESSION</th>
                  <th>EVENT</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.running}>
                  <td>
                    <span class="terminal-dot"></span>
                    <a class="terminal-link" href={"/api/v1/#{entry.issue_identifier}"}>
                      <%= entry.issue_identifier %>
                    </a>
                  </td>
                  <td class={stage_class(entry.state)}><%= entry.state || "unknown" %></td>
                  <td class="terminal-yellow"><%= entry.codex_app_server_pid || "n/a" %></td>
                  <td class="terminal-magenta"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                  <td class="terminal-yellow terminal-number"><%= format_int(entry.tokens.total_tokens) %></td>
                  <td class="terminal-cyan"><%= compact_session(entry.session_id) %></td>
                  <td class={event_class(entry.last_event)}><%= event_text(entry) %></td>
                </tr>
              </tbody>
            </table>

            <%= if @payload.running == [] do %>
              <div class="terminal-line">
                <span class="terminal-rail">│</span>
                <span class="terminal-indent terminal-muted">No active agents</span>
              </div>
              <div class="terminal-line"><span class="terminal-rail">│</span></div>
            <% else %>
              <div class="terminal-line"><span class="terminal-rail">│</span></div>
            <% end %>

            <div class="terminal-line terminal-section-title">
              <span class="terminal-rail">├─</span>
              <span>Backoff queue</span>
            </div>
            <div class="terminal-line"><span class="terminal-rail">│</span></div>

            <%= if @payload.retrying == [] do %>
              <div class="terminal-line">
                <span class="terminal-rail">│</span>
                <span class="terminal-indent terminal-muted">No queued retries</span>
              </div>
            <% else %>
              <div :for={entry <- @payload.retrying} class="terminal-line">
                <span class="terminal-rail">│</span>
                <span class="terminal-indent terminal-orange">↻</span>
                <a class="terminal-link terminal-error" href={"/api/v1/#{entry.issue_identifier}"}>
                  <%= entry.issue_identifier %>
                </a>
                <span class="terminal-yellow">attempt=<%= entry.attempt %></span>
                <span class="terminal-muted">in</span>
                <span class="terminal-cyan"><%= next_in_words(entry.due_in_ms) %></span>
                <span class="terminal-muted"><%= retry_error(entry.error) %></span>
              </div>
            <% end %>

            <div class="terminal-line terminal-title">
              <span class="terminal-rail">╰─</span>
            </div>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp load_payload do
    Presenter.dashboard_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(value) when is_float(value), do: value |> trunc() |> format_int()
  defp format_int(_value), do: "0"

  defp format_rate_limits(nil), do: "codex | primary n/a | secondary n/a | credits n/a"
  defp format_rate_limits(value), do: inspect(value, pretty: false, limit: 8)

  defp format_next_refresh(%{checking?: true}), do: "checking now..."

  defp format_next_refresh(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    seconds = div(max(due_in_ms, 0) + 999, 1000)
    "#{seconds}s"
  end

  defp format_next_refresh(_polling), do: "live"

  defp compact_session(nil), do: "n/a"

  defp compact_session(session_id) when is_binary(session_id) do
    if String.length(session_id) <= 16 do
      session_id
    else
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    end
  end

  defp event_text(entry) do
    entry.last_message || to_string(entry.last_event || "none")
  end

  defp retry_error(nil), do: ""
  defp retry_error(""), do: ""
  defp retry_error(error), do: "error=#{truncate_text(to_string(error), 120)}"

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(max(due_in_ms, 0), 1_000)
    millis = rem(max(due_in_ms, 0), 1_000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp stage_class(stage) do
    normalized = stage |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["active", "progress", "running"]) -> "terminal-green"
      String.contains?(normalized, ["rework", "blocked", "failed", "error"]) -> "terminal-error"
      String.contains?(normalized, ["ready", "todo", "queued"]) -> "terminal-cyan"
      true -> "terminal-blue"
    end
  end

  defp event_class(nil), do: "terminal-blue"
  defp event_class("codex/event/token_count"), do: "terminal-yellow"
  defp event_class("codex/event/task_started"), do: "terminal-green"
  defp event_class("turn_completed"), do: "terminal-magenta"
  defp event_class(_), do: "terminal-blue"

  defp truncate_text(value, max_length) when is_binary(value) and byte_size(value) > max_length do
    String.slice(value, 0, max_length - 1) <> "…"
  end

  defp truncate_text(value, _max_length), do: value

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
