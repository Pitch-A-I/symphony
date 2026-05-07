defmodule SymphonyElixir.PRReviewBridgeTest do
  use SymphonyElixir.TestSupport

  defmodule FakePitchAIPMClient do
    def human_review_pr_links do
      state_agent()
      |> Agent.get(fn state -> {:ok, Map.fetch!(state, :links)} end)
    end

    def sync_github_pr_comments(link, comments) do
      Agent.update(state_agent(), &Map.put(&1, :synced, {link, comments}))
      {:ok, %{baseline?: false, inserted: length(comments)}}
    end

    def claim_pending_github_pr_comment(_worker_id) do
      Agent.get_and_update(state_agent(), fn state ->
        cond do
          is_nil(Map.get(state, :response)) ->
            {{:ok, nil}, state}

          Map.get(state, :claimed?) ->
            {{:ok, nil}, state}

          true ->
            {{:ok, Map.fetch!(state, :response)}, Map.put(state, :claimed?, true)}
        end
      end)
    end

    def mark_github_pr_comment_responded(response_id, response_body, github_comment_id, response_url) do
      Agent.update(
        state_agent(),
        &Map.put(&1, :responded, %{
          response_id: response_id,
          response_body: response_body,
          github_comment_id: github_comment_id,
          response_url: response_url
        })
      )

      :ok
    end

    def mark_github_pr_comment_failed(response_id, error, retry_delay_seconds) do
      Agent.update(
        state_agent(),
        &Map.put(&1, :failed, %{
          response_id: response_id,
          error: error,
          retry_delay_seconds: retry_delay_seconds
        })
      )

      :ok
    end

    defp state_agent, do: Application.fetch_env!(:symphony_elixir, :pr_review_bridge_test_agent)
  end

  defmodule FakeGitHubClient do
    def parse_pr_url("https://github.com/pitchai/example/pull/12") do
      {:ok, %{repo_full_name: "pitchai/example", pr_number: 12}}
    end

    def parse_pr_url(_url), do: {:error, :invalid_github_pr_url}

    def list_pr_comments(repo_full_name, pr_number) do
      Agent.update(state_agent(), &Map.put(&1, :listed_pr, %{repo_full_name: repo_full_name, pr_number: pr_number}))

      {:ok,
       [
         %{
           kind: "issue_comment",
           id: "1001",
           body: "Can you explain why this fixes the timeout?",
           html_url: "https://github.com/pitchai/example/pull/12#issuecomment-1001",
           author_login: "reviewer",
           author_type: "User",
           created_at: "2026-05-05T10:00:00Z"
         }
       ]}
    end

    def post_pr_reply(repo_full_name, pr_number, body) do
      Agent.update(
        state_agent(),
        &Map.put(&1, :github_reply, %{repo_full_name: repo_full_name, pr_number: pr_number, body: body})
      )

      {:ok, %{id: "2002", url: "https://github.com/pitchai/example/pull/12#issuecomment-2002"}}
    end

    def ensure_pr_ci_prewarmed(repo_full_name, pr_number) do
      Agent.update(
        state_agent(),
        &Map.update(&1, :ci_prewarmed, [%{repo_full_name: repo_full_name, pr_number: pr_number}], fn checks ->
          [%{repo_full_name: repo_full_name, pr_number: pr_number} | checks]
        end)
      )

      {:ok, %{state: "running", action: "observed", total: 2, pending: 1, failed: 0, passed: 1, head_sha: "abc123"}}
    end

    defp state_agent, do: Application.fetch_env!(:symphony_elixir, :pr_review_bridge_test_agent)
  end

  defmodule FakeCodexResume do
    def run(thread_id, workspace, prompt) do
      Agent.update(
        state_agent(),
        &Map.put(&1, :codex_resume, %{thread_id: thread_id, workspace: workspace, prompt: prompt})
      )

      {:ok, "This change fixes the timeout by reducing repeated polling and preserving the cached response path."}
    end

    defp state_agent, do: Application.fetch_env!(:symphony_elixir, :pr_review_bridge_test_agent)
  end

  test "PR review bridge resumes original Codex thread and posts response to GitHub" do
    workspace = Path.join(System.tmp_dir!(), "symphony-pr-review-bridge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    {:ok, state_agent} =
      Agent.start_link(fn ->
        %{
          links: [
            %{
              task_id: "11111111-1111-1111-1111-111111111111",
              identifier: "PM-12345678",
              title: "Review bridge test",
              pr_link_id: 42,
              url: "https://github.com/pitchai/example/pull/12",
              repo_full_name: "stale/tracking-repo",
              pr_number: 12,
              session_id: "019df465-4e69-77e1-8f01-f91b87c0cb80-019df465-5029-7170-b41d-c629e8cc1a73",
              thread_id: "019df465-4e69-77e1-8f01-f91b87c0cb80",
              workspace_path: workspace
            }
          ],
          response: %{
            id: 7,
            task_id: "11111111-1111-1111-1111-111111111111",
            identifier: "PM-12345678",
            title: "Review bridge test",
            repo_full_name: "pitchai/example",
            pr_number: 12,
            github_comment_id: "1001",
            github_comment_url: "https://github.com/pitchai/example/pull/12#issuecomment-1001",
            author_login: "reviewer",
            body: "Can you explain why this fixes the timeout?",
            attempts: 1,
            thread_id: "019df465-4e69-77e1-8f01-f91b87c0cb80",
            workspace_path: workspace
          }
        }
      end)

    original_pm_client = Application.get_env(:symphony_elixir, :pitchai_pm_client_module)
    original_github_client = Application.get_env(:symphony_elixir, :github_client_module)
    original_codex_resume = Application.get_env(:symphony_elixir, :codex_resume_module)
    original_agent = Application.get_env(:symphony_elixir, :pr_review_bridge_test_agent)

    Application.put_env(:symphony_elixir, :pitchai_pm_client_module, FakePitchAIPMClient)
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :codex_resume_module, FakeCodexResume)
    Application.put_env(:symphony_elixir, :pr_review_bridge_test_agent, state_agent)

    on_exit(fn ->
      restore_application_env(:pitchai_pm_client_module, original_pm_client)
      restore_application_env(:github_client_module, original_github_client)
      restore_application_env(:codex_resume_module, original_codex_resume)
      restore_application_env(:pr_review_bridge_test_agent, original_agent)
      File.rm_rf(workspace)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "pitchai_pm",
      tracker_project_id: "project-pm",
      tracker_database_url: "postgres://postgres:postgres@example.invalid/pm"
    )

    bridge_name = Module.concat(__MODULE__, :Bridge)
    {:ok, bridge} = GenServer.start(SymphonyElixir.PRReviewBridge, [], name: bridge_name)

    on_exit(fn ->
      if Process.alive?(bridge), do: Process.exit(bridge, :normal)
    end)

    send(bridge, :poll)

    assert_eventually(fn ->
      state = Agent.get(state_agent, & &1)

      assert %{
               responded: %{response_id: 7, github_comment_id: "2002"},
               listed_pr: %{repo_full_name: "pitchai/example", pr_number: 12},
               codex_resume: %{
                 thread_id: "019df465-4e69-77e1-8f01-f91b87c0cb80",
                 workspace: ^workspace,
                 prompt: prompt
               },
               github_reply: %{body: github_reply_body}
             } = state

      assert prompt =~ "Can you explain why this fixes the timeout?"
      assert github_reply_body =~ "<!-- symphony-pr-review-response"
      assert github_reply_body =~ "@reviewer"
      assert [%{repo_full_name: "pitchai/example", pr_number: 12}] = state.ci_prewarmed
    end)
  end

  test "PR review bridge prewarms CI for Human Review PRs without a resume session" do
    {:ok, state_agent} =
      Agent.start_link(fn ->
        %{
          links: [
            %{
              task_id: "11111111-1111-1111-1111-111111111111",
              identifier: "PM-12345678",
              title: "Review bridge CI prewarm test",
              pr_link_id: 42,
              url: "https://github.com/pitchai/example/pull/12",
              repo_full_name: "pitchai/example",
              pr_number: 12
            }
          ]
        }
      end)

    original_pm_client = Application.get_env(:symphony_elixir, :pitchai_pm_client_module)
    original_github_client = Application.get_env(:symphony_elixir, :github_client_module)
    original_agent = Application.get_env(:symphony_elixir, :pr_review_bridge_test_agent)

    Application.put_env(:symphony_elixir, :pitchai_pm_client_module, FakePitchAIPMClient)
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :pr_review_bridge_test_agent, state_agent)

    on_exit(fn ->
      restore_application_env(:pitchai_pm_client_module, original_pm_client)
      restore_application_env(:github_client_module, original_github_client)
      restore_application_env(:pr_review_bridge_test_agent, original_agent)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "pitchai_pm",
      tracker_project_id: "project-pm",
      tracker_database_url: "postgres://postgres:postgres@example.invalid/pm"
    )

    bridge_name = Module.concat(__MODULE__, :CIPrewarmBridge)
    {:ok, bridge} = GenServer.start(SymphonyElixir.PRReviewBridge, [], name: bridge_name)

    on_exit(fn ->
      if Process.alive?(bridge), do: Process.exit(bridge, :normal)
    end)

    send(bridge, :poll)

    assert_eventually(fn ->
      state = Agent.get(state_agent, & &1)
      assert [%{repo_full_name: "pitchai/example", pr_number: 12}] = Map.get(state, :ci_prewarmed)
      refute Map.has_key?(state, :codex_resume)
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(100)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(fun, 0), do: fun.()

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
