defmodule Worker.Jack.Sicht do
  @moduledoc """
  Die lokale Laufsicht (#1202): eine Seite auf `127.0.0.1`, die in Echtzeit
  zeigt, was ein Jack-Lauf tut. Vorbild ist `schauen.py` aus dem Spike, aber
  ohne Nachfragen im Takt (Tom: „Echtzeit“).

  Der Prozess ist Beobachter der Laufzeit (`Worker.Agent.laufen/1`, Option
  `:beobachter`) und des Halters (`Worker.Jack.Halter`, Option `:beobachter`).
  Jedes Ereignis geht sofort über Server-Sent Events (`/strom`) an alle
  offenen Seiten. Denken und Text kommen Token für Token, weil die Laufzeit
  mit Beobachter streamt. Beim Verbinden und nach jeder Unterbrechung holt
  die Seite den ganzen Zustand (`/zustand`); was dazwischen geschah, geht so
  nicht verloren.

      {:ok, sicht} = Worker.Jack.Sicht.start_link(port: 8098)
      {:ok, halter} = Worker.Jack.Halter.start_link(stand, beobachter: sicht, ablage: dir)

      Worker.Agent.laufen(
        modell: …, system: …, nachrichten: …,
        werkzeuge: Worker.Jack.Werkzeuge.fuer(halter),
        beobachter: sicht,
        protokoll: Path.join(dir, "protokoll.jsonl")
      )

  Ein beendeter Lauf lässt sich aus seinem Verzeichnis zeigen, über die
  Optionen `:protokoll` und `:ablage` oder `mix lore.jack.schauen`.

  Optionen: `:port` (Default 8098; auf 8099 läuft die Spike-Sicht),
  `:protokoll`, `:ablage`.

  **Ehrliche Grenzen:**
  - Live sieht die Seite nur einen Lauf im selben BEAM. Ein Lauf in einem
    anderen BEAM erscheint nur als Stand seiner Dateien beim Start, ohne
    Deltas.
  - Die Seite bindet nur an Loopback, weil ein Lauf den Mitschnitt der
    echten Runde enthält.
  """

  use GenServer

  require Logger

  alias Worker.Jack.Sicht.Lage

  @port 8098

  @doc "Startet Sicht und Webserver. Ein belegter Port ist `{:error, {:port, grund}}`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Der Port, auf dem die Seite läuft (bei `port: 0` der vergebene)."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(sicht), do: GenServer.call(sicht, :port)

  @doc "Der ganze Zustand, wie ihn `/zustand` liefert."
  @spec zustand(GenServer.server()) :: map()
  def zustand(sicht), do: GenServer.call(sicht, :zustand)

  @doc "Wie viele Seiten gerade offen sind."
  @spec seiten(GenServer.server()) :: non_neg_integer()
  def seiten(sicht), do: GenServer.call(sicht, :seiten)

  @doc "Meldet den aufrufenden Prozess als offene Seite an; er bekommt `{:sicht, json}`."
  @spec abonnieren(GenServer.server()) :: :ok
  def abonnieren(sicht), do: GenServer.call(sicht, {:abonnieren, self()})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ref = :"jack_sicht_#{System.unique_integer([:positive])}"
    lage = Lage.neu() |> vorlesen(opts[:protokoll]) |> stand_lesen(opts[:ablage])

    case Plug.Cowboy.http(Worker.Jack.Sicht.Plug, [sicht: self()],
           ip: {127, 0, 0, 1},
           port: Keyword.get(opts, :port, @port),
           ref: ref,
           # Der Strom sendet nur; ohne das schlösse Cowboy ihn nach 60 s.
           protocol_options: [idle_timeout: :infinity]
         ) do
      {:ok, _} -> {:ok, %{ref: ref, port: :ranch.get_port(ref), lage: lage, seiten: %{}}}
      {:error, grund} -> {:stop, {:port, grund}}
    end
  end

  @impl true
  def handle_call(:port, _von, st), do: {:reply, st.port, st}
  def handle_call(:zustand, _von, st), do: {:reply, Lage.zustand(st.lage), st}
  def handle_call(:seiten, _von, st), do: {:reply, map_size(st.seiten), st}

  def handle_call({:abonnieren, pid}, _von, st),
    do: {:reply, :ok, %{st | seiten: Map.put(st.seiten, pid, Process.monitor(pid))}}

  @impl true
  def handle_info({:agent, daten}, st) when is_map(daten),
    do: {:noreply, anwenden(st, &Lage.ereignis/2, daten)}

  def handle_info({:jack_stand, abbild}, st) when is_map(abbild),
    do: {:noreply, anwenden(st, &Lage.stand/2, abbild)}

  def handle_info({:DOWN, _ref, :process, pid, _grund}, st),
    do: {:noreply, %{st | seiten: Map.delete(st.seiten, pid)}}

  def handle_info(_anderes, st), do: {:noreply, st}

  @impl true
  def terminate(_grund, st) do
    Plug.Cowboy.shutdown(st.ref)
    :ok
  end

  defp anwenden(st, fun, daten) do
    {lage, nachrichten} = fun.(st.lage, daten)
    if st.seiten != %{}, do: Enum.each(nachrichten, &verteilen(st, &1))
    %{st | lage: lage}
  end

  defp verteilen(st, nachricht) do
    json = Jason.encode_to_iodata!(nachricht)
    Enum.each(Map.keys(st.seiten), &send(&1, {:sicht, json}))
  rescue
    e -> Logger.warning("Jack-Sicht: Nachricht nicht als JSON sendbar: #{Exception.message(e)}")
  end

  # ─── Ein beendeter Lauf aus seinen Dateien ────────────────────────────

  defp vorlesen(lage, nil), do: lage

  defp vorlesen(lage, pfad) do
    if File.exists?(pfad),
      do: pfad |> File.stream!() |> Enum.reduce(lage, &zeile_lesen/2),
      else: lage
  end

  # Eine Zeile, die kein JSON-Objekt ist (etwa abgeschnitten, weil der Lauf
  # noch schreibt), wird übergangen.
  defp zeile_lesen(zeile, lage) do
    case Jason.decode(zeile) do
      {:ok, %{} = d} -> lage |> Lage.ereignis(d) |> elem(0)
      _ -> lage
    end
  end

  # Beim Nachlesen ist nur der Endstand bekannt, nicht der Bestand zu Beginn;
  # „neu in diesem Lauf“ bliebe sonst bei 0 stehen und wäre falsch.
  defp stand_lesen(lage, nil), do: lage

  defp stand_lesen(lage, dir) do
    pfad = Path.join(dir, "stand.json")

    with true <- File.exists?(pfad),
         {:ok, %{} = abbild} <- pfad |> File.read!() |> Jason.decode() do
      {lage, _} = Lage.stand(lage, abbild)
      put_in(lage.lauf["bestand_start"], nil)
    else
      _ -> lage
    end
  end
end
