defmodule Worker.Repo.Recording do
  @moduledoc """
  Issue #719 (Fortsetzung des #581-Splits): die Session-/Utterance-/Marker-/
  Speaker-Reads aus `Worker.Repo` — die Aufnahme-Domäne. Call-Sites bleiben
  `Worker.Repo.x()` (Façade-defdelegate); Row-Shapes in `Worker.Repo.Rows`.
  """

  alias Worker.Repo.Rows
  alias Worker.Schema.Mnesia, as: S

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

  @doc "All markers across every session of `campaign_id`, oldest first."
  def list_markers_for_campaign(campaign_id) do
    list_sessions(campaign_id)
    |> Enum.flat_map(&list_markers(&1.id))
    |> Enum.sort_by(& &1.at_ts, {:asc, DateTime})
  end
end
