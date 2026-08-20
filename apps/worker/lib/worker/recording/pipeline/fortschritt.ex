defmodule Worker.Recording.Pipeline.Fortschritt do
  @moduledoc """
  Issue #1122: das Gedächtnis eines Pipeline-Laufs — welche Stufe wo steht und
  wie viele Einheiten sie erledigt hat.

  Vorher waren die Stufen reine Ereignisse: `notify_status` broadcastete
  „started"/„ended" und vergaß sie sofort. Eine abgeschlossene Stufe hinterließ
  nichts, und wer die Seite mitten im Lauf öffnete, sah bis zur nächsten
  Meldung gar nichts. Genau daran ist der erste Anlauf einer Replay-Anzeige
  gescheitert (2026-08-20): sie hielt einen Lauf für aktiv, dessen Prozess
  längst gestorben war.

  ## Warum ein eigener Prozess

  Drei Gründe, jeder für sich ausreichend:

  1. **`Worker.Recording.Pipeline` darf nicht blockieren.** Dort läuft
     `run_for_session/1` als `handle_call`; 244 Fortschritts-Casts einer
     Gap-Fill-Schleife hätten sich davorgelegt.
  2. **Der Koordinator ist die Rolle, die verteilte Batches brauchen.** Sollen
     Chunks später auf mehrere Worker gehen, melden die Arbeiter *ihm*, und er
     meldet nach außen — die Oberfläche bleibt unberührt, egal ob ein Worker
     rechnet oder fünf.
  3. `pipeline.ex` steht bei 589 Code-Zeilen vor der 600er-Grenze des
     God-Module-Checks.

  ## Menge statt Zähler

  Erledigte Einheiten werden als **Menge von IDs** geführt, nicht als Zahl. Ein
  Zähler ist nicht zusammenführbar: meldet Worker A „3 fertig" und Worker B „4
  fertig", ist weder 3 noch 4 noch 7 ableitbar. Die Vereinigung von Mengen ist
  dagegen unempfindlich gegen Reihenfolge und Doppelzustellung — dieselbe
  Konvergenz-Überlegung wie bei den Folds aus #766. Nach außen geht die
  Kardinalität, damit die Nachricht klein bleibt.

  „4 von 7" heißt deshalb **vier sind fertig**, nicht „ich bin bei Nummer
  vier": verteilt kann Chunk 5 vor Chunk 2 fertig werden.

  ## Grenzen

  Der Zustand lebt im Arbeitsspeicher. Ein Worker-Neustart verliert ihn — wie
  bei `CampaignReplay` auch. Ein Lauf, dessen Prozess stirbt, bleibt als
  `:laeuft` stehen, bis ihn das Aufräumen verdrängt; die Anzeige muss das
  Alter also mitlesen und darf „läuft" nicht als Beweis nehmen.
  """

  use GenServer

  alias Shared.PipelineStufen

  @name __MODULE__

  # Mindestabstand zwischen zwei Fortschritts-Broadcasts derselben Stufe.
  # Zeitbasiert statt „jede k-te Einheit", weil die Einheiten sehr
  # unterschiedlich lange dauern: ein Gap-Fill-Block braucht ~30 s, ein
  # Verify-Fakt Bruchteile davon. Der Stufenwechsel selbst wird IMMER
  # gesendet — sonst bliebe die Anzeige bei 6/7 stehen, wenn die letzte
  # gedrosselte Meldung wegfällt.
  @broadcast_min_ms 1_000

  # Wie viele Läufe im Gedächtnis bleiben. Ein Kampagnen-Replay erzeugt einen
  # pro Session (26 bei Romeo); der Deckel verhindert, dass der Prozess über
  # Wochen wächst, ohne dass es jemand bemerkt.
  @max_laeufe 50

  # ─── API ──────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Ein Lauf beginnt. `ctx` trägt `run_id`, `session_id`, `campaign_id`."
  @spec lauf_start(map()) :: :ok
  def lauf_start(ctx), do: GenServer.cast(@name, {:lauf_start, ctx, now_ms()})

  @doc "Stufenwechsel: `status` ist \"started\" | \"ended\" | \"failed\"."
  @spec stufe(map(), String.t(), String.t()) :: :ok
  def stufe(ctx, stage, status), do: GenServer.cast(@name, {:stufe, ctx, stage, status, now_ms()})

  @doc """
  Gesamtzahl der Einheiten dieser Stufe — sobald sie feststeht (die Extraktion
  weiß erst nach dem Chunking, wie viele Chunks es sind).
  """
  @spec gesamt(map(), String.t(), non_neg_integer()) :: :ok
  def gesamt(ctx, stage, n) when is_integer(n) and n >= 0,
    do: GenServer.cast(@name, {:gesamt, ctx, stage, n})

  @doc "Eine Einheit ist fertig. `id` identifiziert sie (Chunk-Index, Block-ID, …)."
  @spec fertig(map(), String.t(), term()) :: :ok
  def fertig(ctx, stage, id), do: GenServer.cast(@name, {:fertig, ctx, stage, id, now_ms()})

  @doc "Stand einer Session — `nil`, wenn kein Lauf bekannt ist."
  @spec stand(String.t()) :: map() | nil
  def stand(session_id), do: GenServer.call(@name, {:stand, session_id})

  @doc "Alle bekannten Läufe, jüngster zuerst."
  @spec alle() :: [map()]
  def alle, do: GenServer.call(@name, :alle)

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{laeufe: %{}, gesendet: %{}}}

  @impl true
  def handle_cast({:lauf_start, ctx, jetzt}, state) do
    lauf = %{
      run_id: ctx[:run_id],
      session_id: ctx[:session_id],
      campaign_id: ctx[:campaign_id],
      gestartet_ms: jetzt,
      aktualisiert_ms: jetzt,
      stufen: %{}
    }

    {:noreply, put_lauf(state, ctx[:session_id], lauf)}
  end

  def handle_cast({:stufe, ctx, stage, status, jetzt}, state) do
    state =
      update_stufe(state, ctx, stage, jetzt, fn s ->
        case status do
          "started" -> %{s | status: :laeuft, seit_ms: jetzt}
          # Der Abschluss ist autoritativ: was die Stufe beendet hat, ist
          # vollständig — auch wenn eine gedrosselte Meldung unterwegs verloren
          # ging. Ohne das bliebe die Anzeige bei 6/7 stehen.
          "ended" -> %{s | status: :fertig, bis_ms: jetzt, fertig: voll(s)}
          _ -> %{s | status: :fehler, bis_ms: jetzt}
        end
      end)

    # Stufenwechsel immer senden, nie drosseln.
    {:noreply, sende(state, ctx, stage, true)}
  end

  def handle_cast({:gesamt, ctx, stage, n}, state) do
    state = update_stufe(state, ctx, stage, now_ms(), &%{&1 | gesamt: n})
    {:noreply, sende(state, ctx, stage, true)}
  end

  def handle_cast({:fertig, ctx, stage, id, jetzt}, state) do
    state = update_stufe(state, ctx, stage, jetzt, &%{&1 | fertig: MapSet.put(&1.fertig, id)})
    {:noreply, sende(state, ctx, stage, false)}
  end

  @impl true
  def handle_call({:stand, session_id}, _from, state) do
    {:reply, state.laeufe |> Map.get(session_id) |> serialisiere(), state}
  end

  def handle_call(:alle, _from, state) do
    laeufe =
      state.laeufe
      |> Map.values()
      |> Enum.sort_by(& &1.aktualisiert_ms, :desc)
      |> Enum.map(&serialisiere/1)

    {:reply, laeufe, state}
  end

  # ─── Zustand ──────────────────────────────────────────────────────

  defp put_lauf(state, nil, _lauf), do: state

  defp put_lauf(state, session_id, lauf) do
    laeufe = Map.put(state.laeufe, session_id, lauf)

    # Ältestes raus, sobald der Deckel reißt — gemessen an der letzten
    # Aktualisierung, nicht am Start: ein langer Lauf ist nicht alt.
    laeufe =
      if map_size(laeufe) > @max_laeufe do
        {aeltester, _} = Enum.min_by(laeufe, fn {_k, l} -> l.aktualisiert_ms end)
        Map.delete(laeufe, aeltester)
      else
        laeufe
      end

    %{state | laeufe: laeufe}
  end

  defp update_stufe(state, ctx, stage, jetzt, fun) do
    sid = ctx[:session_id]

    case Map.get(state.laeufe, sid) do
      nil ->
        # Meldung ohne bekannten Lauf (Worker-Neustart mitten im Lauf, oder ein
        # Aufrufer ohne `lauf_start`): den Lauf hier anlegen statt die Meldung
        # zu verwerfen. Eine halbe Anzeige ist besser als keine.
        lauf = %{
          run_id: ctx[:run_id],
          session_id: sid,
          campaign_id: ctx[:campaign_id],
          gestartet_ms: jetzt,
          aktualisiert_ms: jetzt,
          stufen: %{}
        }

        state |> put_lauf(sid, lauf) |> update_stufe(ctx, stage, jetzt, fun)

      lauf ->
        stufen = Map.update(lauf.stufen, stage, fun.(neue_stufe(jetzt)), fun)
        put_lauf(state, sid, %{lauf | stufen: stufen, aktualisiert_ms: jetzt})
    end
  end

  defp neue_stufe(jetzt) do
    %{status: :offen, gesamt: nil, fertig: MapSet.new(), seit_ms: jetzt, bis_ms: nil}
  end

  # Beim Abschluss zählt die Stufe als vollständig. Ohne bekannte Gesamtzahl
  # bleibt die Menge, wie sie ist — eine Zahl zu erfinden wäre schlimmer als
  # keine.
  defp voll(%{gesamt: nil} = s), do: s.fertig
  defp voll(%{gesamt: n}), do: MapSet.new(1..max(n, 1)//1)

  # ─── Broadcast ────────────────────────────────────────────────────

  defp sende(state, ctx, stage, immer?) do
    sid = ctx[:session_id]
    key = {sid, stage}
    jetzt = now_ms()
    zuletzt = Map.get(state.gesendet, key, 0)

    if immer? or jetzt - zuletzt >= @broadcast_min_ms do
      broadcast(state, ctx, stage)
      %{state | gesendet: Map.put(state.gesendet, key, jetzt)}
    else
      state
    end
  end

  defp broadcast(state, ctx, stage) do
    with lauf when not is_nil(lauf) <- Map.get(state.laeufe, ctx[:session_id]),
         s when not is_nil(s) <- Map.get(lauf.stufen, stage) do
      payload =
        %{
          "kind" => "pipeline_fortschritt",
          "campaign_id" => lauf.campaign_id,
          "session_id" => lauf.session_id,
          "run_id" => lauf.run_id,
          "stage" => stage,
          "status" => Atom.to_string(s.status),
          "fertig" => MapSet.size(s.fertig),
          "gesamt" => s.gesamt,
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

      Worker.HubClient.publish_status(payload)
      Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})
    end

    :ok
  end

  # ─── Serialisierung ───────────────────────────────────────────────

  @doc false
  # Public für Tests + Snapshot: der Zustand als schlichte Map, Mengen als
  # Anzahl. Die Stufenliste kommt aus `Shared.PipelineStufen`, damit auch
  # noch nicht gelaufene Stufen als `offen` auftauchen — sonst könnte die
  # Anzeige nicht sagen, was noch aussteht.
  def serialisiere(nil), do: nil

  def serialisiere(lauf) do
    stufen =
      Enum.map(PipelineStufen.alle(), fn stufe ->
        s = Map.get(lauf.stufen, stufe.name)

        %{
          "name" => stufe.name,
          "titel" => stufe.titel,
          "spalte" => stufe.spalte,
          "status" => (s && Atom.to_string(s.status)) || "offen",
          "fertig" => (s && MapSet.size(s.fertig)) || 0,
          "gesamt" => s && s.gesamt,
          "dauer_ms" => dauer(s)
        }
      end)

    %{
      "run_id" => lauf.run_id,
      "session_id" => lauf.session_id,
      "campaign_id" => lauf.campaign_id,
      "gestartet_vor_ms" => now_ms() - lauf.gestartet_ms,
      "still_seit_ms" => now_ms() - lauf.aktualisiert_ms,
      "stufen" => stufen
    }
  end

  defp dauer(nil), do: nil
  defp dauer(%{bis_ms: nil, seit_ms: seit}), do: now_ms() - seit
  defp dauer(%{bis_ms: bis, seit_ms: seit}), do: bis - seit

  defp now_ms, do: System.monotonic_time(:millisecond)
end
