defmodule Worker.Telemetry do
  @moduledoc """
  Issue #542: die Signale, die heute still bleiben, laut machen.

  Der Hub hat seit #238 strukturierte Telemetrie (`Hub.Telemetry`) — der
  Worker hatte **keine einzige Stelle**, obwohl fünf der sechs in #542
  benannten Signale Worker-Signale sind. Das ist der Grund, warum ein
  Self-Update-Zombie (#512) einmal 1h15m unbemerkt lief und warum der
  Watchdog-Vollzug bei jedem Update (#1048) nur auffiel, weil zufällig
  jemand in `coredumpctl` sah.

  ## Was gezählt wird

  | Signal | Bedeutung | Schwelle |
  |---|---|---|
  | `:task_crash` | ein Task unter `Worker.TaskSupervisor` ist gestorben | ab 1 laut |
  | `:unbekannter_event_kind` | ein Event-Kind, für den es keinen Fold gibt | ab 1 laut |
  | `:pipeline_fehler` | eine Pipeline-Stufe ist gescheitert | ab 5 laut |
  | `:publish_stau` | Rückstand ungesendeter Ereignisse (aus `worker_state`) | wächst er, laut |

  ## Warum eine Logzeile und kein Panel

  Die Akzeptanz von #542 lässt beides zu („`/admin`-Panel ODER periodischer
  Self-Report"). Die Logzeile ist hier die richtige Wahl: sie folgt dem
  bestehenden `[telemetry] event=… key=value`-Format aus #238, ist über
  `journalctl`/`grep`/`awk` auswertbar, und sie funktioniert **auch dann,
  wenn der Hub nicht erreichbar ist** — also genau in der Lage, in der die
  meisten dieser Signale entstehen. Ein Panel bräuchte einen Snapshot-Scope
  und damit eine lebende Verbindung zum Hub.

  ## Gemeldet wird nur, wenn etwas passiert ist

  Ein Takt-Report „alles null" alle 60 Sekunden wäre in einem Log, das über
  Tage läuft, reines Rauschen — und Rauschen ist der Mechanismus, durch den
  ein echtes Signal übersehen wird (dieselbe Lehre wie bei der
  Speicher-Schwelle in #1098: an `memory.current` gemessen hätte sie ab Tag
  eins dauerhaft geleuchtet und wäre genau dann übersehen worden, wenn sie
  einmal etwas bedeutet). Ist im Fenster nichts vorgefallen, schweigt der
  Reporter.

  ## Ehrliche Grenzen

  - **Die Zähler leben im Arbeitsspeicher.** Ein Worker-Neustart setzt sie
    zurück. Für Raten-Signale („K Crashes je Fenster") ist das richtig, für
    eine Gesamtbilanz über Tage taugt es nicht. Der Rückstand
    (`:publish_stau`) ist davon ausgenommen — der liegt seit #475 persistent
    in `worker_state`.
  - **Ein Neustart ist selbst kein Signal.** Stirbt der Worker, verschwindet
    der Reporter mit ihm; dass er lief, steht nur in den bis dahin
    geschriebenen Zeilen. Der Watchdog-Vollzug (#1048) wird deshalb aus dem
    Bootpfad gemeldet, nicht von hier.
  - **Task-Crashes werden über den Logger gezählt, nicht über Telemetrie.**
    `Task.Supervisor` sendet kein Telemetrie-Ereignis; gezählt wird der
    Absturzbericht, den OTP ohnehin schreibt (`Worker.Telemetry.Absturz`).
    Ein Absturz, den OTP nicht als Bericht formuliert, wird nicht gezählt.
  """

  use GenServer
  require Logger

  @signale [:task_crash, :unbekannter_event_kind, :pipeline_fehler]

  # Ab wie vielen Vorfällen im Fenster die Zeile zur Warnung wird. Ein
  # abgestürzter Task und ein unbekannter Event-Kind sind Einzelfälle, die
  # niemand erwartet — beide ab dem ersten Mal laut. Pipeline-Fehler stehen
  # ohnehin einzeln in `/admin/errors` (#716) und sind bei langen Läufen
  # nicht ungewöhnlich; sie werden erst in Häufung zur Warnung.
  @schwellen %{task_crash: 1, unbekannter_event_kind: 1, pipeline_fehler: 5}

  @doc "Signale dieses Moduls — auch die Quelle für Tests."
  @spec signale() :: [atom()]
  def signale, do: @signale

  @doc "Schwellenwerte je Signal (Vorfälle je Fenster, ab denen gewarnt wird)."
  @spec schwellen() :: %{atom() => pos_integer()}
  def schwellen, do: @schwellen

  @doc """
  Einen Vorfall zählen. Feuer-und-vergiss: ein `cast`, der im heißen Pfad
  nichts kostet und nie scheitert — läuft der Reporter nicht (Tests,
  Mix-Tasks, ein Boot vor seinem Start), verfällt der Ruf still.

  **Der Ruf loggt nichts.** Jeder dieser Vorfälle wird an seiner Entstehung
  bereits geschrieben: ein Task-Absturz als OTP-Bericht, ein unbekannter
  Ereignis-Typ als `Logger.warning` direkt daneben, ein Pipeline-Fehler als
  Eintrag in `/admin/errors`. Eine zweite Zeile je Vorfall wäre Wiederholung
  — und bei einer Fehlerserie (ein Gap-Fill-Lauf hat hunderte Blöcke) würde
  sie genau das Log fluten, in dem der Vorfall gefunden werden soll. Der
  Mehrwert liegt in der **Häufung und der Schwelle**, nicht in der
  Wiederholung.

  `quelle:` in `meta` wird als Menge gesammelt und im Fenster-Bericht
  genannt, damit „drei Abstürze" nicht bedeutungslos bleibt.
  """
  @spec zaehle(atom(), keyword()) :: :ok
  def zaehle(signal, meta \\ []) when is_atom(signal) do
    GenServer.cast(__MODULE__, {:zaehle, signal, meta[:quelle]})
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec stand() :: %{atom() => non_neg_integer()}
  def stand, do: GenServer.call(__MODULE__, :stand)

  # Wieviel Zeit nach der Backstop-Frist noch als normaler Abgang gilt:
  # systemd wartet vor dem Neustart (heute gemessen 15 s) und der Boot
  # selbst braucht ein paar Sekunden. Grosszügig gewählt — die Frage ist
  # „hat der Halt gehangen", und ein hängender Halt überschreitet das
  # deutlich (im Fall vom 17.09. 70 s gegen 45 s Schwelle).
  @abgang_puffer_ms 30_000

  @doc """
  Issue #542, Signal 4: berichtet, wie der **vorherige** Lauf geendet hat.

  Ein Worker, der stirbt, meldet nichts mehr — erzählen kann es nur sein
  Nachfolger. Gerufen wird das beim Start, nachdem Mnesia bereitsteht.

  Drei Fälle:

  - **Kein vorheriger Lauf** — der allererste Start. Still.
  - **Abgang ohne Ankündigung** — der letzte Lauf hat `halt_node/1` nie
    erreicht: abgestürzt, vom Kernel abgeräumt, hart abgeschossen. Laut.
  - **Angekündigter Abgang** — die Dauer bis zum neuen Start sagt, ob er
    durchkam. Über der Backstop-Frist plus Puffer hat der Backstop nicht
    gegriffen (#1048, #776-Nachtrag). Laut.

  Der Zeitvergleich läuft über die Wanduhr, nicht über die monotone Uhr —
  sie ist die einzige, die einen Neustart überdauert. Eine verstellte Uhr
  verfälscht die Zahl also; für „hing der Halt eine Minute" reicht das.
  """
  @spec melde_vorherigen_abgang() :: :ok
  def melde_vorherigen_abgang do
    vorheriger_lauf = Worker.Repo.get_state(:lauf_begonnen_at)
    angekuendigt = Worker.Repo.get_state(:halt_angekuendigt_at)
    jetzt = System.system_time(:millisecond)

    beurteile_abgang(vorheriger_lauf, angekuendigt, jetzt)

    Worker.Repo.put_state(:lauf_begonnen_at, jetzt)
    Worker.Repo.put_state(:halt_angekuendigt_at, nil)
    :ok
  rescue
    # Der Bootpfad darf an einer Beobachtung nicht scheitern.
    e ->
      Logger.warning("Worker.Telemetry: Abgangs-Bericht übersprungen (#{inspect(e)})")
      :ok
  end

  defp beurteile_abgang(nil, _angekuendigt, _jetzt), do: :ok

  defp beurteile_abgang(_lauf, nil, _jetzt) do
    Logger.warning(
      "[telemetry] event=worker.abgang art=unangekuendigt — der vorherige Lauf hat den " <>
        "geordneten Halt nie erreicht (Absturz, OOM oder hart beendet)"
    )
  end

  defp beurteile_abgang(_lauf, angekuendigt, jetzt) when is_integer(angekuendigt) do
    dauer = jetzt - angekuendigt
    schwelle = Worker.Lifecycle.halt_grace_ms() + @abgang_puffer_ms

    if dauer > schwelle do
      Logger.warning(
        "[telemetry] event=worker.abgang art=haengend dauer_ms=#{dauer} schwelle_ms=#{schwelle} " <>
          "— der Halt kam nicht durch und der Backstop hat nicht gegriffen (#1048)"
      )
    else
      Logger.info("[telemetry] event=worker.abgang art=geordnet dauer_ms=#{dauer}")
    end
  end

  defp beurteile_abgang(_lauf, _angekuendigt, _jetzt), do: :ok

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Worker.Telemetry.Absturz.anhaengen()
    {:ok, leerer_stand(), {:continue, :takt}}
  end

  @impl true
  def handle_continue(:takt, state) do
    {:noreply, plane_takt(state)}
  end

  @impl true
  def handle_cast({:zaehle, signal, quelle}, state) do
    # Ein unbekanntes Signal wird trotzdem gezählt statt verworfen: ein
    # Tippfehler am Aufrufer soll auffallen, nicht verschwinden.
    {:noreply, state |> Map.update(signal, 1, &(&1 + 1)) |> merke_quelle(quelle)}
  end

  @impl true
  def handle_call(:stand, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:takt, state) do
    state = plane_takt(state)
    stau = rueckstand()
    melde(state, stau, Map.get(state, :__stau__))
    # Rückstand und Zeitgeber gelten über das Fenster hinaus — der eine ist
    # ein Stand statt eines Vorfalls und wird als Vergleichspunkt gebraucht,
    # der andere ist der nächste Takt selbst. Zähler und Quellen beginnen
    # bei null.
    {:noreply,
     leerer_stand()
     |> Map.put(:__stau__, stau)
     |> Map.put(:__timer__, Map.get(state, :__timer__))}
  end

  def handle_info(_andere, state), do: {:noreply, state}

  # ─── Intern ──────────────────────────────────────────────────────

  defp leerer_stand, do: @signale |> Map.new(&{&1, 0}) |> Map.put(:__quellen__, [])

  # Höchstens fünf verschiedene Quellen je Fenster. Ohne Deckel wüchse die
  # Liste bei einer Absturzschleife mit wechselnden Prozessnamen unbegrenzt
  # mit — im Zustand eines Prozesses, der genau dann leben muss, wenn etwas
  # schiefgeht.
  defp merke_quelle(state, nil), do: state

  defp merke_quelle(state, quelle) do
    Map.update(state, :__quellen__, [quelle], fn vorhandene ->
      cond do
        quelle in vorhandene -> vorhandene
        length(vorhandene) >= 5 -> vorhandene
        true -> vorhandene ++ [quelle]
      end
    end)
  end

  # Der laufende Zeitgeber wird abgeräumt, bevor ein neuer gesetzt wird.
  # Ohne das entstünde bei jedem von aussen geschickten `:takt` ein zweiter
  # Zeitgeber neben dem geplanten, und der Reporter meldete mit der Zeit
  # immer häufiger — in den Tests, die `:takt` genau so auslösen, ist das
  # kein Randfall, sondern der Normalfall.
  defp plane_takt(state) do
    if ref = Map.get(state, :__timer__), do: Process.cancel_timer(ref)
    ref = Process.send_after(self(), :takt, Worker.Settings.get(:telemetry_report_ms, 60_000))
    Map.put(state, :__timer__, ref)
  end

  # Der Rückstand ungesendeter Ereignisse liegt seit #475 persistent im
  # worker_state. Beim Boot kann Mnesia noch nicht bereit sein — dann ist
  # „unbekannt" richtig und 0 falsch, aber 0 ist hier folgenlos: gemeldet
  # wird erst der Anstieg gegen den vorherigen Wert.
  defp rueckstand do
    case Worker.Repo.get_state(:pending_publish_count) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp melde(state, stau, stau_vorher) do
    zaehler = Map.take(state, @signale)
    vorfaelle = zaehler |> Map.values() |> Enum.sum()

    # Der erste Takt nach dem Start hat keinen Vergleichspunkt: „vorher
    # unbekannt" ist nicht „vorher null". Ohne diese Unterscheidung meldete
    # JEDER Worker-Neustart einen Anstieg von 0 auf den bestehenden
    # Rückstand — ein Fehlalarm genau in dem Moment, in dem ohnehin viel
    # passiert. Gefunden vom Test, nicht gedacht.
    stau_delta = if is_integer(stau_vorher), do: stau - stau_vorher, else: 0

    cond do
      vorfaelle == 0 and stau_delta <= 0 ->
        :ok

      laut?(zaehler, stau_delta) ->
        Logger.warning("[telemetry] event=worker.signale #{zeile(state, stau, stau_delta)}")

      true ->
        Logger.info("[telemetry] event=worker.signale #{zeile(state, stau, stau_delta)}")
    end
  end

  @doc """
  Wird die Meldung eine Warnung? Ein wachsender Rückstand heisst: der Worker
  sammelt Ereignisse, die er nicht loswird — typisch ein Hub, der nicht
  erreichbar ist. Das ist die Lage, für die #542 den Alarm ausdrücklich
  verlangt.

  Öffentlich, damit die Schwellen prüfbar sind, ohne einen Prozess zu
  starten und Logzeilen abzufangen.
  """
  @spec laut?(%{atom() => non_neg_integer()}, integer()) :: boolean()
  def laut?(zaehler, stau_delta) do
    stau_delta > 0 or
      Enum.any?(zaehler, fn {s, n} -> is_integer(n) and n >= Map.get(@schwellen, s, 1) end)
  end

  defp zeile(state, stau, stau_delta) do
    fenster_s = div(Worker.Settings.get(:telemetry_report_ms, 60_000), 1000)

    quellen =
      case Map.get(state, :__quellen__, []) do
        [] -> []
        liste -> [quellen: Enum.join(liste, ",")]
      end

    felder =
      Enum.map(@signale, &{&1, Map.get(state, &1, 0)}) ++
        quellen ++
        [publish_stau: stau, publish_stau_delta: stau_delta, fenster_s: fenster_s]

    felder(felder)
  end

  defp felder(kv), do: Enum.map_join(kv, " ", fn {k, v} -> "#{k}=#{v}" end)
end
