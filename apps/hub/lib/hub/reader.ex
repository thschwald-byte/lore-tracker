defmodule Hub.Reader do
  @moduledoc """
  Coordinates `snapshot_request`/`snapshot_response` round-trips between
  Hub-side callers (LiveViews) and connected workers.

  - `read/2` picks the most-up-to-date connected worker from
    `Hub.WorkerRegistry`, generates a request_id, hands the request to
    that worker's channel pid, and blocks until the worker pushes a
    `snapshot_response` back (or the timeout fires).
  - LiveView callers should treat `{:error, :no_worker}` as the
    "Warte auf Worker" condition.

  ## Issue #146: Worker-Iteration

  Wenn der gewählte Worker mit `%{"forbidden" => true}` oder
  `%{"not_found" => true}` antwortet (oder gar nicht in `@per_attempt_timeout`
  ms), probiert der Reader automatisch den nächsten Worker (sortiert nach
  `applied_seq` desc). Maximal `@max_attempts` Versuche. Damit kann
  Spielleiter X auch einladen wenn ihr „eigener" Worker offline ist und
  ein anderer connecter Worker die Campaign via Pull-Sync materialisiert
  hat.

  Bei single-Worker-Setup keine Verhaltens-Änderung: eine Iteration,
  gesamter Maximal-Wait `@max_attempts * @per_attempt_timeout` ms.

  ## Issue #366: deterministische Worker-Wahl pro Viewer

  Die Kandidaten-Reihenfolge ist deterministisch (`applied_seq` desc, Tie-Breaker
  `id` asc — identisch zu `Hub.Commands.pick_leader`). Damit „switcht" eine
  per-User-LiveView nicht mehr zwischen zwei Reloads zwischen verschiedenen
  Workern. Zwei Targeting-Opts steuern die Reihenfolge:

  - `worker_id:` (binary) — **Hard-Pin** auf genau diesen Worker (ein Kandidat,
    kein Fallback). Für per-Worker-lokalen State wie `/settings` (Issue #451),
    wo ein Fallback auf einen *fremden* Worker semantisch falsch wäre.
  - `prefer_discord_id:` (binary) — **prefer-own-fallback-to-rest**: die Worker
    des Viewers (`admin_discord_id`-Match) zuerst, der Rest als Fallback-Kaskade.
    Für Admin-Views (`/admin/users|spend|errors|jobs|probelauf`), die bevorzugt
    den eigenen Worker lesen, aber bei dessen Ausfall verfügbar bleiben sollen.

  Ohne beide Opts: die deterministisch sortierte Voll-Liste (unverändertes
  Default-Verhalten, nur ohne die frühere instabile Insertion-Order).

  ## Issue #1149: Warteschlange für die großen Reads

  Von den drei Kampagnen-weiten Scopes (`@serialized_kinds`) läuft **immer nur
  einer**. Der Auslöser ist gemessen (#1146): nach einem OOM-Kill wächst der
  Browser-Reconnect-Backoff, dann verbinden sich alle Tabs und der Worker
  gleichzeitig; `workers_changed` löst in jeder offenen CampaignLive einen
  Voll-Read aus. Bis zu 16 Snapshots à 3,3 MB laufen dann parallel durch
  denselben Hub — der stirbt daran, der Backoff wächst weiter, und der
  Kreislauf schließt sich.

  Die Schlange bricht ihn: aus 16 gleichzeitigen Spitzen wird eine Folge von
  16 einzelnen. **Die Gesamtdauer steigt, der Höchststand nicht** — das ist der
  ganze Zweck, und zugleich der Preis.

  Alle übrigen Scopes bleiben unverändert parallel. Sie sind klein; sie zu
  serialisieren würde Wartezeit erzeugen, ohne Speicher zu sparen.

  `read/2` nimmt dafür ein zusätzliches `notify: pid` entgegen: der Reader
  meldet `{:reader_queued, kind, position}` beim Einreihen und beim
  Weiterrücken, `{:reader_started, kind}` sobald der Read läuft. Best-effort —
  ohne `notify:` verhält sich alles exakt wie zuvor.

  **Zusage an den Aufrufer:** der Reader antwortet immer innerhalb von
  `@queue_max_wait + @default_timeout`. Wer zu lange in der Schlange steht,
  bekommt `{:error, :queue_timeout}` — und ausdrücklich **keinen**
  automatischen Neuversuch, sonst ersetzte ein Timeout-Kreislauf den
  Kill-Kreislauf.

  **Ehrliche Grenzen:** Es gibt kein Dedup — zwei Tabs derselben Kampagne
  lesen denselben Snapshot zweimal nacheinander (das wäre der geteilte
  Kampagnen-Snapshot, eigenes Ticket). Und ein langsamer Read blockiert die
  Schlange: Kopfblockade, gedeckelt durch die Frist, nicht verhindert.
  """

  use GenServer

  require Logger

  # Issue #50: per_attempt 1500ms war zu eng wenn der Worker gerade unter
  # Ollama-Last steht (z.B. parallel laufender Pipeline auf einer anderen
  # PR-Test-Instance). 5000ms ist die neue Untergrenze.
  @max_attempts 3
  @per_attempt_timeout 5_000
  @default_timeout @max_attempts * @per_attempt_timeout

  # Issue #1149: die drei Kampagnen-weiten Listen-Scopes. Gemessen sind zwei
  # davon: `campaign` 3,3 MB, `campaign_luecken` 2,4 MB. `campaign_facts` steht
  # hier, weil es dieselbe Bauart hat (eine Liste über die ganze Kampagne, ohne
  # Fenster) — nicht, weil seine Größe gemessen wäre.
  #
  # `campaign_utterances` ist bewusst NICHT dabei: es ist der Nachlade-Scope
  # des #1087-Fensters und liefert eine feste Zahl Zeilen. Es zu serialisieren
  # würde das Scrollen hinter die grossen Reads stellen — spürbare Zähigkeit
  # ohne Speichergewinn.
  @serialized_kinds ~w(campaign campaign_luecken campaign_facts)

  # Deckel für die Wartezeit in der Schlange. Zusammen mit @default_timeout
  # ergibt er die Zusage, auf der die Aufrufer-Frist beruht: der Reader
  # antwortet IMMER innerhalb von @queue_max_wait + @default_timeout.
  @queue_max_wait 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec read(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(scope, opts \\ []) when is_map(scope) do
    serialized? = serialized?(scope)

    # Issue #1149: der Aufrufer darf nicht sterben, bevor der Reader antwortet.
    # In der Schlange kommt bis zu @queue_max_wait Wartezeit VOR dem
    # eigentlichen Read dazu; ohne diesen Zuschlag stürbe der `GenServer.call`
    # mit einem Timeout-Exit, und der Aufrufer sähe einen Absturz statt einer
    # Antwort. Ein ausdrücklich übergebenes `:timeout` gewinnt weiterhin —
    # dann gilt die Zusage oben allerdings nicht mehr.
    default = if serialized?, do: @queue_max_wait + @default_timeout, else: @default_timeout
    timeout = Keyword.get(opts, :timeout, default)

    # Issue #366: nur die Targeting-Keys an den GenServer reichen.
    pick_opts = Keyword.take(opts, [:worker_id, :prefer_discord_id])
    notify = Keyword.get(opts, :notify)

    GenServer.call(__MODULE__, {:read, scope, pick_opts, notify, serialized?}, timeout + 500)
  end

  @doc "Called by WorkerChannel when a snapshot_response arrives."
  def handle_response(request_id, payload) do
    GenServer.cast(__MODULE__, {:response, request_id, payload})
  end

  @doc """
  Issue #1149: gehört dieser Scope in die Warteschlange?

  Pure Funktion, damit die Liste testbar ist, ohne einen Reader zu starten.
  """
  @spec serialized?(map()) :: boolean()
  def serialized?(scope), do: Map.get(scope, "kind") in @serialized_kinds

  @doc """
  Issue #1149: Wartefrist eines Eintrags, gerechnet statt gegriffen.

  Wer `vor_mir` Reads vor sich hat, wartet höchstens
  `(vor_mir + 2) × @per_attempt_timeout` — die beiden Zuschläge sind der
  gerade laufende Read und der eigene. Gedeckelt auf @queue_max_wait.

  `@per_attempt_timeout` ist die Zahl, die dieses Repo ohnehin als „so lange
  darf ein Worker brauchen" führt; sie hier wiederzuverwenden ist der Grund,
  warum die Frist keine erfundene Zahl ist.
  """
  @spec queue_deadline_ms(non_neg_integer()) :: pos_integer()
  def queue_deadline_ms(vor_mir) when vor_mir >= 0 do
    min((vor_mir + 2) * @per_attempt_timeout, @queue_max_wait)
  end

  @doc """
  Issue #1149: für die Beobachtbarkeit (MemoryReporter) — wie tief ist die
  Schlange?

  ## Issue #1164: warum der Fehlerwert -1 ist und nicht 0

  Bleibt die Antwort aus, meldete diese Funktion früher `0` — den harmlosesten
  möglichen Wert. Die Speicher-Zeile behauptete dann „Schlange leer", wo in
  Wirklichkeit „keine Antwort" galt.

  Das zerstört genau die Unterscheidung, für die das Feld gebaut wurde: ein
  Herd und ein ruhiger Moment sehen beide nach wenig Speicher aus, und die
  Schlangentiefe ist das Einzige, was sie trennt. Ein Fehlerwert von `0`
  verwandelt einen Herd in einen ruhigen Moment — lautlos, nichts wird rot.

  Der Fall ist nicht reproduziert, und es wird keine Häufigkeit behauptet: der
  Reader beantwortet `{:read, …}` asynchron, seine Mailbox ist also nicht per
  se blockiert. Aber unter Speicherdruck und langen GC-Pausen reißt eine
  Sekunden-Frist — und das ist exakt der Moment, für den das Feld existiert.
  Ein Fehlerwert, der genau dann lügt, wenn die Zahl gebraucht wird, ist
  schlechter als eine sichtbare Lücke.

  `-1` ist in der Log-Zeile eindeutig und braucht kein zusätzliches Feld.
  """
  @spec queue_depth() :: integer()
  def queue_depth do
    GenServer.call(__MODULE__, :queue_depth, 1_000)
  catch
    :exit, _ -> -1
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @doc """
  Issue #1149: der leere Zustand — EINE Quelle für `init/1` und die Tests.

  Die Tests bauten ihren Zustand vorher als `%{pending: %{}}` von Hand nach.
  Das ist die Klasse, die in `Worker.Discord.VoiceSession` (#1005) einen
  Prod-Crash-Loop gekostet hat: eine Klausel schreibt per Map-Update ein Feld,
  das der Aufbau nie angelegt hat, `KeyError`, Neustart, Schleife. Ein
  gemeinsamer Konstruktor macht ein künftiges viertes Feld automatisch in
  beiden Welten vorhanden, statt es an einer Stelle zu vergessen.
  """
  @spec initial_state() :: map()
  def initial_state, do: %{pending: %{}, queue: [], in_flight: nil}

  @impl true
  def init(_) do
    # Issue #1149: der Reader abonniert die Registry, um den Ausfall des
    # Workers zu bemerken, an dem der laufende Read hängt. Ohne das stünde die
    # Schlange genau im Reconnect-Fall still — dem Fall, für den sie gebaut ist.
    Phoenix.PubSub.subscribe(Hub.PubSub, Hub.WorkerRegistry.topic())
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:queue_depth, _from, state), do: {:reply, length(state.queue), state}

  @impl true
  def handle_call({:read, scope, pick_opts, notify, serialized?}, from, state) do
    entry = %{
      from: from,
      scope: scope,
      pick_opts: pick_opts,
      notify: notify,
      serialized?: serialized?
    }

    if serialized? and state.in_flight != nil do
      {:noreply, enqueue(entry, state)}
    else
      case start_read(entry, state) do
        {:ok, state} -> {:noreply, state}
        {:none, state} -> {:reply, {:error, :no_worker}, state}
      end
    end
  end

  @impl true
  def handle_cast({:response, request_id, payload}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        # Late response nach Timeout / abgeschlossener Iteration — drop.
        {:noreply, state}

      {entry, pending_map} ->
        cancel_timer(entry.timer)
        state = %{state | pending: pending_map}

        if retryable?(payload) and entry.attempts_left > 0 and entry.remaining != [] do
          {:noreply, retry(request_id, entry, payload, state)}
        else
          GenServer.reply(entry.from, {:ok, payload})
          # Issue #1148: der Reader SPEICHERT nichts — er nimmt eine Antwort
          # entgegen, reicht sie weiter und vergisst sie. Trotzdem meldet die
          # Telemetrie konstant ~29 MB für diesen Prozess: der Payload eines
          # Kampagnen-Snapshots (3,3 MB serialisiert, ein Vielfaches davon als
          # Term) liegt nach dem `reply` als Müll im Heap, und die
          # generationelle GC eines dauerhaft warmen Prozesses sammelt ihn
          # nicht ein. `:hibernate` erzwingt genau hier einen Voll-GC und gibt
          # den Heap ans System zurück.
          #
          # Kosten: der nächste Read weckt den Prozess (Heap-Neuaufbau). Der
          # Reader läuft im Nutzer-Takt, nicht im Millisekunden-Takt — der
          # Aufweck-Aufwand ist gegen 29 MB Dauerbelegung irrelevant.
          {:noreply, finish(request_id, state), :hibernate}
        end
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    # Bei Timeout auch den nächsten Worker probieren — vielleicht ist der
    # vorige nur gerade beschäftigt.
    #
    # Issue #1148: hibernaten. Der Timeout-Pfad trägt zwar keinen großen
    # Payload, aber der Heap ist zu diesem Zeitpunkt von den VORIGEN Antworten
    # aufgebläht — und ein Read, der in einen Timeout läuft, ist genau der
    # Moment, in dem der Hub unter Last steht und den Speicher am dringendsten
    # braucht.
    if Map.has_key?(state.pending, request_id) do
      {:noreply, fail_attempt(request_id, :timeout, state), :hibernate}
    else
      # Später Timeout auf eine längst beantwortete Anfrage: nichts zu tun,
      # nichts freizugeben. Ein :hibernate wäre hier reine Aufweck-Kosten.
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:queue_timeout, ref}, state) do
    case Enum.split_with(state.queue, &(&1.queue_ref == ref)) do
      {[entry], rest} ->
        # Issue #1149: KEIN automatischer Neuversuch. Ein Timer-Retry würde den
        # Kill-Kreislauf, den diese Schlange bricht, durch einen
        # Timeout-Kreislauf ersetzen. Der Aufrufer bekommt einen sauberen
        # Fehler; die LiveView bietet einen Knopf an.
        GenServer.reply(entry.from, {:error, :queue_timeout})
        notify_positions(rest)
        {:noreply, %{state | queue: rest}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:workers_changed, _joins, leaves}, state) do
    gone = MapSet.new(leaves, fn {id, _meta} -> id end)

    betroffen =
      state.pending
      |> Enum.filter(fn {_rid, e} -> MapSet.member?(gone, e.worker_id) end)
      |> Enum.map(fn {rid, _e} -> rid end)

    if betroffen != [] do
      Logger.debug("Hub.Reader: #{length(betroffen)} laufende Read(s) am abgemeldeten Worker")
    end

    {:noreply, Enum.reduce(betroffen, state, &fail_attempt(&1, :worker_gone, &2))}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ─── Warteschlange (Issue #1149) ─────────────────────────────────

  defp enqueue(entry, state) do
    vor_mir = length(state.queue)
    ref = make_ref()
    timer = Process.send_after(self(), {:queue_timeout, ref}, queue_deadline_ms(vor_mir))

    notify(entry.notify, {:reader_queued, Map.get(entry.scope, "kind"), vor_mir + 1})

    %{state | queue: state.queue ++ [Map.merge(entry, %{queue_ref: ref, queue_timer: timer})]}
  end

  # Ein serialisierter Read ist fertig (egal wie) → Platz frei machen.
  defp finish(request_id, state) do
    if state.in_flight == request_id do
      dequeue_next(%{state | in_flight: nil})
    else
      state
    end
  end

  defp dequeue_next(%{queue: []} = state), do: state

  defp dequeue_next(%{queue: [entry | rest]} = state) do
    cancel_timer(entry.queue_timer)
    state = %{state | queue: rest}

    case start_read(entry, state) do
      {:ok, state} ->
        notify_positions(state.queue)
        state

      {:none, state} ->
        # Kein Worker mehr da: diesen Aufrufer bedienen und weiterrücken,
        # sonst bliebe die Schlange am ersten Eintrag hängen.
        GenServer.reply(entry.from, {:error, :no_worker})
        dequeue_next(state)
    end
  end

  defp notify_positions(queue) do
    queue
    |> Enum.with_index(1)
    |> Enum.each(fn {e, pos} ->
      notify(e.notify, {:reader_queued, Map.get(e.scope, "kind"), pos})
    end)
  end

  # Best-effort: bleibt die Meldung aus, fehlt nur die Positionsanzeige.
  defp notify(nil, _msg), do: :ok
  defp notify(pid, msg) when is_pid(pid), do: send(pid, msg)

  # ─── Lese-Versuche ───────────────────────────────────────────────

  defp start_read(entry, state) do
    case pick_workers(entry.pick_opts) do
      [] ->
        {:none, state}

      [first | rest] ->
        {worker_id, _meta} = first
        request_id = new_request_id()
        send_to_worker(first, entry.scope, request_id)
        timer = Process.send_after(self(), {:timeout, request_id}, @per_attempt_timeout)

        pending_entry = %{
          from: entry.from,
          remaining: rest,
          scope: entry.scope,
          timer: timer,
          attempts_left: @max_attempts - 1,
          # Issue #1149: gemerkt, damit der workers_changed-Failover weiß,
          # welcher laufende Read an einem abgemeldeten Worker hängt.
          worker_id: worker_id,
          serialized?: entry.serialized?,
          notify: entry.notify
        }

        notify(entry.notify, {:reader_started, Map.get(entry.scope, "kind")})

        state = %{state | pending: Map.put(state.pending, request_id, pending_entry)}
        {:ok, if(entry.serialized?, do: %{state | in_flight: request_id}, else: state)}
    end
  end

  # Ein Versuch ist gescheitert (Timeout oder Worker weg) — nächsten Worker
  # probieren, sonst dem Aufrufer antworten und den Platz freigeben.
  defp fail_attempt(request_id, reason, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        state

      {entry, pending_map} ->
        cancel_timer(entry.timer)
        state = %{state | pending: pending_map}

        if entry.attempts_left > 0 and entry.remaining != [] do
          retry(request_id, entry, reason, state)
        else
          GenServer.reply(entry.from, {:error, caller_reason(reason)})
          finish(request_id, state)
        end
    end
  end

  # Ein abgemeldeter Worker ist für den Aufrufer dasselbe wie gar keiner —
  # die LiveView kennt :no_worker bereits als „Warte auf Worker".
  defp caller_reason(:worker_gone), do: :no_worker
  defp caller_reason(other), do: other

  defp retryable?(%{"forbidden" => true}), do: true
  defp retryable?(%{"not_found" => true}), do: true
  defp retryable?(_), do: false

  defp retry(request_id, entry, reason, state) do
    [next | rest] = entry.remaining
    {worker_id, _meta} = next
    new_request_id = new_request_id()
    send_to_worker(next, entry.scope, new_request_id)
    timer = Process.send_after(self(), {:timeout, new_request_id}, @per_attempt_timeout)

    Logger.debug(
      "Hub.Reader retry: reason=#{inspect(reason)} attempts_left=#{entry.attempts_left - 1}"
    )

    new_entry = %{
      from: entry.from,
      remaining: rest,
      scope: entry.scope,
      timer: timer,
      attempts_left: entry.attempts_left - 1,
      worker_id: worker_id,
      serialized?: Map.get(entry, :serialized?, false),
      notify: Map.get(entry, :notify)
    }

    state = %{state | pending: Map.put(state.pending, new_request_id, new_entry)}

    # Issue #1149: derselbe Read, nur ein anderer Worker — der Platz in der
    # Schlange wandert mit. Ohne das gäbe der Reader den Platz nie wieder frei,
    # und die Schlange stünde nach dem ersten Retry für immer.
    if state.in_flight == request_id do
      %{state | in_flight: new_request_id}
    else
      state
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────

  defp pick_workers(opts), do: order_candidates(Hub.WorkerRegistry.list(), opts)

  @doc """
  Issue #366: ordnet die Worker-Kandidaten für einen Read.

  Pure Funktion (testbar ohne `Phoenix.Tracker`). `workers` ist die Liste der
  `{worker_id, meta}`-Tupel aus `Hub.WorkerRegistry.list/0`.

  - `worker_id:` → Hard-Filter auf genau diesen Worker (Issue #451, kein Fallback).
  - `prefer_discord_id:` → eigene Worker (admin_discord_id-Match) zuerst, Rest als
    Fallback-Kaskade.
  - sonst → deterministisch sortierte Voll-Liste.

  Sortierung überall `{-applied_seq, id}` (frischester zuerst, Tie-Breaker `id`) —
  identisch zu `Hub.Commands.pick_leader`, damit dieselbe LiveView zwischen Reloads
  nicht zwischen Workern springt.
  """
  @spec order_candidates([{binary(), map()}], keyword()) :: [{binary(), map()}]
  def order_candidates(workers, opts \\ []) do
    sorted = Enum.sort_by(workers, fn {id, m} -> {-Map.get(m, :applied_seq, 0), id} end)

    cond do
      worker_id = Keyword.get(opts, :worker_id) ->
        Enum.filter(sorted, fn {id, _} -> id == worker_id end)

      did = Keyword.get(opts, :prefer_discord_id) ->
        {own, rest} = Enum.split_with(sorted, fn {_, m} -> m[:admin_discord_id] == did end)
        own ++ rest

      true ->
        sorted
    end
  end

  defp send_to_worker({_worker_id, meta}, scope, request_id) do
    send(meta.channel_pid, {:snapshot_request, scope, request_id, self()})
  end

  defp new_request_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
