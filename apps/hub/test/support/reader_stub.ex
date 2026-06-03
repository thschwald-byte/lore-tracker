defmodule HubWeb.ReaderStub do
  @moduledoc """
  Test-Stub für `Hub.Reader` (Issue #66). Registriert sich unter dem Namen
  `Hub.Reader` und beantwortet jeden `{:read, scope, timeout}`-Call mit einer
  fixen Antwort (typischerweise `{:ok, snapshot}`) — so mounten LiveView-Tests
  ohne echten Worker.

  Wird via `HubWeb.ConnCase.stub_reader!/1` benutzt, das den supervisten echten
  `Hub.Reader` vorher aus dem Tree nimmt (sonst Name-Kollision).
  """

  use GenServer

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(reply), do: GenServer.start_link(__MODULE__, reply, name: Hub.Reader)

  @impl true
  def init(reply), do: {:ok, reply}

  @impl true
  # Issue #451 (Track B): Reader.read/2 schickt {:read, scope, worker_id, timeout}.
  def handle_call({:read, _scope, _worker_id, _timeout}, _from, reply),
    do: {:reply, reply, reply}
end
