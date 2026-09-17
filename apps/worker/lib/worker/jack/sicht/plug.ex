defmodule Worker.Jack.Sicht.Plug do
  @moduledoc """
  Die Seite der Laufsicht (`Worker.Jack.Sicht`):

    * `GET /` — die Seite (`priv/jack/sicht.html`), bei jedem Aufruf von der
      Platte gelesen: eine Änderung wirkt nach dem Neuladen im Browser, ohne
      den Lauf neu zu starten. Fehlt die Datei, gilt die beim Kompilieren
      gelesene Fassung;
    * `GET /zustand` — der ganze Zustand als JSON;
    * `GET /strom` — Server-Sent Events: jede Nachricht der Sicht als
      `data: {json}`, dazu alle 15 s eine Kommentarzeile, damit eine stille
      Verbindung von beiden Seiten als lebendig gilt.
  """

  import Plug.Conn

  alias Worker.Jack.Sicht

  @seite_pfad Path.expand("../../../../priv/jack/sicht.html", __DIR__)
  @external_resource @seite_pfad
  @seite File.read!(@seite_pfad)
  @takt_ms 15_000

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%Plug.Conn{method: "GET", request_path: "/"} = conn, _opts) do
    conn |> put_resp_content_type("text/html") |> ohne_cache() |> send_resp(200, seite())
  end

  def call(%Plug.Conn{method: "GET", request_path: "/zustand"} = conn, opts) do
    conn
    |> put_resp_content_type("application/json")
    |> ohne_cache()
    |> send_resp(200, Jason.encode_to_iodata!(Sicht.zustand(Keyword.fetch!(opts, :sicht))))
  end

  def call(%Plug.Conn{method: "GET", request_path: "/strom"} = conn, opts) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> ohne_cache()
      |> send_chunked(200)

    :ok = Sicht.abonnieren(Keyword.fetch!(opts, :sicht))
    senden(conn)
  end

  def call(conn, _opts), do: send_resp(conn, 404, "nicht gefunden")

  # Bis die Seite die Verbindung schließt.
  defp senden(conn) do
    stueck =
      receive do
        {:sicht, json} -> ["data: ", json, "\n\n"]
      after
        @takt_ms -> ": still\n\n"
      end

    case chunk(conn, stueck) do
      {:ok, conn} -> senden(conn)
      {:error, _geschlossen} -> conn
    end
  end

  defp seite do
    case File.read(@seite_pfad) do
      {:ok, html} -> html
      {:error, _} -> @seite
    end
  end

  defp ohne_cache(conn), do: put_resp_header(conn, "cache-control", "no-store")
end
