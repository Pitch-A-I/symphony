defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule FakePitchAIPMClient do
    def reconcile_blocked_tasks do
      {:ok,
       %{
         groups: 0,
         blocked_tasks: 0,
         created_blocker_tasks: 0,
         reopened_blocker_tasks: 0,
         merged_duplicate_blocker_tasks: 0,
         linked_dependencies: 0,
         created_reconciliation_agent_tasks: 0,
         updated_reconciliation_agent_tasks: 0,
         skipped_reconciliation_agent_tasks: 0,
         blocker_task_ids: [],
         reconciliation_agent_task_ids: []
       }}
    end

    def set_board_group_collapsed(group_by, column_state_name, group_key, collapsed?) do
      if recipient = Application.get_env(:symphony_elixir, :pitchai_pm_test_recipient) do
        send(recipient, {:pitchai_pm_set_board_group_collapsed, group_by, column_state_name, group_key, collapsed?})
      end

      :ok
    end

    def move_issue_on_board(task_id, state_name, opts) do
      if recipient = Application.get_env(:symphony_elixir, :pitchai_pm_test_recipient) do
        send(recipient, {:pitchai_pm_move_issue_on_board, task_id, state_name, opts})
      end

      :ok
    end

    def board_snapshot do
      {:ok,
       %{
         project: %{id: "project-pm", name: "TODO App"},
         collapsed_groups: Application.get_env(:symphony_elixir, :pitchai_pm_fake_collapsed_groups, []),
         project_options: [
           %{id: "project-pm", name: "TODO App"},
           %{id: "project-driestar", name: "Driestar — AI Pilot Regie (Formatief Toetsen)"}
         ],
         task_limit_per_column: 12,
         columns: [
           %{
             state_name: "Suggested",
             color: "#8b5cf6",
             task_count: 1,
             hidden?: false,
             tasks: [
               %{
                 id: "issue-suggested",
                 identifier: "MT-SUG",
                 title: "Summarize feedback from Slack",
                 state: "Suggested",
                 value_name: "Task",
                 project_id: "project-pm",
                 project_name: "TODO App",
                 assignee: nil,
                 priority: 4,
                 rank: 1024.0,
                 labels: ["demo"],
                 branch_name: nil,
                 url: "",
                 updated_at: "2026-05-02T12:00:00Z",
                 created_at: "2026-05-01T12:00:00Z",
                 comment_count: 1,
                 downstream_count: 3,
                 pr_count: 0,
                 workpad_updated_at: nil
               }
             ]
           },
           %{
             state_name: "Todo",
             color: "#9ca3af",
             task_count: 1,
             hidden?: false,
             tasks: [
               %{
                 id: "issue-todo",
                 identifier: "MT-890",
                 title: "Upgrade to latest React version",
                 state: "Todo",
                 value_name: "Task",
                 project_id: "project-pm",
                 project_name: "TODO App",
                 assignee: nil,
                 priority: 5,
                 rank: 1024.0,
                 labels: [],
                 branch_name: nil,
                 url: "",
                 updated_at: "2026-05-02T12:00:00Z",
                 created_at: "2026-05-01T12:00:00Z",
                 comment_count: 0,
                 downstream_count: 0,
                 pr_count: 0,
                 workpad_updated_at: nil
               }
             ]
           },
           %{
             state_name: "In Progress",
             color: "#facc15",
             task_count: 1,
             hidden?: false,
             tasks: [
               %{
                 id: "issue-http",
                 identifier: "MT-HTTP",
                 title: "Dispatch active PM task",
                 state: "In Progress",
                 value_name: "Task",
                 project_id: "project-pm",
                 project_name: "TODO App",
                 assignee: "symphony",
                 priority: 3,
                 rank: 1024.0,
                 labels: [],
                 branch_name: nil,
                 url: "",
                 updated_at: "2026-05-02T12:00:00Z",
                 created_at: "2026-05-01T12:00:00Z",
                 comment_count: 0,
                 downstream_count: 0,
                 pr_count: 0,
                 workpad_updated_at: nil
               }
             ]
           },
           %{
             state_name: "Blocked",
             color: "#64748b",
             task_count: 1,
             hidden?: false,
             tasks: [
               %{
                 id: "issue-blocked",
                 identifier: "MT-BLOCK",
                 title: "Blocked source checkout task",
                 state: "Blocked",
                 value_name: "Task",
                 project_id: "project-pm",
                 project_name: "TODO App",
                 assignee: "symphony",
                 priority: 2,
                 rank: 1024.0,
                 labels: [],
                 branch_name: nil,
                 url: "",
                 updated_at: "2026-05-02T13:00:00Z",
                 created_at: "2026-05-01T13:00:00Z",
                 comment_count: 1,
                 downstream_count: 0,
                 blocked_reason: "No application source files are present in the provided workspace.",
                 pr_count: 0,
                 workpad_updated_at: "2026-05-02T13:00:00Z"
               }
             ]
           },
           %{
             state_name: "Human Review",
             color: "#e85d8e",
             task_count: 0,
             hidden?: false,
             tasks: []
           }
         ],
         hidden_columns: [
           %{state_name: "Rework", color: "#dc2626", task_count: 0, hidden?: true, tasks: []},
           %{state_name: "Merging", color: "#059669", task_count: 0, hidden?: true, tasks: []},
           %{state_name: "Done", color: "#6366f1", task_count: 12, hidden?: true, tasks: []}
         ]
       }}
    end

    def task_detail("issue-http") do
      {:ok,
       %{
         id: "issue-http",
         identifier: "MT-HTTP",
         title: "Dispatch active PM task",
         description: %{"request" => "Render agent progress like the Symphony demo."},
         state: "In Progress",
         value_name: "Task",
         rank: 1024.0,
         priority: 3,
         labels: ["symphony"],
         branch_name: "feature/detail-modal",
         url: "",
         assignee: "symphony",
         repo_full_name: "pitchai/dispatch",
         repo_url: "https://example.invalid/pitchai/dispatch",
         workspace_path: "/tmp/workspaces/MT-HTTP",
         tracking_metadata: %{},
         project: %{id: "project-pm", name: "TODO App"},
         workpad: %{
           body: """
           ## Codex Workpad

           ### Plan

           - [x] 1. Inspect the current board
             - [x] 1.1 Locate the LiveView card renderer
           - [ ] 2. Add a task detail modal
             - [ ] 2.1 Render nested checkboxes

           ### Acceptance Criteria

           - [x] Opening a card shows details
           - [ ] Agent progress is visible

           ### Validation

           - [ ] Run LiveView tests

           ### Notes

           - Keep the interaction close to the Symphony demo.
           """,
           updated_at: "2026-05-02T12:00:00Z"
         },
         comments: [],
         prs: [],
         state_events: [
           %{
             "from_state" => "Todo",
             "to_state" => "In Progress",
             "actor" => "symphony",
             "reason" => "dispatch",
             "created_at" => "2026-05-02T12:00:00Z"
           }
         ],
         blockers: [],
         created_at: "2026-05-01T12:00:00Z",
         updated_at: "2026-05-02T12:00:00Z"
       }}
    end

    def task_detail("issue-blocked") do
      {:ok,
       %{
         id: "issue-blocked",
         identifier: "MT-BLOCK",
         title: "Blocked source checkout task",
         description: %{"request" => "Fix the task once a source checkout exists."},
         state: "Blocked",
         value_name: "Task",
         rank: 1024.0,
         priority: 2,
         labels: ["symphony"],
         branch_name: nil,
         url: "",
         assignee: "symphony",
         repo_full_name: "pitchai/dispatch",
         repo_url: "https://example.invalid/pitchai/dispatch",
         workspace_path: "/tmp/workspaces/MT-BLOCK",
         tracking_metadata: %{},
         project: %{id: "project-pm", name: "TODO App"},
         workpad: %{
           body: """
           ## Codex Workpad

           ### Plan

           - [x] 1. Inspect workspace

           ### Blockers

           - True blocker: no application source files are present in the provided workspace.
           """,
           updated_at: "2026-05-02T13:00:00Z"
         },
         comments: [
           %{
             "body" => "Workspace was bootstrapped after the blocker was recorded.",
             "author" => "symphony",
             "kind" => "comment",
             "created_at" => "2026-05-02T13:05:00Z"
           },
           %{
             "body" => "Blocked in unattended Symphony session: no application source files are present in the provided workspace.",
             "author" => "symphony",
             "kind" => "comment",
             "created_at" => "2026-05-02T13:00:00Z"
           }
         ],
         prs: [],
         state_events: [
           %{
             "from_state" => "In Progress",
             "to_state" => "Blocked",
             "actor" => "symphony",
             "reason" => "tool_update_task_state",
             "created_at" => "2026-05-02T13:00:00Z"
           }
         ],
         blockers: [
           %{
             "id" => "issue-suggested",
             "identifier" => "MT-SUG",
             "title" => "Summarize feedback from Slack",
             "state" => "Suggested"
           }
         ],
         created_at: "2026-05-01T13:00:00Z",
         updated_at: "2026-05-02T13:00:00Z"
       }}
    end

    def task_detail(_task_id), do: {:error, :task_not_found}

    def create_board_task(params) do
      if recipient = Application.get_env(:symphony_elixir, :pitchai_pm_test_recipient) do
        send(recipient, {:pitchai_pm_create_board_task, params})
      end

      {:ok,
       %{
         id: "created-ticket",
         identifier: "PM-CREATED",
         title: params["name"],
         description: params["description"],
         state: params["state_name"],
         value_name: "Task",
         rank: nil,
         priority: nil,
         labels: [],
         branch_name: nil,
         url: "",
         assignee: nil,
         repo_full_name: nil,
         repo_url: nil,
         workspace_path: nil,
         tracking_metadata: %{},
         project: %{id: params["project_id"], name: "TODO App"},
         workpad: %{body: nil, updated_at: nil},
         comments: [],
         prs: [],
         state_events: [],
         blockers: [],
         created_at: "2026-05-03T12:00:00Z",
         updated_at: "2026-05-03T12:00:00Z"
       }}
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      if recipient = Keyword.get(state, :recipient) do
        send(recipient, :snapshot_requested)
      end

      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    pitchai_pm_client_module = Application.get_env(:symphony_elixir, :pitchai_pm_client_module)
    pitchai_pm_test_recipient = Application.get_env(:symphony_elixir, :pitchai_pm_test_recipient)
    pitchai_pm_fake_collapsed_groups = Application.get_env(:symphony_elixir, :pitchai_pm_fake_collapsed_groups)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      if is_nil(pitchai_pm_client_module) do
        Application.delete_env(:symphony_elixir, :pitchai_pm_client_module)
      else
        Application.put_env(:symphony_elixir, :pitchai_pm_client_module, pitchai_pm_client_module)
      end

      if is_nil(pitchai_pm_test_recipient) do
        Application.delete_env(:symphony_elixir, :pitchai_pm_test_recipient)
      else
        Application.put_env(:symphony_elixir, :pitchai_pm_test_recipient, pitchai_pm_test_recipient)
      end

      if is_nil(pitchai_pm_fake_collapsed_groups) do
        Application.delete_env(:symphony_elixir, :pitchai_pm_fake_collapsed_groups)
      else
        Application.put_env(:symphony_elixir, :pitchai_pm_fake_collapsed_groups, pitchai_pm_fake_collapsed_groups)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "plan" => [],
                 "recent_events" => [],
                 "runtime_seconds" => nil,
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "plan" => [],
               "recent_events" => [],
               "runtime_seconds" => nil,
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)
    Application.put_env(:symphony_elixir, :pitchai_pm_client_module, FakePitchAIPMClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "pitchai_pm",
      tracker_project_id: "project-pm",
      tracker_database_url: "postgresql://postgres:postgres@127.0.0.1:5432/test"
    )

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "Hooks.ModalScrollLock"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css_conn = get(build_conn(), "/dashboard.css")
    assert Plug.Conn.get_resp_header(dashboard_css_conn, "cache-control") == ["no-store"]

    dashboard_css = response(dashboard_css_conn, 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ "body.has-modal-open"
    assert dashboard_css =~ ".board-columns"
    assert dashboard_css =~ ".ticket-card"
    assert dashboard_css =~ ".ticket-blocked-reason"
    assert dashboard_css =~ ".dependency-badge"
    assert dashboard_css =~ ".group-chevron"
    assert dashboard_css =~ ".issue-group-count"
    assert dashboard_css =~ ".blocked-reason-panel"
    assert dashboard_css =~ ".state-spinner"
    assert dashboard_css =~ ".drag-placeholder"
    assert dashboard_css =~ ".is-drag-origin-card"
    assert dashboard_css =~ ".detail-modal"
    assert dashboard_css =~ "width: min(88rem, calc(100vw - 1.8rem))"
    assert dashboard_css =~ "max-height: calc(100dvh - 1.5rem)"
    assert dashboard_css =~ "overflow-y: auto"
    assert dashboard_css =~ ".checklist-item"
    assert dashboard_css =~ ".runtime-events"
    assert dashboard_css =~ "scrollbar-gutter: stable"
    assert dashboard_css =~ ".terminal-frame"
    assert dashboard_css =~ ".terminal-running-table"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "kanban board liveview renders PM ticket columns" do
    orchestrator_name = Module.concat(__MODULE__, :BoardOrchestrator)
    Application.put_env(:symphony_elixir, :pitchai_pm_client_module, FakePitchAIPMClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "pitchai_pm",
      tracker_project_id: "project-pm",
      tracker_database_url: "postgresql://postgres:postgres@127.0.0.1:5432/test"
    )

    snapshot =
      static_snapshot()
      |> Map.update!(:running, fn [running | rest] ->
        [
          Map.put(running, :recent_codex_events, [
            %{
              event: :notification,
              timestamp: DateTime.utc_now(),
              method: "codex/event/agent_message_delta",
              message: "assistant draft: grouped canonical blocker update",
              stream_kind: "assistant_message",
              stream_text: "grouped canonical blocker update",
              stream_delta_count: 4
            }
          ])
          | rest
        ]
      end)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    refute html =~ "TODO App / Issues"
    assert html =~ "Agent completion forecast"
    assert html =~ "1 active - ETA learning"
    assert html =~ "3: --"
    assert html =~ "Group"
    assert html =~ "Project"
    assert html =~ "issue-group-label"
    assert html =~ "group-chevron"
    assert html =~ "Suggested"
    refute html =~ "Backlog"
    assert html =~ "Todo"
    assert html =~ "In Progress"
    assert html =~ "Human Review"
    assert html =~ "TODO App"
    assert html =~ "MT-BLOCK"
    assert html =~ "3 downstream"
    assert html =~ "ticket-blocked-reason"
    assert html =~ "No application source files are present in the provided workspace."
    refute html =~ "Hidden columns"
    refute html =~ "Rework"
    refute html =~ "Merging"
    refute html =~ "Done"
    assert html =~ "state-spinner"
    assert html =~ "data-drop-state=\"Todo\""
    assert html =~ "MT-HTTP"
    assert html =~ "Dispatch active PM task"
    refute html =~ ">Active<"
    refute html =~ "runtime-badge running"
    assert html =~ "MT-890"
    refute html =~ "SYMPHONY STATUS"

    Application.put_env(:symphony_elixir, :pitchai_pm_test_recipient, self())

    render_click(view, "toggle_issue_group", %{
      "group_by" => "project",
      "column_state_name" => "Suggested",
      "group_key" => "project:project-pm",
      "collapsed" => "true"
    })

    assert_receive {:pitchai_pm_set_board_group_collapsed, "project", "Suggested", "project:project-pm", true}

    create_modal = render_click(view, "open_create_task", %{"state_name" => "Todo"})
    assert create_modal =~ "New ticket"
    assert create_modal =~ "Driestar — AI Pilot Regie"
    assert create_modal =~ ~r/<option[^>]+value="Todo"[^>]+selected/

    created_html =
      render_submit(view, "create_task", %{
        "task" => %{
          "project_id" => "project-pm",
          "state_name" => "Todo",
          "name" => "New board-created ticket",
          "prompt" => "Use the board create form to capture implementation instructions."
        }
      })

    assert_receive {:pitchai_pm_create_board_task,
                    %{
                      "project_id" => "project-pm",
                      "state_name" => "Todo",
                      "name" => "New board-created ticket",
                      "description" => %{
                        "request" => "Use the board create form to capture implementation instructions."
                      },
                      "value_name" => "Task"
                    }}

    assert created_html =~ "New board-created ticket"
    assert created_html =~ "Use the board create form to capture implementation instructions."
    refute created_html =~ "detail-chip\">Task"

    hidden_html = render_click(view, "toggle_hidden_columns")
    assert hidden_html =~ "Hidden columns"
    assert hidden_html =~ "Rework"
    assert hidden_html =~ "Merging"
    assert hidden_html =~ "Done"

    detail = render_click(view, "open_task", %{"task_id" => "issue-http"})
    assert detail =~ "phx-hook=\"ModalScrollLock\""
    assert detail =~ "tabindex=\"-1\""
    assert detail =~ "Agent progress"
    assert detail =~ "Checklist"
    refute detail =~ "detail-status-pill"
    refute detail =~ "detail-chip\">Task"
    assert detail =~ "detail-chip\">P3"
    refute detail =~ "detail-chip\">symphony"
    assert detail =~ "Recent app-server events"
    assert detail =~ "assistant draft: grouped canonical blocker update"
    refute detail =~ "agent message streaming: grouped"
    assert detail =~ "Render agent progress like the Symphony demo."
    assert detail =~ "Inspect the current board"
    assert detail =~ "Render nested checkboxes"
    assert detail =~ "Acceptance Criteria"
    assert detail =~ "State history"

    blocked_detail = render_click(view, "open_task", %{"task_id" => "issue-blocked"})
    assert blocked_detail =~ "blocked-reason-panel"
    assert blocked_detail =~ "Blocked in unattended Symphony session"
    refute blocked_detail =~ "Workspace was bootstrapped"
    assert blocked_detail =~ "Blockers"
    assert blocked_detail =~ "Blocked by"
    assert blocked_detail =~ "MT-SUG"
    assert blocked_detail =~ "Move to Todo"

    Application.put_env(:symphony_elixir, :pitchai_pm_test_recipient, self())
    render_hook(view, "move_task", %{"task_id" => "issue-todo", "target_state" => "Human Review"})

    assert_receive {:pitchai_pm_move_issue_on_board, "issue-todo", "Human Review", %{after_task_id: nil, before_task_id: nil, reason: "kanban_drag_drop"}}

    render_click(view, "move_task_to_todo", %{"task_id" => "issue-blocked"})

    assert_receive {:pitchai_pm_move_issue_on_board, "issue-blocked", "Todo", %{reason: "modal_move_to_todo"}}

    render_click(view, "focus_task_card", %{"task_id" => "issue-suggested"})
    assert_push_event(view, "focus-task-card", %{task_id: "issue-suggested"})
    refute render(view) =~ "task-detail-backdrop"

    rendered = render_click(view, "refresh")
    refute rendered =~ "TODO App / Issues"
    assert rendered =~ "Group"
  end

  test "kanban issue detail opens reuse current runtime instead of taking a new orchestrator snapshot" do
    orchestrator_name = Module.concat(__MODULE__, :BoardDetailRuntimeOrchestrator)
    Application.put_env(:symphony_elixir, :pitchai_pm_client_module, FakePitchAIPMClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "pitchai_pm",
      tracker_project_id: "project-pm",
      tracker_database_url: "postgresql://postgres:postgres@127.0.0.1:5432/test"
    )

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        recipient: self()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    {:ok, view, _html} = live(build_conn(), "/")

    flush_snapshot_requests()

    detail = render_click(view, "open_task", %{"task_id" => "issue-http"})

    assert detail =~ "Agent progress"
    assert detail =~ "Dispatch active PM task"
    refute_receive :snapshot_requested, 50
  end

  test "kanban board applies persisted collapsed project groups" do
    orchestrator_name = Module.concat(__MODULE__, :CollapsedBoardOrchestrator)
    Application.put_env(:symphony_elixir, :pitchai_pm_client_module, FakePitchAIPMClient)

    Application.put_env(:symphony_elixir, :pitchai_pm_fake_collapsed_groups, [
      %{group_by: "project", column_state_name: "Todo", group_key: "project:project-pm"}
    ])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "pitchai_pm",
      tracker_project_id: "project-pm",
      tracker_database_url: "postgresql://postgres:postgres@127.0.0.1:5432/test"
    )

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "issue-group is-collapsed"
    assert html =~ "aria-expanded=\"false\""
    assert html =~ "issue-group-count"
    refute html =~ "Upgrade to latest React version"
  end

  test "status liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/status")
    assert html =~ "SYMPHONY STATUS"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Backoff queue"
    assert html =~ "EVENT"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "terminal-running-table"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/status")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert ["no-store"] = Req.Response.get_header(dashboard_css, "cache-control")
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp flush_snapshot_requests do
    receive do
      :snapshot_requested -> flush_snapshot_requests()
    after
      0 -> :ok
    end
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
