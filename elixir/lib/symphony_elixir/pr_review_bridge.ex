defmodule SymphonyElixir.PRReviewBridge do
  @moduledoc """
  Polls linked GitHub PRs in Human Review and asks the original Codex session to answer new comments.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Codex.Resume, as: CodexResume
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.PitchAIPM.Client, as: PitchAIPMClient
  alias SymphonyElixir.Workspace

  @poll_interval_ms 15_000
  @max_in_flight 1

  defstruct timer_ref: nil, in_flight: %{}, worker_id: nil

  @type state :: %__MODULE__{
          timer_ref: reference() | nil,
          in_flight: %{optional(reference()) => map()},
          worker_id: String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{worker_id: "pr-review-bridge-#{System.unique_integer([:positive])}"}
    {:ok, schedule_poll(state, 2_000)}
  end

  @impl true
  def handle_info(:poll, %__MODULE__{} = state) do
    state = %{state | timer_ref: nil}

    state =
      if bridge_enabled?() do
        sync_linked_pr_comments()
        dispatch_pending_comments(state)
      else
        state
      end

    {:noreply, schedule_poll(state, @poll_interval_ms)}
  end

  def handle_info({ref, result}, %__MODULE__{in_flight: in_flight} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    response = Map.get(in_flight, ref)
    state = %{state | in_flight: Map.delete(in_flight, ref)}
    handle_response_result(response, result)

    {:noreply, dispatch_pending_comments(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{in_flight: in_flight} = state) do
    response = Map.get(in_flight, ref)
    state = %{state | in_flight: Map.delete(in_flight, ref)}

    if response do
      mark_failed(response, {:resume_worker_down, reason})
    end

    {:noreply, dispatch_pending_comments(state)}
  end

  defp bridge_enabled? do
    Config.settings!().tracker.kind == "pitchai_pm"
  rescue
    error ->
      Logger.warning("PR review bridge disabled because config is unavailable: #{Exception.message(error)}")
      false
  end

  defp sync_linked_pr_comments do
    client = pitchai_pm_client()

    if function_exported?(client, :human_review_pr_links, 0) do
      case client.human_review_pr_links() do
        {:ok, links} ->
          Enum.each(links, &sync_pr_link_comments/1)

        {:error, reason} ->
          Logger.warning("PR review bridge failed to list Human Review PR links: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp sync_pr_link_comments(link) do
    with {:ok, link} <- normalize_pr_link(link),
         {:ok, comments} <- github_client().list_pr_comments(link.repo_full_name, link.pr_number),
         {:ok, result} <- pitchai_pm_client().sync_github_pr_comments(link, comments) do
      if result.inserted > 0 do
        Logger.info("PR review bridge queued #{result.inserted} GitHub comment(s) for #{link.identifier} #{link.url}")
      end
    else
      {:skip, reason} ->
        Logger.debug("PR review bridge skipped PR link: #{inspect(reason)}")

      {:error, reason} ->
        Logger.warning("PR review bridge failed to sync PR link #{inspect(Map.get(link, :url))}: #{inspect(reason)}")
    end
  end

  defp normalize_pr_link(link) when is_map(link) do
    parsed = pr_ref_from_link(link)

    with {:ok, pr_ref} <- parsed,
         thread_id when is_binary(thread_id) <- clean_string(Map.get(link, :thread_id)),
         true <- clean_string(Map.get(link, :task_id)) != nil do
      {:ok,
       link
       |> Map.put(:repo_full_name, pr_ref.repo_full_name)
       |> Map.put(:pr_number, pr_ref.pr_number)
       |> Map.put(:thread_id, thread_id)}
    else
      {:error, reason} -> {:skip, reason}
      nil -> {:skip, :missing_original_codex_session}
      false -> {:skip, :missing_task_id}
    end
  end

  defp pr_ref_from_link(link) do
    case GitHubClient.parse_pr_url(Map.get(link, :url) || "") do
      {:ok, pr_ref} ->
        {:ok, pr_ref}

      {:error, _reason} ->
        case {Map.get(link, :repo_full_name), Map.get(link, :pr_number)} do
          {repo_full_name, pr_number} when is_binary(repo_full_name) and is_integer(pr_number) ->
            {:ok, %{repo_full_name: repo_full_name, pr_number: pr_number}}

          _missing ->
            {:error, :invalid_github_pr_url}
        end
    end
  end

  defp dispatch_pending_comments(%__MODULE__{} = state) do
    if map_size(state.in_flight) < @max_in_flight do
      client = pitchai_pm_client()
      maybe_claim_pending_comment(state, client)
    else
      state
    end
  end

  defp maybe_claim_pending_comment(state, client) do
    if function_exported?(client, :claim_pending_github_pr_comment, 1) do
      case client.claim_pending_github_pr_comment(state.worker_id) do
        {:ok, nil} ->
          state

        {:ok, response} ->
          start_response_task(state, response)

        {:error, reason} ->
          Logger.warning("PR review bridge failed to claim pending GitHub comment: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp start_response_task(state, response) do
    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        respond_to_pr_comment(response)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, response)}
  end

  defp respond_to_pr_comment(response) do
    with {:ok, workspace} <- workspace_for_response(response),
         {:ok, assistant_response} <-
           codex_resume().run(Map.fetch!(response, :thread_id), workspace, response_prompt(response)),
         github_body = github_response_body(response, assistant_response),
         {:ok, github_response} <-
           github_client().post_pr_reply(Map.fetch!(response, :repo_full_name), Map.fetch!(response, :pr_number), github_body),
         :ok <-
           pitchai_pm_client().mark_github_pr_comment_responded(
             Map.fetch!(response, :id),
             assistant_response,
             github_response.id,
             github_response.url
           ) do
      {:ok, %{response_id: response.id, github_response: github_response}}
    else
      {:error, reason} ->
        mark_failed(response, reason)
        {:error, reason}
    end
  end

  defp workspace_for_response(response) do
    workspace = clean_string(Map.get(response, :workspace_path)) || default_workspace_path(response)

    if File.dir?(workspace) do
      {:ok, workspace}
    else
      Workspace.create_for_issue(%{
        id: Map.get(response, :task_id),
        identifier: Map.get(response, :identifier)
      })
    end
  end

  defp default_workspace_path(response) do
    response
    |> Map.get(:identifier)
    |> safe_identifier()
    |> then(&Path.join(Config.settings!().workspace.root, &1))
  end

  defp safe_identifier(identifier) do
    identifier
    |> Kernel.||("issue")
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp response_prompt(response) do
    """
    A human commented on the GitHub pull request for your Symphony task.

    Task:
    - ID: #{response.task_id}
    - Identifier: #{response.identifier}
    - Title: #{response.title}

    Pull request:
    - Repository: #{response.repo_full_name}
    - PR: ##{response.pr_number}
    - Comment URL: #{response.github_comment_url || "n/a"}
    - Comment author: #{response.author_login || "unknown"}

    Human comment:
    #{response.body}

    Instructions:
    - Continue the original Codex session context and answer this PR comment directly.
    - Treat this as a review Q&A turn. Do not merge the PR.
    - Do not post to GitHub yourself; Symphony will post your final response back to the PR.
    - If the comment asks for code changes, explain what you would change and say the task should be moved to Rework for implementation.
    - Keep the final response concise, concrete, and suitable as a GitHub PR comment.
    """
  end

  defp github_response_body(response, assistant_response) do
    """
    <!-- symphony-pr-review-response task_id=#{response.task_id} source_comment_id=#{response.github_comment_id} -->
    @#{response.author_login || "reviewer"} #{assistant_response}
    """
  end

  defp handle_response_result(nil, _result), do: :ok

  defp handle_response_result(_response, {:ok, _result}), do: :ok

  defp handle_response_result(response, {:error, reason}) do
    mark_failed(response, reason)
  end

  defp mark_failed(response, reason) when is_map(response) do
    error = inspect(reason, limit: 50, printable_limit: 4_000)
    delay = retry_delay_seconds(Map.get(response, :attempts, 1))

    case pitchai_pm_client().mark_github_pr_comment_failed(Map.fetch!(response, :id), error, delay) do
      :ok -> :ok
      {:error, mark_reason} -> Logger.warning("PR review bridge failed to record response failure: #{inspect(mark_reason)}")
    end
  end

  defp retry_delay_seconds(attempts) when is_integer(attempts), do: min(900, max(1, attempts) * 60)
  defp retry_delay_seconds(_attempts), do: 60

  defp schedule_poll(%__MODULE__{timer_ref: timer_ref} = state, delay_ms) do
    if is_reference(timer_ref), do: Process.cancel_timer(timer_ref)
    %{state | timer_ref: Process.send_after(self(), :poll, delay_ms)}
  end

  defp pitchai_pm_client do
    Application.get_env(:symphony_elixir, :pitchai_pm_client_module, PitchAIPMClient)
  end

  defp github_client do
    Application.get_env(:symphony_elixir, :github_client_module, GitHubClient)
  end

  defp codex_resume do
    Application.get_env(:symphony_elixir, :codex_resume_module, CodexResume)
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_string(_value), do: nil
end
