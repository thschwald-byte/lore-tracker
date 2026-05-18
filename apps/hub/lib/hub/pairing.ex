defmodule Hub.Pairing do
  @moduledoc """
  Pure helpers for the `/pair` flow.

  The flow itself spans `HubWeb.PairController` (entry) and
  `HubWeb.AuthController.callback/2` (Discord post-OAuth dispatch).
  """

  @session_worker_id :pair_worker_id
  @session_callback :pair_callback
  @session_nonce :pair_nonce

  def session_keys, do: [@session_worker_id, @session_callback, @session_nonce]

  @doc """
  Validate the URL the Worker passed as `?callback=`. Must be HTTP loopback
  (Discord is the only secret holder — we don't want a malicious link to
  exfiltrate a freshly-minted token to an arbitrary host).
  """
  @spec validate_callback(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def validate_callback(nil), do: {:error, "missing callback"}

  def validate_callback(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host, port: port}
      when host in ["localhost", "127.0.0.1", "::1"] and is_integer(port) ->
        {:ok, url}

      _ ->
        {:error, "callback must be http://localhost:<port>/..."}
    end
  end

  @doc """
  Validate the worker_id passed by the Worker. Cheap shape check —
  UUIDv7 strings are 36 chars.
  """
  @spec validate_worker_id(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def validate_worker_id(nil), do: {:error, "missing worker_id"}

  def validate_worker_id(id) when is_binary(id) do
    if String.length(id) == 36 and String.match?(id, ~r/^[0-9a-f-]+$/i) do
      {:ok, id}
    else
      {:error, "worker_id is not a UUID"}
    end
  end

  def put_pair_context(conn, worker_id, callback, nonce) do
    conn
    |> Plug.Conn.put_session(@session_worker_id, worker_id)
    |> Plug.Conn.put_session(@session_callback, callback)
    |> Plug.Conn.put_session(@session_nonce, nonce)
  end

  def take_pair_context(conn) do
    worker_id = Plug.Conn.get_session(conn, @session_worker_id)
    callback = Plug.Conn.get_session(conn, @session_callback)
    nonce = Plug.Conn.get_session(conn, @session_nonce)

    new_conn =
      Enum.reduce(session_keys(), conn, fn key, c ->
        Plug.Conn.delete_session(c, key)
      end)

    case worker_id do
      nil -> {:error, :no_pair_context, new_conn}
      _ -> {:ok, %{worker_id: worker_id, callback: callback, nonce: nonce}, new_conn}
    end
  end
end
