defmodule SymphonyElixir.Codex.Resume do
  @moduledoc """
  Runs a non-interactive Codex `exec resume` turn against an existing session.
  """

  require Logger

  alias SymphonyElixir.Config

  @spec run(String.t(), Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def run(thread_id, workspace, prompt)
      when is_binary(thread_id) and is_binary(workspace) and is_binary(prompt) do
    temp_dir = Path.join(System.tmp_dir!(), "symphony-codex-resume-#{System.unique_integer([:positive])}")
    output_file = Path.join(temp_dir, "last-message.txt")
    prompt_file = Path.join(temp_dir, "prompt.txt")

    try do
      with :ok <- prepare_temp_dir(temp_dir),
           :ok <- write_prompt_file(prompt_file, prompt) do
        do_run(thread_id, workspace, output_file, prompt_file)
      end
    after
      File.rm_rf(temp_dir)
    end
  end

  defp do_run(thread_id, workspace, output_file, prompt_file) do
    task =
      Task.async(fn ->
        System.cmd(
          "sh",
          [
            "-c",
            """
            exec codex exec resume --all --dangerously-bypass-approvals-and-sandbox \
            -c shell_environment_policy.inherit=all \
            -o "$1" "$2" - < "$3"
            """,
            "symphony-codex-resume",
            output_file,
            thread_id,
            prompt_file
          ],
          cd: workspace,
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

  defp write_prompt_file(prompt_file, prompt) do
    with :ok <- File.write(prompt_file, prompt),
         :ok <- File.chmod(prompt_file, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:codex_resume_prompt_file_failed, reason}}
    end
  end

  defp prepare_temp_dir(temp_dir) do
    with :ok <- File.mkdir(temp_dir),
         :ok <- File.chmod(temp_dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:codex_resume_temp_dir_failed, reason}}
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
