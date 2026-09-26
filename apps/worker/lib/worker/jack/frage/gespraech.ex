defmodule Worker.Jack.Frage.Gespraech do
  @moduledoc """
  Die Verläufe der offenen Frage-Gespräche (#850, Chat-Modus).

  Eine Frage im Modus „Frage" ist ein Lauf für sich. Im Modus „Chat" setzt
  jede Folgefrage auf dem Verlauf der vorigen auf — erst damit ergibt „und wer
  war noch dabei?" überhaupt einen Sinn.

  **Der Verlauf lebt im Worker, nicht im Hub.** Er ist die Nachrichtenliste
  eines Agentenlaufs (gut 100 KB nach wenigen Runden), und der Hub ist seit
  #164 zustandslos. Durch den Kanal ginge er bei jeder Frage zweimal.

  **Gehalten wird an einer Gesprächs-ID**, die der Hub beim Einschalten des
  Chat-Modus vergibt — nicht an der Lauf-ID: Die wechselt je Frage, sie ist
  Adresse und Abbruch-Handle. Jedes Einschalten vergibt eine neue ID; deshalb
  braucht das Ausschalten kein Aufräumen, das alte Gespräch verfällt.

  **Drei Riegel, alle gegen stilles Wachsen oder stille Verschlechterung:**

    * **Verfall** (`@ttl_ms`, 30 min): Wer das Fenster zuklappt, meldet sich
      nicht ab. Ohne Verfall bliebe jeder Verlauf bis zum Worker-Neustart
      liegen.
    * **Deckel** (`@max_gespraeche`): Beim Anlegen fliegt das älteste heraus,
      wenn es zu viele werden. Der Verlauf ist Arbeitsspeicher auf der
      Maschine, die daneben Whisper und die Pipeline fährt.
    * **Kompaktierung beendet das Gespräch.** Fasst der Agent seinen Verlauf
      zusammen, stehen die gelesenen Fakten nicht mehr wörtlich darin,
      sondern als Zusammenfassung — in genau dem Lauf, dessen Antwort eine
      Beleg-Plakette tragen soll. Dann lieber ein neues Gespräch als eine
      Antwort, deren Belege verschwimmen, ohne dass es jemand sieht.

  Der Zustand ist **flüchtig**: Ein Worker-Neustart verliert die Gespräche,
  die nächste Frage beginnt eins. Das ist dieselbe Zusage wie im Fenster
  („der Verlauf ist flüchtig"), nur eine Ebene tiefer.
  """

  use GenServer

  require Logger

  @ttl_ms 30 * 60_000
  @max_gespraeche 20
  @sweep_ms 5 * 60_000

  @typedoc "Was ein Folgelauf braucht: der angeheftete Auftrag und der Verlauf."
  @type stand :: %{auftrag: String.t(), verlauf: [map()]}

  @doc "Die Lebensdauer eines unbenutzten Gesprächs in Millisekunden."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "Wie viele Gespräche gleichzeitig gehalten werden."
  @spec max_gespraeche() :: pos_integer()
  def max_gespraeche, do: @max_gespraeche

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Der Stand eines Gesprächs, oder `nil` — auch für `nil` als ID (Modus
  „Frage"), damit der Aufrufer nicht unterscheiden muss.
  """
  @spec holen(String.t() | nil, GenServer.server()) :: stand() | nil
  def holen(id, server \\ __MODULE__)
  def holen(nil, _server), do: nil
  def holen(id, server) when is_binary(id), do: GenServer.call(server, {:holen, id})

  @doc """
  Merkt den Stand eines Gesprächs. Für `nil` als ID passiert nichts (Modus
  „Frage" führt kein Gespräch).
  """
  @spec merken(String.t() | nil, stand(), GenServer.server()) :: :ok
  def merken(id, stand, server \\ __MODULE__)
  def merken(nil, _stand, _server), do: :ok

  def merken(id, stand, server) when is_binary(id),
    do: GenServer.cast(server, {:merken, id, stand})

  @doc "Verwirft ein Gespräch. Unbekannte IDs sind kein Fehler."
  @spec verwerfen(String.t() | nil, GenServer.server()) :: :ok
  def verwerfen(id, server \\ __MODULE__)
  def verwerfen(nil, _server), do: :ok
  def verwerfen(id, server) when is_binary(id), do: GenServer.cast(server, {:verwerfen, id})

  @doc "Wie viele Gespräche gerade gehalten werden (für Tests und Telemetrie)."
  @spec anzahl(GenServer.server()) :: non_neg_integer()
  def anzahl(server \\ __MODULE__), do: GenServer.call(server, :anzahl)

  @doc """
  Gibt es ein Gespräch, das noch fortgesetzt werden kann? (#1259)

  **Der Selbstupdate-Riegel braucht das** (`Worker.Updater.idle?/0`): Zwischen
  zwei Fragen läuft kein GPU-Job, der Worker hielte sich für untätig und
  startete neu — und weil die Verläufe im Arbeitsspeicher leben, wäre der
  Zusammenhang danach still weg. Im Fenster stünde weiter „Chat max 3", und
  die nächste Antwort kennte die vorige Frage nicht.

  Gezählt wird gegen die Frist, nicht gegen die schiere Anwesenheit: Ein
  verfallener Eintrag, den der Sweep noch nicht geholt hat, ist kein Gespräch
  mehr — sonst hielte er das Update bis zu fünf Minuten länger auf, ohne dass
  es jemandem nützt.
  """
  @spec offen?(GenServer.server()) :: boolean()
  def offen?(server \\ __MODULE__), do: GenServer.call(server, :offen?)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}, {:continue, :takt}}
  end

  @impl true
  def handle_continue(:takt, state), do: {:noreply, takt(state)}

  @impl true
  def handle_call({:holen, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, %{stand: stand}} ->
        # Der Zugriff hält es am Leben: Verfallen soll, was niemand mehr
        # fortsetzt, nicht was lange dauert.
        {:reply, stand, Map.update!(state, id, &%{&1 | ts: jetzt()})}

      :error ->
        {:reply, nil, state}
    end
  end

  def handle_call(:anzahl, _from, state), do: {:reply, map_size(state), state}

  def handle_call(:offen?, _from, state) do
    grenze = jetzt() - @ttl_ms
    {:reply, Enum.any?(state, fn {_id, %{ts: ts}} -> ts >= grenze end), state}
  end

  @impl true
  def handle_cast({:merken, id, stand}, state) do
    {:noreply, state |> platz_schaffen(id) |> Map.put(id, %{stand: stand, ts: jetzt()})}
  end

  def handle_cast({:verwerfen, id}, state), do: {:noreply, Map.delete(state, id)}

  @impl true
  def handle_info(:sweep, state) do
    grenze = jetzt() - @ttl_ms
    {:noreply, state |> Map.reject(fn {_id, %{ts: ts}} -> ts < grenze end) |> takt()}
  end

  def handle_info(_anderes, state), do: {:noreply, state}

  # Der Timer-Ref liegt im Prozess-Wörterbuch, nicht im Zustand: Der ist eine
  # reine Gesprächs-Map (`id => Eintrag`), und ein Sonderschlüssel darin
  # müsste in `holen`, `merken` und dem Sweep überall mitgedacht werden.
  @impl true
  def terminate(_grund, _state) do
    if ref = Process.get(:sweep_ref), do: Process.cancel_timer(ref)
    :ok
  end

  defp takt(state) do
    if ref = Process.get(:sweep_ref), do: Process.cancel_timer(ref)
    Process.put(:sweep_ref, Process.send_after(self(), :sweep, @sweep_ms))
    state
  end

  # Ein neues Gespräch verdrängt das älteste, nicht ein zufälliges — sonst
  # träfe es gerade das, an dem jemand arbeitet.
  defp platz_schaffen(state, id) do
    if Map.has_key?(state, id) or map_size(state) < @max_gespraeche do
      state
    else
      {aeltester, _} = Enum.min_by(state, fn {_id, %{ts: ts}} -> ts end)
      Logger.info("Frage-Jack: Gespräch #{aeltester} verdrängt (Deckel #{@max_gespraeche})")
      Map.delete(state, aeltester)
    end
  end

  defp jetzt, do: System.monotonic_time(:millisecond)
end
