defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Minimal GitHub API client for PR review comment polling and replies.
  """

  require Logger

  @api_base "https://api.github.com"
  @api_version "2022-11-28"
  @marker_prefix "<!-- symphony-pr-review-response"

  @type pr_ref :: %{repo_full_name: String.t(), pr_number: pos_integer()}
  @type comment :: %{
          required(:kind) => String.t(),
          required(:id) => String.t(),
          required(:body) => String.t(),
          required(:created_at) => String.t(),
          optional(:html_url) => String.t(),
          optional(:author_login) => String.t(),
          optional(:author_type) => String.t()
        }

  @successful_check_conclusions MapSet.new(["success", "skipped", "neutral"])

  @spec parse_pr_url(String.t()) :: {:ok, pr_ref()} | {:error, :invalid_github_pr_url}
  def parse_pr_url(url) when is_binary(url) do
    case Regex.run(~r{github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)}i, url) do
      [_match, repo_full_name, pr_number] ->
        {:ok, %{repo_full_name: repo_full_name, pr_number: String.to_integer(pr_number)}}

      _no_match ->
        {:error, :invalid_github_pr_url}
    end
  end

  @spec list_pr_comments(String.t(), pos_integer()) :: {:ok, [comment()]} | {:error, term()}
  def list_pr_comments(repo_full_name, pr_number) when is_binary(repo_full_name) and is_integer(pr_number) do
    with {:ok, issue_comments} <- list_issue_comments(repo_full_name, pr_number),
         {:ok, review_comments} <- list_review_comments(repo_full_name, pr_number) do
      {:ok, issue_comments ++ review_comments}
    end
  end

  @spec post_pr_reply(String.t(), pos_integer(), String.t()) ::
          {:ok, %{id: String.t(), url: String.t() | nil}} | {:error, term()}
  def post_pr_reply(repo_full_name, pr_number, body)
      when is_binary(repo_full_name) and is_integer(pr_number) and is_binary(body) do
    path = "/repos/#{repo_full_name}/issues/#{pr_number}/comments"

    case request(:post, path, json: %{body: body}) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok,
         %{
           id: response_body |> Map.get("id") |> to_string(),
           url: Map.get(response_body, "html_url")
         }}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:github_post_failed, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ensure_pr_ci_prewarmed(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def ensure_pr_ci_prewarmed(repo_full_name, pr_number)
      when is_binary(repo_full_name) and is_integer(pr_number) do
    with {:ok, pr_info} <- pull_request_info(repo_full_name, pr_number),
         {:ok, check_runs} <- list_commit_check_runs(repo_full_name, pr_info.head_sha) do
      check_runs
      |> summarize_check_runs()
      |> Map.merge(%{
        head_sha: pr_info.head_sha,
        head_ref: pr_info.head_ref,
        head_repo_full_name: pr_info.head_repo_full_name
      })
      |> maybe_request_missing_check_suite(repo_full_name)
    end
  end

  @spec response_marker_prefix() :: String.t()
  def response_marker_prefix, do: @marker_prefix

  @spec bot_response?(String.t() | nil) :: boolean()
  def bot_response?(body) when is_binary(body), do: String.contains?(body, @marker_prefix)
  def bot_response?(_body), do: false

  defp list_issue_comments(repo_full_name, pr_number) do
    list_paginated("/repos/#{repo_full_name}/issues/#{pr_number}/comments", %{kind: "issue_comment"})
  end

  defp list_review_comments(repo_full_name, pr_number) do
    list_paginated("/repos/#{repo_full_name}/pulls/#{pr_number}/comments", %{kind: "review_comment"})
  end

  defp pull_request_info(repo_full_name, pr_number) do
    case request(:get, "/repos/#{repo_full_name}/pulls/#{pr_number}", []) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        pull_request_info_from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_pr_fetch_failed, repo_full_name, pr_number, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pull_request_info_from_body(body) do
    head = Map.get(body, "head") || %{}
    head_repo = Map.get(head, "repo") || %{}

    case clean_string(Map.get(head, "sha")) do
      nil ->
        {:error, :missing_github_pr_head_sha}

      head_sha ->
        {:ok,
         %{
           head_sha: head_sha,
           head_ref: clean_string(Map.get(head, "ref")),
           head_repo_full_name: clean_string(Map.get(head_repo, "full_name"))
         }}
    end
  end

  defp list_commit_check_runs(repo_full_name, head_sha) do
    case request(:get, "/repos/#{repo_full_name}/commits/#{head_sha}/check-runs", params: [per_page: 100]) do
      {:ok, %Req.Response{status: status, body: %{"check_runs" => check_runs}}}
      when status in 200..299 and is_list(check_runs) ->
        {:ok, check_runs}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error, {:github_check_runs_shape, status, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_check_runs_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize_check_runs(check_runs) when is_list(check_runs) do
    pending = Enum.count(check_runs, &check_run_pending?/1)
    failed = Enum.count(check_runs, &check_run_failed?/1)
    passed = max(length(check_runs) - pending - failed, 0)

    %{
      state: check_summary_state(length(check_runs), pending, failed),
      action: "observed",
      total: length(check_runs),
      pending: pending,
      failed: failed,
      passed: passed
    }
  end

  defp check_summary_state(0, _pending, _failed), do: "missing"
  defp check_summary_state(_total, _pending, failed) when failed > 0, do: "failed"
  defp check_summary_state(_total, pending, _failed) when pending > 0, do: "running"
  defp check_summary_state(_total, _pending, _failed), do: "passed"

  defp check_run_pending?(check_run) when is_map(check_run) do
    clean_string(Map.get(check_run, "status")) != "completed" or clean_string(Map.get(check_run, "conclusion")) == nil
  end

  defp check_run_pending?(_check_run), do: true

  defp check_run_failed?(check_run) when is_map(check_run) do
    clean_string(Map.get(check_run, "status")) == "completed" and
      not MapSet.member?(@successful_check_conclusions, clean_string(Map.get(check_run, "conclusion")))
  end

  defp check_run_failed?(_check_run), do: true

  defp maybe_request_missing_check_suite(%{state: "missing", head_sha: head_sha} = summary, repo_full_name) do
    with {:ok, check_suites} <- list_commit_check_suites(repo_full_name, head_sha),
         {:ok, check_suite} <- latest_check_suite(check_suites) do
      rerequest_check_suite(repo_full_name, check_suite, summary)
    else
      {:error, :no_check_suites} ->
        {:ok, Map.merge(summary, %{action: "none", reason: "no_check_suites"})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_request_missing_check_suite(summary, _repo_full_name), do: {:ok, summary}

  defp list_commit_check_suites(repo_full_name, head_sha) do
    case request(:get, "/repos/#{repo_full_name}/commits/#{head_sha}/check-suites", params: [per_page: 100]) do
      {:ok, %Req.Response{status: status, body: %{"check_suites" => check_suites}}}
      when status in 200..299 and is_list(check_suites) ->
        {:ok, check_suites}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error, {:github_check_suites_shape, status, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_check_suites_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_check_suite([]), do: {:error, :no_check_suites}

  defp latest_check_suite(check_suites) do
    {:ok, Enum.max_by(check_suites, &(Map.get(&1, "updated_at") || Map.get(&1, "created_at") || ""))}
  end

  defp rerequest_check_suite(repo_full_name, check_suite, summary) do
    case Map.get(check_suite, "id") do
      id when is_integer(id) ->
        do_rerequest_check_suite(repo_full_name, id, summary)

      _missing ->
        {:ok, Map.merge(summary, %{action: "none", reason: "check_suite_missing_id"})}
    end
  end

  defp do_rerequest_check_suite(repo_full_name, check_suite_id, summary) do
    case request(:post, "/repos/#{repo_full_name}/check-suites/#{check_suite_id}/rerequest", []) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, Map.merge(summary, %{state: "requested", action: "rerequested", check_suite_id: check_suite_id})}

      {:ok, %Req.Response{status: status, body: body}} when status in [403, 404, 422] ->
        {:ok,
         Map.merge(summary, %{
           action: "not_requested",
           check_suite_id: check_suite_id,
           reason: "rerequest_rejected",
           github_status: status,
           github_body: body
         })}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_check_suite_rerequest_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_paginated(path, metadata, page \\ 1, acc \\ []) do
    case request(:get, path, params: [per_page: 100, page: page]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_list(body) ->
        comments = Enum.map(body, &comment_from_github(&1, metadata))

        if length(body) < 100 do
          {:ok, Enum.reverse(acc, comments)}
        else
          list_paginated(path, metadata, page + 1, Enum.reverse(comments, acc))
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_list_failed, path, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, path, opts) do
    with {:ok, token} <- github_token() do
      Req.request(
        [
          method: method,
          base_url: @api_base,
          url: path,
          auth: {:bearer, token},
          headers: [
            {"accept", "application/vnd.github+json"},
            {"x-github-api-version", @api_version},
            {"user-agent", "pitchai-symphony-pr-review-bridge"}
          ],
          receive_timeout: 30_000
        ] ++ opts
      )
    end
  end

  defp github_token do
    [
      System.get_env("GITHUB_TOKEN"),
      System.get_env("GH_TOKEN"),
      System.get_env("GITHUB_DEV_PAT"),
      System.get_env("PITCHAI_GIT_TOKEN")
    ]
    |> Enum.find_value(&clean_string/1)
    |> case do
      token when is_binary(token) ->
        {:ok, token}

      nil ->
        github_token_from_cli()
    end
  end

  defp github_token_from_cli do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} ->
        case clean_string(token) do
          nil -> {:error, :missing_github_token}
          clean_token -> {:ok, clean_token}
        end

      {output, status} ->
        Logger.warning("Unable to read GitHub token from gh auth token status=#{status} output=#{inspect(String.trim(output))}")
        {:error, :missing_github_token}
    end
  rescue
    error in ErlangError -> {:error, {:github_cli_unavailable, Exception.message(error)}}
  end

  defp comment_from_github(comment, metadata) when is_map(comment) do
    user = Map.get(comment, "user") || %{}

    %{
      kind: Map.fetch!(metadata, :kind),
      id: comment |> Map.get("id") |> to_string(),
      body: Map.get(comment, "body") || "",
      html_url: Map.get(comment, "html_url"),
      author_login: Map.get(user, "login"),
      author_type: Map.get(user, "type"),
      created_at: Map.get(comment, "created_at")
    }
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_string(_value), do: nil
end
