defmodule Worker.Status.Router do
  @moduledoc """
  Issue #1218: der lesende Statusendpunkt. Ein Pfad, `GET /status`, JSON.

  **Er liest nur aus dem Arbeitsspeicher und fragt keinen GenServer, der
  blockieren kann.** Das ist keine Feinheit: `Worker.Discord.BotGate.status/0`
  liest aus demselben Grund den abgelegten Zustand statt den Prozess zu rufen
  (#475) — ein Leser, der hinter einem laufenden HTTP-Aufruf hängt, wird im
  Betrieb zum Blockierer. Eine Hardware-Anzeige fragt im Sekundentakt.
  """

  use Plug.Router

  alias Worker.Recording.Pipeline.Fortschritt
  alias Worker.Status.{Lage, Praesenz}

  plug(:match)
  plug(:dispatch)

  get "/status" do
    lage = Lage.baue(Fortschritt.alle(), aufnahme?(), Praesenz.lesen())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(lage))
  end

  match _ do
    send_resp(conn, 404, "")
  end

  # Aus Mnesia, nicht aus dem Recorder-Prozess: dieselbe Quelle, die am Hub
  # `/health/recording` speist (#703).
  defp aufnahme?, do: Worker.Repo.any_active_recording?() == true
end
