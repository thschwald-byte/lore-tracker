defmodule Worker.Setup.Router do
  @moduledoc """
  Tiny Plug router for the worker's local pairing UI. Bound to
  `localhost:<setup_port>` only.
  """

  use Plug.Router

  require Logger

  alias Worker.Repo

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug :dispatch

  get "/setup" do
    worker_id =
      case Repo.get_state(:worker_id) do
        nil ->
          new_id = UUIDv7.generate()
          Repo.put_state(:worker_id, new_id)
          new_id

        existing ->
          existing
      end

    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    callback = "#{my_base_url(conn)}/paired"

    pair_url =
      hub_base_url() <>
        "/pair?" <>
        URI.encode_query(worker_id: worker_id, nonce: nonce, callback: callback)

    redirect(conn, pair_url)
  end

  get "/paired" do
    params = conn.query_params

    with token when is_binary(token) and byte_size(token) > 0 <- params["token"],
         discord_id when is_binary(discord_id) and byte_size(discord_id) > 0 <-
           params["discord_id"],
         display_name when is_binary(display_name) <- params["display_name"] || "" do
      :ok =
        Repo.put_state_many(%{
          hub_token: token,
          admin_discord_id: discord_id,
          hub_base_url: hub_base_url(),
          last_applied_seq: 0
        })

      :ok = Repo.upsert_user(discord_id, display_name)

      Logger.info(
        "Worker paired: discord_id=#{discord_id} display_name=#{display_name} (Hub-Token gespeichert)"
      )

      html(conn, success_body(discord_id, display_name))
    else
      _ ->
        send_resp(
          conn,
          400,
          "Pairing-Antwort unvollständig: token/discord_id/display_name fehlen."
        )
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp hub_base_url do
    Application.fetch_env!(:worker, :hub_base_url)
  end

  defp my_base_url(conn) do
    "http://#{conn.host}:#{conn.port}"
  end

  defp redirect(conn, url) do
    conn
    |> Plug.Conn.put_resp_header("location", url)
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(302, "redirecting to #{url}")
  end

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html; charset=utf-8")
    |> Plug.Conn.send_resp(200, body)
  end

  defp success_body(discord_id, display_name) do
    """
    <!DOCTYPE html>
    <html lang="de"><head><meta charset="utf-8"><title>Pairing fertig</title></head>
    <body style="font-family: system-ui; max-width: 36rem; margin: 4rem auto; padding: 0 1rem;">
      <h1>Pairing abgeschlossen</h1>
      <p>Admin: <strong>#{Plug.HTML.html_escape_to_iodata(display_name)}</strong>
         <small>(Discord-ID #{Plug.HTML.html_escape_to_iodata(discord_id)})</small></p>
      <p>Dieses Browser-Fenster kann geschlossen werden. Der Worker verbindet sich
         beim nächsten Start mit dem Hub (Channel-Plumbing landet in M3).</p>
    </body></html>
    """
  end
end
