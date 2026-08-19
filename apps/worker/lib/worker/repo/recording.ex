defmodule Worker.Repo.Recording do
  @moduledoc """
  Issue #719 (Fortsetzung des #581-Splits): die Session-/Utterance-/Marker-/
  Speaker-Reads aus `Worker.Repo` — die Aufnahme-Domäne. Call-Sites bleiben
  `Worker.Repo.x()` (Façade-defdelegate); Row-Shapes in `Worker.Repo.Rows`.
  """

  alias Worker.Repo.Rows
  alias Worker.Schema.Mnesia, as: S

  # Issue #1087: wie viele Utterances pro Session der Campaign-Snapshot
  # ausliefert. Bewusst = `Components.window_max/0` im Hub (200): das
  # Render-Fenster startet als Tail von 150 und darf bis 200 wachsen, ohne
  # dass ein Nachladen nötig wird. Erst der Griff nach älteren Zeilen löst
  # einen Worker-Read aus.
  @utterance_tail 200

  import Worker.Repo,
    except: [
      list_sessions: 1,
      get_session: 1,
      recent_utterance_texts: 1,
      recent_utterance_texts: 2,
      list_utterances: 1,
      list_utterances: 2,
      live_purge_plan: 0,
      list_markers: 1,
      list_speaker_assignments_for_campaign: 1,
      list_speaker_assignments: 1,
      list_utterances_for_campaign: 1,
      list_utterances_for_campaign: 2,
      list_markers_for_campaign: 1,
      active_session_for: 1,
      get_session_capture_mode: 1,
      next_session_number: 1
    ]

  # ─── sessions ───────────────────────────────────────────────────

  def list_sessions(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.sessions(), campaign_id, :campaign_id)
    end)
    |> Enum.map(&Rows.session/1)
    |> Enum.sort_by(& &1.number)
  end

  def get_session(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.sessions(), session_id) end) do
      [row] -> Rows.session(row)
      [] -> nil
    end
  end

  @doc "First non-completed session for a campaign (or nil)."
  def active_session_for(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.find(fn s -> s.status in [:recording, :paused] end)
  end

  @doc """
  Issue #987: session-weiter Aufnahme-Modus. `"discord" | "browser" | nil`
  (nil = noch keine Wahl getroffen, s. `Recorder.choose_capture_mode/3`).
  """
  @spec get_session_capture_mode(String.t()) :: String.t() | nil
  def get_session_capture_mode(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_capture_modes(), session_id) end) do
      [{_tbl, _sid, _cid, mode, _set_by, _updated_at}] -> mode
      [] -> nil
    end
  end

  @doc "Next session number for a campaign (max+1, or 1 if none yet)."
  def next_session_number(campaign_id) do
    case list_sessions(campaign_id) do
      [] -> 1
      list -> Enum.max_by(list, & &1.number).number + 1
    end
  end

  # ─── utterances ─────────────────────────────────────────────────

  @doc """
  Utterances einer Session, chronologisch sortiert.

  Issue #418: `:live`-Rows aus Alt-Sessions (vor dem Live-Removal, als es noch
  Live-Transkription gab) werden defensiv rausgefiltert — die Batch-
  `confirmed`-Variante ist die kanonische. `mix lore.purge_live` löscht die
  Alt-Live-Rows endgültig.
  """
  def list_utterances(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    rows =
      transaction(fn ->
        :mnesia.index_read(S.utterances(), session_id, :session_id)
      end)
      |> Enum.reject(&Rows.utterance_deleted?/1)
      |> Enum.map(&Rows.utterance/1)
      |> Enum.reject(&(&1.status == :live))
      |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})

    # Issue #506: `limit: :all` lädt die GANZE Session — für den Stage-2-
    # Pipeline-Pfad, der sonst nur die letzten 200 Utts einer langen Session
    # summt (→ trunkiertes Resümee, vergiftet Epos + Chronik downstream).
    # UI-/Snapshot-Reader behalten das 200-Default-Cap (kein 3000-Utt-Load
    # in eine LiveView).
    case limit do
      :all -> rows
      n when is_integer(n) -> Enum.take(rows, -n)
    end
  end

  @spec recent_utterance_texts(String.t(), pos_integer()) :: [String.t()]
  def recent_utterance_texts(session_id, limit \\ 10) do
    list_utterances(session_id, limit: limit)
    |> Enum.map(& &1.text)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
  end

  @doc """
  Issue #418: Plan für `Worker.Maintenance.purge_live/0`. Klassifiziert alle
  Sessions mit `status: :live`-Rows danach, ob ein Batch-Pendant existiert:

      %{clearable: [{session_id, live_count}], orphan: [{session_id, live_count}]}

  `clearable` = Session hat live UND mindestens eine nicht-live Row → die live-
  Rows sind redundant und können via `LiveUtterancesCleared` getilgt werden.
  `orphan` = nur live, kein Batch → NICHT tilgen (Datenverlust). Tombstone'd
  Rows zählen nicht mit.
  """
  def live_purge_plan do
    transaction(fn -> :mnesia.foldl(&[&1 | &2], [], S.utterances()) end)
    |> Enum.reject(&Rows.utterance_deleted?/1)
    |> Enum.map(&Rows.utterance/1)
    |> Enum.group_by(& &1.session_id)
    |> Enum.reduce(%{clearable: [], orphan: []}, fn {sid, rows}, acc ->
      live_count = Enum.count(rows, &(&1.status == :live))

      cond do
        live_count == 0 ->
          acc

        Enum.any?(rows, &(&1.status != :live)) ->
          %{acc | clearable: [{sid, live_count} | acc.clearable]}

        true ->
          %{acc | orphan: [{sid, live_count} | acc.orphan]}
      end
    end)
  end

  def list_markers(session_id) do
    transaction(fn ->
      :mnesia.index_read(S.markers(), session_id, :session_id)
    end)
    |> Enum.map(fn {_, id, sid, at, kind, label} ->
      %{id: id, session_id: sid, at_ts: at, kind: kind, label: label}
    end)
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end

  # ─── speaker assignments (Issue #19) ────────────────────────────

  @doc """
  Sprecher-Zuordnungen aller Sessions einer Kampagne. Liefert eine Liste
  von `%{session_id, speaker_label, discord_id}`. Pseudo-Labels ohne
  Zuordnung tauchen hier nicht auf — sie werden in der UI als „Sprecher N"
  gerendert.
  """
  def list_speaker_assignments_for_campaign(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.flat_map(fn s -> list_speaker_assignments(s.id) end)
  end

  def list_speaker_assignments(session_id) do
    transaction(fn ->
      :mnesia.index_read(S.speaker_assignments(), session_id, :session_id)
    end)
    |> Enum.map(fn {_, _key, sid, label, did, _at} ->
      %{session_id: sid, speaker_label: label, discord_id: did}
    end)
  end

  # ─── campaign-weite Aggregat-Reads ──────────────────────────────

  @doc """
  All utterances across every session of `campaign_id`, oldest first.
  Used by Protokoll so prior sessions remain visible when a new recording
  starts.

  Issue #150: globales Limit auf 10_000 hochgesetzt (war 1000) — bei
  Bühnenstück-großen Kampagnen wie der Folger-R&J-Demo (1060 Utterances,
  27 Sessions) fielen sonst die ältesten Utterances raus und Session 1
  verschwand komplett aus der Protokoll-Spalte. Pro-Session-Limit bleibt
  bei 1000 (default in `list_utterances/2`). Wenn Render-Performance ein
  Thema wird, ist Pagination der saubere Weg — eigenes Issue.
  """
  def list_utterances_for_campaign(campaign_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10_000)

    list_sessions(campaign_id)
    |> Enum.flat_map(&list_utterances(&1.id, limit: limit))
    |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
    |> Enum.take(-limit)
  end

  @doc """
  Issue #1087: Utterance-**Ladefenster** pro Session statt Vollast.

  Liefert `{utterances, counts, froms}` — die jüngsten `per_session`
  Utterances jeder Session der Kampagne (chronologisch über alle Sessions
  sortiert), dazu die **Gesamtzahl** je Session und den **absoluten Index**,
  an dem das gelieferte Fenster beginnt. Die beiden Maps sind der Grund, warum
  der Hub trotz Teillieferung korrekt zählen und weiterblättern kann.

  Warum überhaupt: der Voll-Load (`list_utterances_for_campaign/2`, Deckel
  10.000) schickte für eine reale Kampagne 5.553 Utterances = 4,8 MB Heap an
  **jeden** Betrachter. Der Prod-Hub hat 381,5 MiB Cgroup-Limit und wurde
  wiederholt am Limit gekillt, ausschließlich in Zeitfenstern mit Zuschauern.
  Das Render-Fenster aus #709 half dabei nicht: es schneidet nur zu, was ins
  DOM geht, während die volle Liste in den Assigns liegen blieb.
  """
  @spec campaign_utterance_tail(String.t(), pos_integer()) ::
          {[map()], %{optional(String.t()) => non_neg_integer()},
           %{optional(String.t()) => non_neg_integer()}}
  def campaign_utterance_tail(campaign_id, per_session \\ @utterance_tail) do
    {lists, counts, froms} =
      campaign_id
      |> list_sessions()
      |> Enum.reduce({[], %{}, %{}}, fn s, {ls, cs, fs} ->
        all = list_utterances(s.id, limit: :all)
        total = length(all)

        {[Enum.take(all, -per_session) | ls], Map.put(cs, s.id, total),
         Map.put(fs, s.id, max(0, total - per_session))}
      end)

    utterances =
      lists
      |> Enum.concat()
      |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})

    {utterances, counts, froms}
  end

  @doc "Issue #1087: Default-Größe des Ladefensters pro Session."
  @spec utterance_tail_size() :: pos_integer()
  def utterance_tail_size, do: @utterance_tail

  @doc """
  Issue #1087: absoluter Ausschnitt `[from, from + count)` einer Session,
  chronologisch. Gibt `{utterances, total}` zurück; `total` ist die
  Gesamtzahl der Session, damit der Hub sein Fenster clampen kann.

  `nil` statt eines Tupels, wenn die Session nicht zu `campaign_id` gehört —
  die Session-ID kommt vom Client, und ein Member der Kampagne A darf so
  nicht in Kampagne B lesen.
  """
  @spec utterance_slice(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {[map()], non_neg_integer()} | nil
  def utterance_slice(campaign_id, session_id, from, count) do
    case get_session(session_id) do
      %{campaign_id: ^campaign_id} ->
        all = list_utterances(session_id, limit: :all)
        {Enum.slice(all, max(from, 0), max(count, 0)), length(all)}

      _ ->
        nil
    end
  end

  @doc """
  Issue #1087: einzelne Utterances per ID — für Sprungmarken und den
  Refs-Popover, die auf Zeilen **außerhalb** des geladenen Fensters zeigen
  können. Fremde Kampagnen werden weggefiltert, nicht abgewiesen: eine
  unauflösbare Referenz ist kein Fehler, sondern eine leere Antwort.
  """
  @spec utterances_by_ids(String.t(), [String.t()]) ::
          {[map()], %{optional(String.t()) => non_neg_integer()}}
  def utterances_by_ids(campaign_id, ids) when is_list(ids) do
    wanted = MapSet.new(ids)

    {found, indices} =
      campaign_id
      |> list_sessions()
      |> Enum.reduce({[], %{}}, fn s, {acc, idx} ->
        s.id
        |> list_utterances(limit: :all)
        |> Enum.with_index()
        |> Enum.reduce({acc, idx}, fn {u, i}, {a, ix} ->
          if MapSet.member?(wanted, u.id),
            do: {[u | a], Map.put(ix, u.id, i)},
            else: {a, ix}
        end)
      end)

    {Enum.sort_by(found, & &1.timestamp, {:asc, DateTime}), indices}
  end

  @doc "All markers across every session of `campaign_id`, oldest first."
  def list_markers_for_campaign(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.flat_map(&list_markers(&1.id))
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end
end
