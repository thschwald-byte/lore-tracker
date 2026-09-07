defmodule Hub.MemoryReporter do
  @moduledoc """
  Issue #1087: periodische Speicher-Zeile im Prod-Log.

  Der Prod-Hub wurde binnen zwölf Tagen fünfzehnmal am Speicherlimit gekillt.
  Die Ursachensuche scheiterte daran, dass Gigalixir nur die **Tatsache** des
  Kills protokolliert, keinen Verlauf: aus den Logs war nicht zu entscheiden,
  ob der Speicher über Stunden stieg (Leck) oder binnen Sekunden sprang
  (Spitze). Diese Zeile macht aus „irgendwann tot" eine Kurve, die sich
  rückwirkend auswerten lässt — die Logs werden ohnehin nach `~/logs/`
  mitgeschrieben.

  Gemessen werden **zwei** Größen, und die Unterscheidung ist der Kern:

  - `:erlang.memory/0` — was der BEAM von sich selbst weiß.
  - die **Cgroup** (`/sys/fs/cgroup/memory.*`) — was der Kernel sieht und
    woran der Container stirbt. Die beiden weichen deutlich voneinander ab
    (live gemessen: BEAM 160 MB, Cgroup 242 MiB bei 381,5 MiB Limit), weil
    Allocator-Verschnitt, VM-Overhead und Seitencache nur in der zweiten Zahl
    stehen. Nur auf die BEAM-Zahl zu schauen, hätte die Ursache verfehlt.

  Dazu die Zahl der offenen LiveViews: der einzige belastbare Zusammenhang aus
  der Log-Auswertung war, dass **kein einziger** Kill in ein Zeitfenster ohne
  Zuschauer fiel (0 von 1494), während 13 in die 272 Fenster mit Zuschauern
  fielen. Ohne diese Spalte bliebe das eine Korrelation über Umwege.

  Reine Messung, kein Eingriff — ein Deckel oder Rückdruck wäre eine Maßnahme
  gegen eine noch unbewiesene Ursache.
  """
  use GenServer

  require Logger

  @default_interval_ms 30_000
  @cgroup_dir "/sys/fs/cgroup"
  # Ab diesem Anteil des Cgroup-Limits wird die Zeile zur Warnung. Kein
  # Eingriff, nur Sichtbarkeit: eine Warnung kurz vor dem Kill macht im
  # Nachhinein den Zusammenhang auffindbar.
  @warn_ratio 0.85
  @top_n 3

  # Issue #1163: ab diesem Zuwachs zwischen zwei Messungen wird die Zeile zur
  # Warnung — unabhängig vom Pegel. Der Wert ist an den Prod-Logs des
  # 2026-09-06 gemessen, nicht gegriffen: über 1778 Messintervalle folgte einem
  # Sprung ≥30 MB in 4 von 9 Fällen ein Kill innerhalb von 120 s (44 %), gegen
  # eine Grundwahrscheinlichkeit von 2 % — Faktor 22. Der Median-Anstieg liegt
  # bei +1 MB, das 95.-Perzentil bei +46 MB; ein Sprung dieser Größe ist also
  # kein Rauschen.
  #
  # EHRLICHE GRENZE, die zum Wert gehört: nur 4 von 20 Kills wurden so
  # angekündigt. Das Signal ist TREFFSICHER, aber UNEMPFINDLICH — es fängt rund
  # ein Fünftel. Wer hier nachschärft, muss beide Richtungen messen; eine
  # niedrigere Schwelle fängt mehr Kills und mehr Fehlalarme, und eine Warnung,
  # die oft und nutzlos leuchtet, wird weggeklickt (die #1124-Lektion).
  @sprung_mb 30

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Issue #1169: eine Messzeile zu einem benannten Ereignis — statt blind alle
  30 s zu messen, misst der Hub, wenn er weiss, dass gleich etwas passiert.

  Der Anlass: der Prod-Hub starb dreimal an einem Tag beim Öffnen der
  CampaignLive, jedes Mal neun Sekunden nach dem Mount. Die letzte Messung vor
  dem Kill war 21 Sekunden alt und völlig unauffällig. Alle Zahlen zur
  Ladespitze stammten von einer Teststage — es gab keine einzige aus Prod, und
  ein darauf gebauter Cut (C4) reichte nicht.

  **Cast, nicht Call**, damit die LiveView nie auf den Reporter wartet — und
  **ohne die Top-Prozesse**: deren Einsammeln legt einige hundert KB auf den
  Heap, und beim Mount ist der Speicher gerade knapp. Was bleibt (`:erlang.
  memory/0` plus vier Cgroup-Dateien) kostet praktisch nichts.

  Stirbt der Hub mitten im Read, steht die `voll_read_start`-Zeile trotzdem
  im Log. Das ist der Unterschied zu heute: „angefangen, nicht überlebt" statt
  21 Sekunden Stille. Danach kommt genau eine von zwei Zeilen — `voll_read_ok`
  mit `snapshot_words`, oder `voll_read_error` mit `reason` — nie eine
  „ok"-Zeile für einen Timeout. Beide tragen `anlass` (`mount`, `reload`,
  `workers_changed`): der Voll-Read läuft aus drei Stellen an, und nur eine
  davon ist ein Mount; ohne das Feld sähe ein Worker-Rejoin bei 16 Tabs wie
  16 Mounts aus (Review-Funde, PR #1180). Die dritte Zeile, `voll_read_rendered`,
  kommt NACH dem Render eines Apply (`kind` = `campaign`, `campaign_luecken`,
  `campaign_luecken_slice`) — dort entsteht die Spitze, nicht beim Read (#1181).
  Alle Zeilen aus der CampaignLive tragen `lv_heap_words`, den Heap des
  LiveView-Prozesses selbst, und `lv_pid` (#1185), damit bei mehreren Tabs
  zählbar ist, welche Zeile zu welchem gehört; die Cgroup-Werte sehen nur den
  ganzen Pod. Auf `voll_read_rendered` folgt seit #1185 ein GC im
  LiveView-Prozess und `voll_read_gc` — die Differenz der beiden Heaps ist
  Render-Müll, der Rest lebende Struktur.
  """
  @spec marke(String.t(), keyword()) :: :ok
  def marke(label, extra \\ []) when is_binary(label) do
    GenServer.cast(__MODULE__, {:marke, label, extra})
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get(opts, :interval_ms) ||
        Application.get_env(:hub, :memory_report_interval_ms, @default_interval_ms)

    # Jedes Feld, das eine Klausel später per Map-Update schreibt, MUSS hier
    # stehen — ein fehlender Key wirft KeyError und der GenServer stirbt in
    # einer Restart-Schleife (die Lehre aus #1005).
    state = %{
      interval: interval,
      cgroup_dir: Keyword.get(opts, :cgroup_dir, @cgroup_dir),
      timer: nil,
      # Issue #1163: der `cg_anon_mb` der VORIGEN Runde. `nil` heißt „noch keine
      # Vergleichsgröße" — die erste Runde nach dem Start kann keinen Sprung
      # melden, und ein angenommener Startwert von 0 erzeugte dort einen
      # Fehlalarm über die volle Grundlast.
      letzter_anon: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_cast({:marke, label, extra}, state) do
    mem = :erlang.memory()

    fields =
      [
        marke: label,
        total_mb: mb(mem[:total]),
        processes_mb: mb(mem[:processes]),
        binary_mb: mb(mem[:binary]),
        live_views: live_view_count(),
        reader_queue: Hub.Reader.queue_depth()
      ] ++ cgroup_fields(read_cgroup(state.cgroup_dir)) ++ extra

    log(fields)
    {:noreply, state}
  end

  @impl true
  def handle_info(:report, state) do
    fields = collect(state)
    log(fields)

    # Das Einsammeln aller Prozessinfos legt einige hundert KB auf den eigenen
    # Heap. Ohne das Aufräumen stünde dieser Prozess in seiner eigenen Top-3 —
    # und verdrängte dort genau die Prozesse, wegen derer die Zeile existiert.
    :erlang.garbage_collect()

    {:noreply, state |> merke_anon(fields) |> schedule()}
  end

  @impl true
  def terminate(_reason, state) do
    cancel(state.timer)
    :ok
  end

  defp schedule(state) do
    cancel(state.timer)
    %{state | timer: Process.send_after(self(), :report, state.interval)}
  end

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  @doc """
  Issue #1087: alle Messwerte einer Runde als Keyword-Liste, in der Reihenfolge
  der Log-Zeile. Public, damit sie ohne laufenden GenServer prüfbar ist.
  """
  @spec collect(map()) :: keyword()
  def collect(%{cgroup_dir: dir} = state) do
    mem = :erlang.memory()

    beam = [
      total_mb: mb(mem[:total]),
      processes_mb: mb(mem[:processes]),
      binary_mb: mb(mem[:binary]),
      ets_mb: mb(mem[:ets]),
      code_mb: mb(mem[:code]),
      procs: length(:erlang.processes()),
      live_views: live_view_count(),
      # Issue #1149: wie viele grosse Reads warten gerade auf ihren Platz?
      # Ohne diese Zahl ist ein Herd von einem ruhigen Moment nicht zu
      # unterscheiden — beide zeigen einen niedrigen Speicherstand, aber der
      # eine steht kurz vor der Spitze und der andere nicht.
      reader_queue: Hub.Reader.queue_depth()
    ]

    cg = cgroup_fields(read_cgroup(dir))

    # Issue #1163: der Zuwachs seit der letzten Runde, als EIGENES Feld. Auch
    # unterhalb der Warnschwelle steht er damit im Log — die Zeile beantwortet
    # sonst „wie voll ist es", aber nie „wie schnell füllt es sich", und genau
    # das ist die Frage, an der die Pegel-Warnung scheitert.
    beam ++ cg ++ delta_feld(cg, Map.get(state, :letzter_anon)) ++ [top: top_processes(@top_n)]
  end

  # Kein Feld statt einer erfundenen Null: fehlt der Vergleichswert (erste
  # Runde) oder die Cgroup-Zahl (Entwicklermaschine ohne echtes Limit), gibt es
  # keinen Sprung zu melden. `anon_delta_mb=0` hieße „gemessen, nichts
  # passiert" — das ist eine andere Aussage als „nicht messbar".
  defp delta_feld(cg, letzter) do
    case {Keyword.get(cg, :cg_anon_mb), letzter} do
      {a, l} when is_integer(a) and is_integer(l) -> [anon_delta_mb: a - l]
      _ -> []
    end
  end

  @doc false
  # Den `cg_anon_mb` dieser Runde für die nächste merken. Fehlt er, bleibt der
  # alte Wert stehen statt auf nil zu fallen — sonst verlöre ein einzelner
  # Lesefehler die Vergleichsgröße und die nächste Runde meldete keinen Sprung.
  def merke_anon(state, fields) do
    case Keyword.get(fields, :cg_anon_mb) do
      a when is_integer(a) -> %{state | letzter_anon: a}
      _ -> state
    end
  end

  @doc """
  Issue #1087: Cgroup-v2-Werte in Bytes. `%{}`, wenn kein **echtes** Limit
  gesetzt ist.

  Die Unterscheidung ist Absicht: im Container steht in `memory.max` eine Zahl,
  auf der Entwicklermaschine der String `"max"`. Ohne diese Prüfung stünden im
  Dev-Log die Speicherwerte des ganzen Rechners — Zahlen, die aussehen wie eine
  Messung, aber keine sind.
  """
  @spec read_cgroup(String.t()) :: map()
  def read_cgroup(dir) do
    case read_int(Path.join(dir, "memory.max")) do
      nil ->
        %{}

      limit ->
        %{
          limit: limit,
          current: read_int(Path.join(dir, "memory.current")),
          peak: read_int(Path.join(dir, "memory.peak")),
          anon: read_stat_key(Path.join(dir, "memory.stat"), "anon")
        }
    end
  end

  @doc "Issue #1087: Cgroup-Werte als Log-Felder; leer, wenn nicht messbar."
  @spec cgroup_fields(map()) :: keyword()
  def cgroup_fields(cg) when map_size(cg) == 0, do: []

  def cgroup_fields(cg) do
    [
      cg_limit_mb: mb(cg[:limit]),
      cg_used_mb: mb(cg[:current]),
      cg_peak_mb: mb(cg[:peak]),
      cg_anon_mb: mb(cg[:anon]),
      # Issue #1098: der Prozentwert rechnet auf `anon`, NICHT auf `current`.
      # `current` enthält den Seitencache, und den wirft der Kernel weg, bevor
      # er einen Prozess killt — an der ersten Prod-Messung sichtbar: im
      # Leerlauf, bei null Betrachtern, `current` 301 MB von 381 (79 %) gegen
      # `anon` 154 MB (40 %). Eine Warnschwelle auf `current` hätte ab Tag eins
      # dauerhaft geleuchtet und wäre damit genau dann übersehen worden, wenn
      # sie einmal etwas bedeutet. `current` und `peak` bleiben als Spalten
      # stehen — sie sind fürs Nachrechnen nützlich, nur nicht als Alarm.
      cg_pct: pct(cg[:anon], cg[:limit])
    ]
  end

  @doc """
  Issue #1087: Anteil des Limits in Prozent, oder `nil`. `nil` statt 0, weil
  „nicht messbar" und „nichts belegt" verschiedene Aussagen sind.

  Issue #1098: gefüttert wird das mit `anon`, nicht mit `current` — siehe
  `cgroup_fields/1`.
  """
  @spec pct(integer() | nil, integer() | nil) :: integer() | nil
  def pct(used, limit) when is_integer(used) and is_integer(limit) and limit > 0,
    do: round(used * 100 / limit)

  def pct(_, _), do: nil

  @doc """
  Issue #1087: die größten Prozesse mit Namen und Mailbox-Länge.

  Ohne Namen sagt eine Gesamtzahl beim nächsten Kill wieder nichts — die Frage
  wird sein, WER den Speicher hielt. Die Mailbox-Länge steht daneben, weil ein
  Stau dort die zweite plausible Bauform desselben Symptoms ist.
  """
  @spec top_processes(pos_integer()) :: String.t()
  def top_processes(n) do
    :erlang.processes()
    |> Enum.map(&process_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(n)
    |> Enum.map_join(",", fn {kb, name, qlen} -> "#{name}/#{kb}kb/q#{qlen}" end)
  end

  defp process_entry(pid) do
    case Process.info(pid, [:memory, :message_queue_len, :registered_name, :dictionary]) do
      nil ->
        nil

      info ->
        {div(info[:memory], 1024), process_name(pid, info), info[:message_queue_len]}
    end
  end

  defp process_name(pid, info) do
    case info[:registered_name] do
      name when is_atom(name) and not is_nil(name) ->
        name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

      _ ->
        case initial_call(info[:dictionary]) do
          {mod, _f, _a} -> mod |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
          _ -> inspect(pid)
        end
    end
  end

  @doc """
  Issue #1087: Zahl der offenen LiveView-Prozesse.

  Erkannt am **Prozess-Label**, das Phoenix beim Start eines LiveView-Channels
  setzt (`{Phoenix.LiveView, MeinLive, "lv:phx-…"}`). Naheliegender wäre
  `$initial_call` gewesen — das trägt aber das LiveView-**Modul**
  (`{HubWeb.EinstellungenLive, :mount, 3}`), nicht den Channel, und eine
  Erkennung darüber hätte jede neue Ansicht einzeln kennen müssen.

  Eine Registry gibt es nicht: Phoenix führt keine Liste offener LiveViews,
  und die internen Transport-Strukturen sind kein Vertrag. Das Label ist eine
  bewusst gesetzte Beobachtungshilfe — trotzdem ein Interna, deshalb mountet
  ein Test einen echten LiveView und prüft, dass er hier auftaucht. Ohne den
  Test meldete die Log-Zeile nach einem Phoenix-Update still dauerhaft 0.
  """
  @spec live_view_count() :: non_neg_integer()
  def live_view_count do
    Enum.count(:erlang.processes(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> live_view?(Keyword.get(dict, :"$process_label"))
        _ -> false
      end
    end)
  end

  defp live_view?({Phoenix.LiveView, _module, _id}), do: true
  defp live_view?(_), do: false

  defp initial_call(dict) when is_list(dict), do: Keyword.get(dict, :"$initial_call")
  defp initial_call(_), do: nil

  defp read_int(path) do
    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_stat_key(path, key) do
    with {:ok, content} <- File.read(path),
         line when is_binary(line) <-
           content |> String.split("\n") |> Enum.find(&String.starts_with?(&1, key <> " ")),
         [_, value] <- String.split(line, " ", parts: 2),
         {n, ""} <- Integer.parse(String.trim(value)) do
      n
    else
      _ -> nil
    end
  end

  defp mb(nil), do: nil
  defp mb(bytes) when is_integer(bytes), do: div(bytes, 1_048_576)

  defp log(fields) do
    line =
      fields
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)

    if warn?(fields) do
      Logger.warning("[telemetry] event=hub.memory #{line}")
    else
      Logger.info("[telemetry] event=hub.memory #{line}")
    end
  end

  @doc """
  Issue #1087: ab `@warn_ratio` des Cgroup-Limits wird die Zeile zur Warnung.
  Issue #1098: gemessen am nicht-reklamierbaren Anteil (`anon`), sonst warnt sie
  im Leerlauf.

  **Issue #1163: der Pegel allein reicht nicht — er kann per Konstruktion nicht
  warnen.** Am 2026-09-06 feuerte diese Warnung an einem Tag mit 77
  Kernel-Kills **kein einziges Mal**: 2180 Zeilen, null Warnungen, höchster
  Wert des Tages 81 % bei einer Schwelle von 85 % — und gleichzeitig
  `cg_peak_mb` 380 von 381. Der Sprung ins Limit passiert ZWISCHEN zwei
  Messungen.

  Eine niedrigere Schwelle löst das nicht: bei einem gemessenen Zuwachs von
  ~194 MB im gleitenden Sekundenfenster müsste sie unter 49 % liegen, während
  die Grundlast im Median bei 75 % liegt. **Es existiert kein Pegelwert, der
  beide Bedingungen erfüllt.**

  Deshalb kommt der **Sprung** als zweiter, unabhängiger Grund dazu. Er warnt
  ebenfalls nicht VORHER — bei 1,2 s von „ruhig" bis Kill reagiert niemand —,
  aber er beantwortet hinterher **dass** und **wodurch**, und das ist die
  Information, die bei jedem weiteren Cut fehlt.
  """
  @spec warn?(keyword()) :: boolean()
  def warn?(fields) do
    pegel_hoch?(fields) or sprung_gross?(fields)
  end

  defp pegel_hoch?(fields) do
    case Keyword.get(fields, :cg_pct) do
      p when is_integer(p) -> p >= round(@warn_ratio * 100)
      _ -> false
    end
  end

  defp sprung_gross?(fields) do
    case Keyword.get(fields, :anon_delta_mb) do
      d when is_integer(d) -> d >= @sprung_mb
      _ -> false
    end
  end

  @doc false
  @spec sprung_schwelle_mb() :: pos_integer()
  def sprung_schwelle_mb, do: @sprung_mb
end
