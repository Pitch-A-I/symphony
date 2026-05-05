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
