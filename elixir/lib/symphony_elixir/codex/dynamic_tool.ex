defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, PitchAIPM}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @pitchai_pm_tool "pitchai_pm"
  @pitchai_pm_description """
  Execute a narrow operation against the PitchAI project-management database.
  """
  @pitchai_pm_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["operation", "params"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "description" => "One of get_task, list_tasks, list_workflow_states, update_task_state, append_changelog, get_workpad, upsert_workpad, add_comment, attach_pr, create_task."
      },
      "params" => %{
        "type" => "object",
        "description" => "Operation parameters.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @pitchai_pm_tool ->
        execute_pitchai_pm(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case tracker_kind() do
      "pitchai_pm" ->
        [
          %{
            "name" => @pitchai_pm_tool,
            "description" => @pitchai_pm_description,
            "inputSchema" => @pitchai_pm_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_pitchai_pm(arguments, opts) do
    pitchai_pm_client = Keyword.get(opts, :pitchai_pm_client, &PitchAIPM.Client.tool_operation/2)

    with {:ok, operation, params} <- normalize_pitchai_pm_arguments(arguments),
         {:ok, response} <- pitchai_pm_client.(operation, params) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(pitchai_pm_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_pitchai_pm_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> normalize_pitchai_pm_arguments(decoded)
      {:error, _reason} -> {:error, :invalid_pitchai_pm_arguments}
    end
  end

  defp normalize_pitchai_pm_arguments(arguments) when is_map(arguments) do
    operation =
      case Map.get(arguments, "operation") || Map.get(arguments, :operation) do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    params = Map.get(arguments, "params") || Map.get(arguments, :params) || %{}

    cond do
      operation == "" -> {:error, :missing_pitchai_pm_operation}
      not is_map(params) -> {:error, :invalid_pitchai_pm_params}
      true -> {:ok, operation, params}
    end
  end

  defp normalize_pitchai_pm_arguments(_arguments), do: {:error, :invalid_pitchai_pm_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp pitchai_pm_error_payload(:missing_pitchai_pm_operation) do
    %{"error" => %{"message" => "`pitchai_pm` requires a non-empty `operation` string."}}
  end

  defp pitchai_pm_error_payload(:invalid_pitchai_pm_params) do
    %{"error" => %{"message" => "`pitchai_pm.params` must be a JSON object."}}
  end

  defp pitchai_pm_error_payload(:invalid_pitchai_pm_arguments) do
    %{"error" => %{"message" => "`pitchai_pm` expects an object with `operation` and `params`."}}
  end

  defp pitchai_pm_error_payload(reason) do
    %{
      "error" => %{
        "message" => "PitchAI PM tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp tracker_kind do
    case Config.settings() do
      {:ok, settings} -> settings.tracker.kind
      _ -> nil
    end
  end
end
