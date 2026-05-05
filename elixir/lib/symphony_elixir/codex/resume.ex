defmodule SymphonyElixir.Codex.Resume do
  @moduledoc """
  Runs a non-interactive Codex `exec resume` turn against an existing session.
  """

  require Logger

  alias SymphonyElixir.Config

  @spec run(String.t(), Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def run(thread_id, workspace, prompt)
      when is_binary(thread_id) and is_binary(workspace) and is_binary(prompt) do
    output_file = Path.join(System.tmp_dir!(), "symphony-codex-resume-#{System.unique_integer([:positive])}.txt")

    try do
      do_run(thread_id, workspace, prompt, output_file)
    after
      File.rm(output_file)
    end
  end

  defp do_run(thread_id, workspace, prompt, output_file) do
    task =
      Task.async(fn ->
        System.cmd(
          "codex",
          [
            "exec",
            "resume",
            "--all",
            "--dangerously-bypass-approvals-and-sandbox",
            "-c",
            "shell_environment_policy.inherit=all",
            "-o",
            output_file,
            thread_id,
            "-"
          ],
          cd: workspace,
          input: prompt,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, Config.settings!().codex.turn_timeout_ms) do
      {:ok, {output, 0}} ->
        read_last_message(output_file, output)

      {:ok, {output, status}} ->
        {:error, {:codex_resume_failed, status, trim_output(output)}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:codex_resume_timeout, Config.settings!().codex.turn_timeout_ms}}
    end
  end

  defp read_last_message(output_file, fallback_output) do
    case File.read(output_file) do
      {:ok, body} ->
        case clean_string(body) do
          nil -> {:error, {:codex_resume_empty_response, trim_output(fallback_output)}}
          response -> {:ok, response}
        end

      {:error, reason} ->
        {:error, {:codex_resume_missing_output, reason, trim_output(fallback_output)}}
    end
  end

  defp trim_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 4_000)
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
