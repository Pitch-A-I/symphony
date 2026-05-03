defmodule SymphonyElixir.PitchAIPM.BlockerReconcilerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PitchAIPM.BlockerReconciler

  test "groups semantically equivalent external validation blockers per project" do
    groups =
      [
        %{
          id: "task-a",
          identifier: "PM-A",
          title: "Validate flow A",
          project_id: "project-1",
          project_name: "Repo: app",
          blocked_reason: "Blocked: uv cannot reach PyPI because DNS fails."
        },
        %{
          id: "task-b",
          identifier: "PM-B",
          title: "Validate flow B",
          project_id: "project-1",
          project_name: "Repo: app",
          blocked_reason: "Blocked after implementation: psycopg cannot open outbound sockets to Postgres."
        }
      ]
      |> BlockerReconciler.group_blocked_tasks()

    assert [
             %{
               blocker_key: "external-validation-access",
               project_id: "project-1",
               tasks: [%{identifier: "PM-A"}, %{identifier: "PM-B"}]
             }
           ] = groups
  end

  test "extracts blocker reason from workpad when no blocker comment exists" do
    task = %{
      id: "task-a",
      identifier: "PM-A",
      project_id: "project-1",
      workpad_body: """
      ## Codex Workpad

      ### Plan

      - [x] Inspect workspace

      ### Blockers

      - True blocker: no application source files are present in the provided workspace.

      ### Notes

      - unrelated
      """
    }

    enriched = BlockerReconciler.enrich_blocked_task(task)

    assert enriched.blocker_key == "source-checkout-missing"
    assert enriched.blocker_reason == "True blocker: no application source files are present in the provided workspace."
  end
end
