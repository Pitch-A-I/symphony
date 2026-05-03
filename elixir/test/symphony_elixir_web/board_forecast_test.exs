defmodule SymphonyElixirWeb.BoardForecastTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.BoardForecast

  test "estimates milestone times from checklist progress and runtime age" do
    now = ~U[2026-05-03 10:00:00Z]

    {_state, forecast} =
      BoardForecast.update(
        BoardForecast.new_state(),
        [
          %{id: "task-1", identifier: "PM-1", done: 6, total: 12, runtime_seconds: 600},
          %{id: "task-2", identifier: "PM-2", done: 3, total: 6, runtime_seconds: 300},
          %{id: "task-3", identifier: "PM-3", done: 2, total: 4, runtime_seconds: 200}
        ],
        now
      )

    assert forecast.running_count == 3
    assert forecast.measured_count == 3
    assert forecast.throughput_items_per_minute > 0
    assert Enum.find(forecast.milestones, &(&1.count == 3)).eta_at == ~U[2026-05-03 10:10:00Z]
    assert Enum.find(forecast.milestones, &(&1.count == 5)).eta_at == nil
  end

  test "smooths changing speed against previous measurements" do
    first_seen_at = ~U[2026-05-03 10:00:00Z]
    second_seen_at = ~U[2026-05-03 10:05:00Z]

    {state, first_forecast} =
      BoardForecast.update(
        BoardForecast.new_state(),
        [%{id: "task-1", identifier: "PM-1", done: 3, total: 9, runtime_seconds: 60}],
        first_seen_at
      )

    {next_state, second_forecast} =
      BoardForecast.update(
        state,
        [%{id: "task-1", identifier: "PM-1", done: 4, total: 9, runtime_seconds: 360}],
        second_seen_at
      )

    first_speed = first_forecast.entries |> List.first() |> Map.fetch!(:speed_items_per_second)
    second_speed = second_forecast.entries |> List.first() |> Map.fetch!(:speed_items_per_second)

    assert Map.has_key?(next_state, "task-1")
    assert second_speed < first_speed
    assert second_speed > 0
  end

  test "waits for measurable progress before estimating completion" do
    {_state, forecast} =
      BoardForecast.update(
        BoardForecast.new_state(),
        [%{id: "task-1", identifier: "PM-1", done: 0, total: 9, runtime_seconds: 600}],
        ~U[2026-05-03 10:00:00Z]
      )

    assert forecast.running_count == 1
    assert forecast.measured_count == 0
    assert Enum.all?(forecast.milestones, &is_nil(&1.eta_at))
  end
end
