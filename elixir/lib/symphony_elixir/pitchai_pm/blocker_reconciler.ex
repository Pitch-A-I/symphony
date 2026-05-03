defmodule SymphonyElixir.PitchAIPM.BlockerReconciler do
  @moduledoc false

  @missing_reason "Blocked without a recorded reason."
  @missing_reason_key "missing-blocker-reason"
  @summary_limit 140
  @stop_words MapSet.new(~w[
    a after an and are as at be by can cannot could for from has have in into is it its no not of on or
    the this to was were when with without
  ])

  @type blocked_task :: map()
  @type blocker_group :: %{
          project_id: String.t(),
          project_name: String.t() | nil,
          blocker_key: String.t(),
          summary: String.t(),
          reason_samples: [String.t()],
          tasks: [blocked_task()]
        }

  @spec group_blocked_tasks([blocked_task()]) :: [blocker_group()]
  def group_blocked_tasks(tasks) when is_list(tasks) do
    tasks
    |> Enum.map(&enrich_blocked_task/1)
    |> Enum.reject(&(value(&1, :project_id) in [nil, ""]))
    |> Enum.group_by(&{value(&1, :project_id), value(&1, :blocker_key)})
    |> Enum.map(&group_from_tasks/1)
    |> Enum.sort_by(&{&1.project_name || "", &1.blocker_key})
  end

  @spec enrich_blocked_task(blocked_task()) :: blocked_task()
  def enrich_blocked_task(task) when is_map(task) do
    reason = blocker_reason(task)

    task
    |> Map.put(:blocker_reason, reason)
    |> Map.put(:blocker_key, blocker_key(reason))
  end

  @spec blocker_reason(blocked_task()) :: String.t()
  def blocker_reason(task) when is_map(task) do
    clean_string(value(task, :blocked_reason)) ||
      workpad_blocker_reason(value(task, :workpad_body)) ||
      @missing_reason
  end

  @spec blocker_key(String.t()) :: String.t()
  def blocker_key(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    cond do
      contains_any?(normalized, ["no application source files", "source checkout", "provided workspace is empty"]) ->
        "source-checkout-missing"

      contains_any?(normalized, [
        "pypi",
        "dns",
        "postgres",
        "permissionerror",
        "psycopg",
        "outbound socket",
        "outbound sockets",
        "operation not permitted"
      ]) ->
        "external-validation-access"

      contains_any?(normalized, ["auth", "credential", "permission denied", "secret", "token"]) ->
        "missing-auth-or-permission"

      true ->
        compact_reason_key(reason)
    end
  end

  @spec summary(String.t()) :: String.t()
  def summary(reason) when is_binary(reason) do
    reason
    |> strip_blocker_prefix()
    |> normalize_space()
    |> truncate(@summary_limit)
  end

  @spec task_descriptor(blocked_task()) :: map()
  def task_descriptor(task) when is_map(task) do
    %{
      "id" => value(task, :id),
      "identifier" => value(task, :identifier),
      "title" => value(task, :title),
      "project_id" => value(task, :project_id),
      "project_name" => value(task, :project_name)
    }
  end

  defp group_from_tasks({{project_id, blocker_key}, tasks}) do
    [first_task | _rest] = tasks
    reasons = tasks |> Enum.map(&value(&1, :blocker_reason)) |> unique_strings()
    first_reason = List.first(reasons) || @missing_reason

    %{
      project_id: project_id,
      project_name: value(first_task, :project_name),
      blocker_key: blocker_key,
      summary: summary(first_reason),
      reason_samples: Enum.take(reasons, 3),
      tasks: Enum.sort_by(tasks, &(value(&1, :identifier) || value(&1, :id) || ""))
    }
  end

  defp workpad_blocker_reason(body) when is_binary(body) do
    case Regex.run(~r/^\s*###\s+Blockers\s*\n(?<section>.*?)(?=^\s*###\s+|\z)/ims, body, capture: :all_names) do
      [section] ->
        section
        |> String.split("\n")
        |> Enum.find_value(&clean_blocker_line/1)

      _no_blockers_section ->
        nil
    end
  end

  defp workpad_blocker_reason(_body), do: nil

  defp clean_blocker_line(line) when is_binary(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\s*[-*]\s*(?:\[[ xX]\]\s*)?/, "")
    |> clean_string()
  end

  defp contains_any?(value, needles) do
    Enum.any?(needles, &String.contains?(value, &1))
  end

  defp compact_reason_key(reason) do
    words =
      reason
      |> String.downcase()
      |> String.replace(~r/`[^`]+`/, " code ")
      |> String.replace(~r/https?:\/\/\S+/, " url ")
      |> String.replace(~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i, " uuid ")
      |> String.replace(~r/\bpm-[0-9a-f]{6,}\b/i, " task ")
      |> String.replace(~r/\/[^\s`'")]+/, " path ")
      |> String.replace(~r/\b\d+(?:\.\d+)?\b/, " number ")
      |> String.replace(~r/[^a-z0-9]+/, " ")
      |> String.split()
      |> Enum.reject(&MapSet.member?(@stop_words, &1))
      |> Enum.uniq()
      |> Enum.take(14)

    case words do
      [] -> @missing_reason_key
      values -> Enum.join(values, "-")
    end
  end

  defp strip_blocker_prefix(reason) do
    String.replace(
      reason,
      ~r/^\s*(blocked(?:\s+(?:after implementation|in unattended symphony session))?|true blocker)\s*:\s*/i,
      ""
    )
  end

  defp unique_strings(values) do
    values
    |> Enum.map(&clean_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_space(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(value, limit) when byte_size(value) <= limit, do: value

  defp truncate(value, limit) do
    value
    |> binary_part(0, limit)
    |> String.replace(~r/\s+\S*$/, "")
    |> Kernel.<>("...")
  end

  defp value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean_string(nil), do: nil
  defp clean_string(value), do: value |> to_string() |> clean_string()
end
