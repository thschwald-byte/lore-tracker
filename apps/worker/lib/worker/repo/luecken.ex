defmodule Worker.Repo.Luecken do
  @moduledoc """
  Issue #865 (Epic #861 D+E): Read-Pfad der Gap-Fill-Welt — Gemma-Füll-
  Vorschläge (`worker_luecken_vorschlaege`) + Kurations-Overlay
  (`worker_luecken_overrides`) inkl. Read-Zeit-Re-Attach (F2). Ausgelagert
  aus `Worker.Repo.Artifacts` (God-Module-Grenze); Call-Sites bleiben
  `Worker.Repo.x()` (Façade-defdelegate).
  """

  alias Worker.Recording.Pipeline.Smoothing
  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo, only: [transaction: 1]

  @doc "Gemma-Füll-Vorschläge einer Session, keyed by Block-Content-ID."
  @spec luecken_vorschlaege_for_session(String.t()) :: %{optional(String.t()) => map()}
  def luecken_vorschlaege_for_session(session_id) when is_binary(session_id) do
    transaction(fn -> :mnesia.index_read(S.luecken_vorschlaege(), session_id, :session_id) end)
    |> Map.new(fn {_, block_id, _sid, _cid, original, vorschlag, modell, event_id} ->
      {block_id,
       %{
         "block_id" => block_id,
         "original" => original,
         "vorschlag" => vorschlag,
         "modell" => modell,
         "event_id" => event_id
       }}
    end)
  end

  @doc """
  Effektive Kurations-Overrides einer Session, keyed by AKTUELLER Block-Content-
  ID — inkl. **Read-Zeit-Re-Attach** (F2 Runde 5/6): matcht ein Override nicht
  direkt (Regelwechsel → neue Block-IDs), wird es über die identische,
  sortiert-kanonisch gesnapshottete `quell_utterance_ids`-Menge auf den
  aktuellen Block gepaart — angewandt NUR, wenn sein `bestaetigter_text` einem
  der `candidate_texts` des Blocks noch entspricht (K3-Snapshot als Wahrheit;
  sonst → `verwaist`-Liste für die Review-Queue, nie still weg). Paaren MEHRERE
  Overrides denselben Block, gewinnt LWW-by-event_id (deterministisch über
  Worker — reine Lese-Berechnung, idempotent, multi-worker-safe).

  `blocks` = die aktuellen Snapshot-Blöcke (String-Key-Maps). Returns
  `%{attached: %{block_id => override}, verwaist: [override]}`.
  """
  @spec luecken_overrides_effective(String.t(), [map()]) :: %{
          attached: %{optional(String.t()) => map()},
          verwaist: [map()]
        }
  def luecken_overrides_effective(session_id, blocks) when is_binary(session_id) do
    overrides =
      transaction(fn -> :mnesia.index_read(S.luecken_overrides(), session_id, :session_id) end)
      |> Enum.map(fn {_, _lo_key, _sid, _cid, block_id, status, text, quell, set_by, event_id} ->
        %{
          "block_id" => block_id,
          "status" => status,
          "bestaetigter_text" => text,
          "quell_utterance_ids" => quell || [],
          "set_by" => set_by,
          "event_id" => event_id
        }
      end)

    by_current_id = Map.new(blocks, &{&1["id"], &1})
    by_quell = Map.new(blocks, &{Enum.sort(&1["quell_utterance_ids"] || []), &1["id"]})

    {attached, verwaist} =
      Enum.reduce(overrides, {%{}, []}, fn ov, {att, orph} ->
        case attach_target(ov, by_current_id, by_quell) do
          nil ->
            {att, [ov | orph]}

          block_id ->
            # LWW bei Mehrfach-Paarung (alter + nach dem Bump neu geschriebener
            # Override auf denselben Block) — höhere event_id gewinnt.
            prev = Map.get(att, block_id)

            if prev != nil and prev["event_id"] >= ov["event_id"],
              do: {att, orph},
              else: {Map.put(att, block_id, ov), orph}
        end
      end)

    %{attached: attached, verwaist: Enum.reverse(verwaist)}
  end

  # Roh-Text des Blocks = Original-Texte seiner Quell-Utterances in
  # Zeit-Reihenfolge. nil, wenn keine Quell-Utterance mehr auffindbar ist
  # (z.B. gelöschte Utterances) — das Panel fällt dann auf den Smoothed-Text
  # ohne Diff zurück, statt einen leeren Roh-Text als „alles ergänzt" zu lügen.
  defp roh_text(block, utt_by_id) do
    utts =
      (block["quell_utterance_ids"] || [])
      |> Enum.map(&Map.get(utt_by_id, &1))
      |> Enum.reject(&is_nil/1)

    if utts == [] do
      nil
    else
      utts
      |> Enum.sort_by(& &1.timestamp, {:asc, DateTime})
      |> Enum.map_join(" ", & &1.text)
    end
  end

  @doc """
  Issue #871 (erweitert um die Slice-E-Kuration, Review 2026-07-16): die
  geglättete Block-Ebene fürs Spalten-UI — pro Session mit Smoothing-Snapshot
  die Blöcke mit **aufgelöstem** `effective_text` (Vorschlag/Kuration
  eingerechnet, dieselbe eine Text-Funktion wie die Pipeline) + allem, was
  die INLINE-Kuration braucht: Smoothed-Basis-Text, Roh-Text (Trims-Diff),
  Vorschlags-Text (Diff + Übernehmen), Override (Badge + letzter Schreiber),
  `quell_utterance_ids` (K3-Snapshot fürs Kurations-Event + Protokoll-Sprung).
  `unbrauchbar`-Blöcke bleiben sichtbar (durchgestrichen, F5-Audit),
  OOC-Verworfenes + verwaiste Overrides (Re-Attach-Review) am Session-Kopf.

  Issue #883: liefert ALLE Blöcke — der frühere 200er-Reader-Cap versteckte
  auf Real Free Seattle die ersten ~540 Blöcke unerreichbar. Begrenzt wird
  render-seitig im Hub (gleitendes #709-Fenster; die #709-Lektion: teuer ist
  der Render-Diff, nicht der Assign-Heap). Damit ist auch die frühere
  Sonderregel „unkuratierte Lücken immer mitliefern" obsolet — es fehlt nichts
  mehr.
  """
  @spec smoothed_for_campaign(String.t()) :: [map()]
  def smoothed_for_campaign(campaign_id) when is_binary(campaign_id) do
    campaign_id
    |> Worker.Repo.list_sessions()
    |> Enum.flat_map(fn session ->
      case Worker.Repo.get_smoothed_blocks(session.id) do
        nil -> []
        snap -> [smoothed_session_view(session, snap)]
      end
    end)
  end

  defp smoothed_session_view(session, snap) do
    blocks = snap.blocks || []
    vorschlaege = luecken_vorschlaege_for_session(session.id)
    %{attached: attached, verwaist: verwaist} = luecken_overrides_effective(session.id, blocks)

    utt_by_id =
      session.id
      |> Worker.Repo.list_utterances(limit: :all)
      |> Map.new(&{&1.id, &1})

    view_blocks =
      blocks
      |> Enum.map(fn b ->
        id = b["id"]
        vorschlag = Map.get(vorschlaege, id)
        override = Map.get(attached, id)

        %{
          "block_id" => id,
          "speaker_discord_id" => b["speaker_discord_id"],
          "text" => Smoothing.effective_text(b, vorschlag, override),
          "text_smoothed" => b["text"],
          "roh_text" => roh_text(b, utt_by_id),
          "vorschlag_text" => vorschlag && Smoothing.effective_text(b, vorschlag, nil),
          "vorschlag_modell" => vorschlag && vorschlag["modell"],
          "quell_utterance_ids" => b["quell_utterance_ids"] || [],
          "hat_luecke" => b["hat_luecke"] == true,
          "override" => override,
          "status" => override && override["status"]
        }
      end)

    %{
      "session_id" => session.id,
      "session_number" => session.number,
      "rules_version" => snap.rules_version,
      "merge_gap_seconds" => snap.merge_gap_seconds,
      "ooc_verworfen_count" => length(snap.ooc_verworfen || []),
      "verwaist" => verwaist,
      "blocks" => view_blocks
    }
  end

  @doc "Anzahl Kurations-Overrides auf diesem Worker (merge_gap-Warnung, /settings)."
  @spec override_count() :: non_neg_integer()
  def override_count do
    transaction(fn -> :mnesia.all_keys(S.luecken_overrides()) end) |> length()
  end

  # Direkter ID-Treffer ODER Mengen-Paarung + Text-Match (Re-Attach). Ein
  # unbrauchbar-Override braucht keinen Text-Match (er segnet keinen Text ab —
  # die Menge identifiziert den Block eindeutig).
  defp attach_target(ov, by_current_id, by_quell) do
    direct = Map.has_key?(by_current_id, ov["block_id"]) and ov["block_id"]

    cond do
      direct ->
        ov["block_id"]

      block_id = Map.get(by_quell, Enum.sort(ov["quell_utterance_ids"])) ->
        block = Map.fetch!(by_current_id, block_id)

        if ov["status"] == "unbrauchbar" or text_still_matches?(ov, block),
          do: block_id,
          else: nil

      true ->
        nil
    end
  end

  # K3-Text-Match: der gesnapshottete bestätigte Text muss noch zu einem der
  # möglichen effektiven Texte des Blocks passen (Smoothed-Text reicht als
  # Kandidat — der Override ERSETZT ja den Text; entscheidend ist, dass sich
  # der UMGEBUNGSTEXT nicht unbemerkt geändert hat: bei original_bestaetigt
  # ist der bestätigte Text der Smoothed-Text selbst und muss exakt matchen;
  # bei bestaetigt/manuell_korrigiert akzeptieren wir die Paarung über die
  # Menge — der bestätigte Text bleibt der K3-Snapshot und wird angewandt).
  defp text_still_matches?(%{"status" => "original_bestaetigt"} = ov, block),
    do: ov["bestaetigter_text"] == block["text"]

  defp text_still_matches?(_ov, _block), do: true
end
