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
  `:protokoll`, `:ablage`, `:folgen`.

  **`folgen: verzeichnis`** — für einen Lauf in einem anderen BEAM: die Sicht
  liest alle `:folgen_ms` (Default 1000) die jüngste `protokoll.jsonl` unter
  dem Verzeichnis nach (auch in Unterverzeichnissen, etwa die Durchgänge
  eines Messlaufs) und die `stand.json` daneben. Ein neueres Protokoll
  (nächste Phase) löst das alte ab, dessen Rest vorher noch gelesen wird.
  Denken und Text erscheinen dann je Antwort, nicht Stück für Stück.

  **Ehrliche Grenzen:**
  - Token für Token sieht die Seite nur einen Lauf im selben BEAM. Einem
    Lauf in einem anderen BEAM folgt sie mit `folgen:` im Sekundentakt, je
    Antwort statt je Token; ohne `folgen:` zeigt sie nur den Stand seiner
    Dateien beim Start.
  - `mtime` hat Sekunden-Auflösung. Fällt die erste Zeile der nächsten Phase
    in dieselbe Sekunde wie die letzte der vorigen, wechselt die Sicht erst
    mit der nächsten Zeile.
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
      {:ok, _} ->
        folgen = folgen_start(opts[:folgen], Keyword.get(opts, :folgen_ms, 1000))

        {:ok, %{ref: ref, port: :ranch.get_port(ref), lage: lage, seiten: %{}, folgen: folgen}}

      {:error, grund} ->
        {:stop, {:port, grund}}
    end
  end

  defp folgen_start(nil, _ms), do: nil

  defp folgen_start(dir, ms) do
    send(self(), :folgen)
    %{wurzel: dir, ms: ms, datei: nil, offset: 0, stand_mtime: nil, timer: nil}
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

  def handle_info(:folgen, %{folgen: %{} = f} = st) do
    st = folgen(st)
    {:noreply, put_in(st.folgen.timer, Process.send_after(self(), :folgen, f.ms))}
  end

  def handle_info(_anderes, st), do: {:noreply, st}

  @impl true
  def terminate(_grund, st) do
    if st.folgen && st.folgen.timer, do: Process.cancel_timer(st.folgen.timer)
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

  # ─── Einem Lauf in einem anderen BEAM folgen ──────────────────────────

  defp folgen(%{folgen: f} = st) do
    st = if f.datei, do: nachlesen(st), else: st
    neueste = neuestes_protokoll(f.wurzel)

    st =
      if wechseln?(neueste, st.folgen.datei) do
        # Neue Phase: ihr Stand kommt aus ihrer eigenen stand.json, nicht aus
        # dem der vorigen — sonst stimmt „neu in diesem Lauf“ nicht.
        %{
          st
          | folgen: %{st.folgen | datei: neueste, offset: 0, stand_mtime: nil},
            lage: %{st.lage | stand: nil}
        }
        |> nachlesen()
      else
        st
      end

    stand_nachlesen(st)
  end

  # Nur ein echt jüngeres Protokoll löst ab; bei gleicher mtime bleibt die
  # Sicht bei ihrer Datei, statt zwischen zwei Phasen hin und her zu springen.
  defp wechseln?(nil, _datei), do: false
  defp wechseln?(_neueste, nil), do: true
  defp wechseln?(neueste, datei), do: neueste != datei and mtime(neueste) > mtime(datei)

  defp neuestes_protokoll(wurzel) do
    wurzel
    |> Path.join("**/protokoll.jsonl")
    |> Path.wildcard()
    |> Enum.max_by(&mtime/1, fn -> nil end)
  end

  defp mtime(pfad) do
    case File.stat(pfad, time: :posix) do
      {:ok, %{mtime: m}} -> m
      _ -> 0
    end
  end

  # Liest ab dem Versatz alle vollständigen Zeilen; eine halbe letzte Zeile
  # (der Lauf schreibt noch) bleibt für den nächsten Takt liegen.
  defp nachlesen(%{folgen: %{datei: datei, offset: offset}} = st) do
    with {:ok, io} <- File.open(datei, [:read, :binary]),
         {:ok, _} <- :file.position(io, offset),
         daten when is_binary(daten) <- IO.binread(io, :eof) do
      File.close(io)
      zeilen = String.split(daten, "\n")
      rest = List.last(zeilen)
      st = zeilen |> Enum.drop(-1) |> Enum.reduce(st, &zeile_folgen/2)
      put_in(st.folgen.offset, offset + byte_size(daten) - byte_size(rest))
    else
      _ -> st
    end
  end

  defp zeile_folgen(zeile, st) do
    case Jason.decode(zeile) do
      {:ok, %{} = d} -> anwenden(st, &Lage.ereignis/2, d)
      _ -> st
    end
  end

  defp stand_nachlesen(%{folgen: %{datei: nil}} = st), do: st

  defp stand_nachlesen(%{folgen: f} = st) do
    pfad = f.datei |> Path.dirname() |> Path.join("stand.json")
    m = mtime(pfad)

    with true <- m != 0 and m != f.stand_mtime,
         {:ok, text} <- File.read(pfad),
         {:ok, %{} = abbild} <- Jason.decode(text) do
      st |> anwenden(&Lage.stand/2, abbild) |> put_in([:folgen, :stand_mtime], m)
    else
      _ -> st
    end
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
