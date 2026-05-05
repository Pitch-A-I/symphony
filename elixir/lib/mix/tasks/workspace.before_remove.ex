defmodule Mix.Tasks.Workspace.BeforeRemove do
  use Mix.Task

  @shortdoc "Close open GitHub PRs for the current branch before workspace removal"

  @moduledoc """
  Closes open pull requests for the current Git branch.

  This task is intended for use from the `before_remove` workspace hook.

  Usage:

      mix workspace.before_remove
      mix workspace.before_remove --branch feature/my-branch
      mix workspace.before_remove --repo openai/symphony
      mix workspace.before_remove --workspace /tmp/symphony-workspace
  """

  @default_repo "openai/symphony"
  @protected_branches MapSet.new(["main", "master", "staging", "develop", "development", "trunk", "production", "prod"])

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [branch: :string, help: :boolean, repo: :string, workspace: :string],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        workspace = opts[:workspace]
        branch = opts[:branch] || current_branch(workspace)
        repo = opts[:repo] || github_repo_for_workspace(workspace) || @default_repo

        maybe_close_open_pull_requests(repo, branch)
        maybe_delete_remote_branch(workspace, branch)
    end
  end

  defp maybe_close_open_pull_requests(_repo, nil), do: :ok

  defp maybe_close_open_pull_requests(repo, branch) do
    cond do
      protected_branch?(branch) ->
        Mix.shell().info("Skipping PR cleanup for protected branch #{branch}")

      unsafe_branch_name?(branch) ->
        Mix.shell().error("Skipping PR cleanup for unsafe branch name #{inspect(branch)}")

      gh_available?() and gh_authenticated?() ->
        repo
        |> list_open_pull_request_numbers(branch)
        |> Enum.each(&close_pull_request(repo, branch, &1))

      true ->
        :ok
    end

    :ok
  end

  defp gh_available? do
    not is_nil(System.find_executable("gh"))
  end

  defp gh_authenticated? do
    match?({:ok, _output}, run_command("gh", ["auth", "status"]))
  end

  defp list_open_pull_request_numbers(repo, branch) do
    case run_command("gh", [
           "pr",
           "list",
           "--repo",
           repo,
           "--head",
           branch,
           "--state",
           "open",
           "--json",
           "number",
           "--jq",
           ".[].number"
         ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp close_pull_request(repo, branch, pr_number) do
    case run_command("gh", [
           "pr",
           "close",
           pr_number,
           "--repo",
           repo,
           "--comment",
           closing_comment(branch)
         ]) do
      {:ok, _output} ->
        Mix.shell().info("Closed PR ##{pr_number} for branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to close PR ##{pr_number} for branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp closing_comment(branch) do
    "Closing because the PitchAI PM task for branch #{branch} was cancelled before merge."
  end

  defp format_output(""), do: ""
  defp format_output(output), do: " output=#{inspect(output)}"

  defp current_branch(workspace) do
    case run_git_command(workspace, ["branch", "--show-current"]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          branch -> branch
        end

      {:error, _reason} ->
        nil
    end
  end

  defp github_repo_for_workspace(nil), do: nil

  defp github_repo_for_workspace(workspace) do
    case run_git_command(workspace, ["remote", "get-url", "origin"]) do
      {:ok, output} -> github_repo_from_remote_url(output)
      {:error, _reason} -> nil
    end
  end

  defp github_repo_from_remote_url(remote_url) when is_binary(remote_url) do
    remote_url = String.trim(remote_url)

    case Regex.run(~r{github\.com[:/]([^/\s:]+/[^/\s]+?)(?:\.git)?/?$}i, remote_url) do
      [_match, repo] -> String.replace_suffix(repo, ".git", "")
      _no_match -> nil
    end
  end

  defp maybe_delete_remote_branch(nil, _branch), do: :ok
  defp maybe_delete_remote_branch(_workspace, nil), do: :ok

  defp maybe_delete_remote_branch(workspace, branch) do
    cond do
      protected_branch?(branch) ->
        Mix.shell().info("Skipping remote branch cleanup for protected branch #{branch}")

      unsafe_branch_name?(branch) ->
        Mix.shell().error("Skipping remote branch cleanup for unsafe branch name #{inspect(branch)}")

      not git_available?() ->
        :ok

      true ->
        delete_remote_branch_if_present(workspace, branch)
    end

    :ok
  end

  defp delete_remote_branch_if_present(workspace, branch) do
    case remote_branch_status(workspace, branch) do
      :present ->
        delete_remote_branch(workspace, branch)

      :missing ->
        :ok

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to inspect remote branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp remote_branch_status(workspace, branch) do
    case run_git_command(workspace, ["ls-remote", "--exit-code", "--heads", "origin", branch]) do
      {:ok, _output} -> :present
      {:error, {2, _output}} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_remote_branch(workspace, branch) do
    case run_git_command(workspace, ["push", "origin", "--delete", branch]) do
      {:ok, _output} ->
        Mix.shell().info("Deleted remote branch #{branch}")

      {:error, {status, output}} ->
        trimmed_output = String.trim(output)

        Mix.shell().error("Failed to delete remote branch #{branch}: exit #{status}#{format_output(trimmed_output)}")
    end
  end

  defp git_available? do
    not is_nil(System.find_executable("git"))
  end

  defp protected_branch?(branch) when is_binary(branch) do
    branch
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@protected_branches, &1))
  end

  defp protected_branch?(_branch), do: true

  defp unsafe_branch_name?(branch) when is_binary(branch) do
    trimmed_branch = String.trim(branch)

    trimmed_branch == "" or String.starts_with?(trimmed_branch, "-") or
      String.contains?(trimmed_branch, ["\n", "\r", <<0>>, " ", "\t", "..", "@{", "\\", "~", "^", ":", "?", "*", "["])
  end

  defp unsafe_branch_name?(_branch), do: true

  defp run_git_command(nil, args), do: run_command("git", args)
  defp run_git_command(workspace, args), do: run_command("git", ["-C", workspace | args])

  defp run_command(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:enoent, ""}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end
end
