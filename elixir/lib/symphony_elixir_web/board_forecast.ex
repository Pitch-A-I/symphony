defmodule SymphonyElixirWeb.BoardForecast do
  @moduledoc """
  Estimates completion times for active board agents from checklist progress.
  """

  @milestones [3, 5, 10, 20]
  @minimum_elapsed_seconds 15
  @previous_weight 0.65
  @observed_weight 1.0 - @previous_weight
  @lifetime_weight 0.7
  @instant_weight 1.0 - @lifetime_weight

  @type progress_entry :: %{
          required(:id) => String.t(),
          required(:identifier) => String.t(),
          required(:done) => non_neg_integer(),
          required(:total) => non_neg_integer(),
          optional(:started_at) => String.t() | nil,
          optional(:runtime_seconds) => number() | nil
        }

  @type state :: %{optional(String.t()) => map()}

  @spec new_state() :: state()
  def new_state, do: %{}

  @spec update(state(), [progress_entry()], DateTime.t()) :: {state(), map()}
  def update(previous_state, progress_entries, %DateTime{} = now)
      when is_map(previous_state) and is_list(progress_entries) do
    measurements =
      progress_entries
      |> Enum.map(&measure_progress(&1, previous_state, now))
      |> Enum.reject(&is_nil/1)

    next_state =
      measurements
      |> Map.new(fn measurement -> {measurement.id, Map.drop(measurement, [:eta_at, :remaining])} end)

    {next_state, forecast(measurements, length(progress_entries))}
  end

  defp measure_progress(%{id: id, done: done, total: total} = entry, previous_state, now)
       when is_binary(id) and is_integer(done) and is_integer(total) and total >= 0 and done >= 0 do
    done = min(done, total)
    previous = Map.get(previous_state, id)
    elapsed_seconds = elapsed_seconds(entry, now)
    observed_speed = observed_speed(%{entry | done: done}, previous, elapsed_seconds, now)
    speed = smoothed_speed(observed_speed, previous)
    remaining = max(total - done, 0)
    eta_at = eta_at(now, remaining, speed)

    %{
      id: id,
      identifier: Map.get(entry, :identifier, id),
      title: Map.get(entry, :title),
      done: done,
      total: total,
      remaining: remaining,
      last_seen_at: now,
      speed_items_per_second: speed,
      eta_at: eta_at
    }
  end

  defp measure_progress(_entry, _previous_state, _now), do: nil

  defp observed_speed(%{done: done}, _previous, elapsed_seconds, _now)
       when elapsed_seconds < @minimum_elapsed_seconds or done == 0 do
    nil
  end

  defp observed_speed(%{done: done} = entry, previous, elapsed_seconds, now) do
    lifetime_speed = done / elapsed_seconds
    instant_speed = instant_speed(entry, previous, now)

    case instant_speed do
      speed when is_number(speed) -> lifetime_speed * @lifetime_weight + speed * @instant_weight
      nil -> lifetime_speed
    end
  end

  defp instant_speed(%{done: done}, %{done: previous_done, last_seen_at: %DateTime{} = last_seen_at}, now)
       when is_integer(previous_done) do
    seconds = DateTime.diff(now, last_seen_at, :second)

    if seconds >= @minimum_elapsed_seconds do
      max(done - previous_done, 0) / seconds
    end
  end

  defp instant_speed(_entry, _previous, _now), do: nil

  defp smoothed_speed(nil, %{speed_items_per_second: previous_speed}) when is_number(previous_speed), do: previous_speed
  defp smoothed_speed(nil, _previous), do: nil
  defp smoothed_speed(observed_speed, nil), do: observed_speed

  defp smoothed_speed(observed_speed, %{speed_items_per_second: previous_speed}) when is_number(previous_speed) do
    previous_speed * @previous_weight + observed_speed * @observed_weight
  end

  defp smoothed_speed(observed_speed, _previous), do: observed_speed

  defp eta_at(_now, remaining, _speed) when remaining <= 0, do: nil
  defp eta_at(_now, _remaining, nil), do: nil
  defp eta_at(_now, _remaining, speed) when speed <= 0, do: nil

  defp eta_at(now, remaining, speed) do
    DateTime.add(now, ceil(remaining / speed), :second)
  end

  defp elapsed_seconds(%{runtime_seconds: seconds}, _now) when is_integer(seconds) and seconds > 0, do: seconds
  defp elapsed_seconds(%{runtime_seconds: seconds}, _now) when is_float(seconds) and seconds > 0, do: seconds

  defp elapsed_seconds(%{started_at: started_at}, now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started_at, _offset} -> max(DateTime.diff(now, started_at, :second), 0)
      {:error, _reason} -> 0
    end
  end

  defp elapsed_seconds(_entry, _now), do: 0

  defp forecast(measurements, running_count) do
    measured =
      measurements
      |> Enum.filter(&measured?/1)
      |> Enum.sort_by(&DateTime.to_unix(&1.eta_at))

    %{
      running_count: running_count,
      measured_count: length(measured),
      throughput_items_per_minute: throughput_items_per_minute(measured),
      milestones: milestones(measured),
      entries: measured
    }
  end

  defp measured?(%{eta_at: %DateTime{}, speed_items_per_second: speed}) when is_number(speed) and speed > 0,
    do: true

  defp measured?(_measurement), do: false

  defp throughput_items_per_minute(measured) do
    measured
    |> Enum.map(& &1.speed_items_per_second)
    |> Enum.sum()
    |> Kernel.*(60)
  end

  defp milestones(measured) do
    Enum.map(@milestones, fn count ->
      %{
        count: count,
        eta_at: nth_eta_at(measured, count)
      }
    end)
  end

  defp nth_eta_at(measured, count) do
    measured
    |> Enum.at(count - 1)
    |> case do
      %{eta_at: eta_at} -> eta_at
      nil -> nil
    end
  end
end
