defmodule HubWeb.ReaderStub do
  @moduledoc """
  Test-Stub für `Hub.Reader` (Issue #66). Registriert sich unter dem Namen
  `Hub.Reader` und beantwortet jeden Lese-Call mit einer fixen Antwort
  (typischerweise `{:ok, snapshot}`) — so mounten LiveView-Tests ohne
  echten Worker.

  Wird via `HubWeb.ConnCase.stub_reader!/1` benutzt, das den supervisten echten
  `Hub.Reader` vorher aus dem Tree nimmt (sonst Name-Kollision).

  ## Issue #1149: warum die Klausel die Tupel-LÄNGE nicht festnagelt

  Der Stub matchte bis dahin auf die exakte innere Form
  (`{:read, scope, worker_id, timeout}`) — und war damit an ein **privates**
  Detail des Readers gekoppelt, das kein Vertrag ist. Sein eigener Moduledoc
  nannte bereits die vorletzte Form (`{:read, scope, timeout}`), ohne dass es
  jemandem aufgefallen wäre.

  Als die Warteschlange zwei Felder ergänzte, war die Folge kein sprechender
  Fehler, sondern ein `FunctionClauseError` **im Stub** — und zwar in rund
  zwanzig LiveView-Tests gleichzeitig, die alle aussahen, als sei die
  CampaignLive kaputt. Der Reader kam in keiner der Fehlermeldungen vor.

  Geprüft wird deshalb nur noch, dass es ein Lese-Call ist. Das hält den Stub
  gegen künftige Signaturänderungen stabil, ohne ihn stumpf zu machen: ein
  Call, der NICHT `:read` heißt, fällt weiterhin laut durch.
  """

  use GenServer

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(reply), do: GenServer.start_link(__MODULE__, reply, name: Hub.Reader)

  @impl true
  def init(reply), do: {:ok, reply}

  @impl true
  def handle_call(:queue_depth, _from, reply), do: {:reply, 0, reply}

  def handle_call(req, _from, reply) when is_tuple(req) and elem(req, 0) == :read,
    do: {:reply, antwort(reply, req), reply}

  # Issue #1198: eine Funktion als Antwort bekommt den Scope und kann je Scope
  # verschieden antworten — die Geglättet-Ansicht rechnet ihr Fenster im Worker,
  # ein Test braucht dafür eine andere Antwort als für den Haupt-Snapshot.
  # Gelesen wird Position 1 von `{:read, scope, …}`: der eine Teil der Form, auf
  # den sich jeder Aufrufer ohnehin verlässt; der Rest bleibt unangetastet.
  defp antwort(fun, req) when is_function(fun, 1), do: fun.(elem(req, 1))
  defp antwort(reply, _req), do: reply
end
