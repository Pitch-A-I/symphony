defmodule SymphonyElixirWeb.BasicAuth do
  @moduledoc """
  Optional dashboard/API basic authentication.
  """

  import Plug.Conn

  @realm "PitchAI Symphony"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case credentials() do
      nil ->
        conn

      {username, password} ->
        authorize(conn, username, password)
    end
  end

  defp authorize(conn, username, password) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {provided_username, provided_password}
      when is_binary(provided_username) and is_binary(provided_password) ->
        if secure_compare(provided_username, username) and secure_compare(provided_password, password) do
          conn
        else
          unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Basic realm=\"#{@realm}\"")
    |> send_resp(401, "authentication required\n")
    |> halt()
  end

  defp credentials do
    username = clean(System.get_env("SYMPHONY_DASHBOARD_USERNAME")) || "pitchai"
    password = clean(System.get_env("SYMPHONY_DASHBOARD_PASSWORD"))

    if password do
      {username, password}
    else
      nil
    end
  end

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean(_), do: nil

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
