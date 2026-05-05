defmodule SymphonyElixir.CodexResumeIOTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.Resume
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  @moduletag :io
  @moduletag timeout: 360_000

  setup do
    workflow_root =
      Path.join(System.tmp_dir!(), "symphony-real-codex-resume-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")

    SymphonyElixir.TestSupport.write_workflow_file!(workflow_file,
      codex_turn_timeout_ms: 300_000
    )

    Workflow.set_workflow_file_path(workflow_file)

    if Process.whereis(WorkflowStore) do
      WorkflowStore.force_reload()
    end

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      File.rm_rf(workflow_root)
    end)

    :ok
  end

  test "resumes a real Codex session and captures the final assistant message" do
    session_id = clean_env("SYMPHONY_REAL_CODEX_RESUME_SESSION_ID")
    workspace = clean_env("SYMPHONY_REAL_CODEX_RESUME_WORKSPACE") || File.cwd!()

    if is_nil(session_id) do
      IO.puts("Skipping real Codex resume smoke; set SYMPHONY_REAL_CODEX_RESUME_SESSION_ID to enable it.")
    else
      token = "PITCHAI_RESUME_SMOKE_#{System.unique_integer([:positive])}"

      prompt = """
      This is a Symphony PR-review bridge smoke test.
      Reply with one concise sentence containing this exact token: #{token}
      Do not modify files, do not post to GitHub, and do not call external services.
      """

      assert {:ok, response} = Resume.run(session_id, workspace, prompt)
      assert response =~ token
    end
  end

  defp clean_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end
  end
end
