defmodule Worker.Materializer.Chronik do
  @moduledoc """
  Issue #1092 (God-Module-Split aus `Worker.Materializer.Apply2`, #544): die
  Folds der Chronik — `ChronikEntryChanged` und `ChronikClearedForSession`.

  Die beiden gehören zusammen und nur zusammen: der Clear setzt einen
  **Watermark** statt zu löschen (#698, I7-Bucket-D), und der Entry-Fold
  entscheidet über dieselbe `generation`, ob eine Row ihn überlebt. Getrennt
  gelesen ergibt keiner von beiden Sinn.

  Läuft im selben Prozess und derselben Mnesia-Transaktion wie der
  Materializer-GenServer; die geteilten Helfer kommen wie in Apply1/Apply2 via
  `import Worker.Materializer` herein.
  """
  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  def apply_kind("ChronikEntryChanged", payload, _ts, meta) do
    # Issue #135: in_game_sort_key wird nicht mehr persistiert — Sort am
    # Read-Path. Payload-Feld bleibt akzeptiert (BC für ältere Events) und
    # wird ignoriert.
    # Issue #114: source_refs trailing — Stage 4 emittiert die utterance_ids
    # pro Eintrag aus dem Epos-Kontext + Session-Utterance-Liste.
    # Issue #385: markdown_body am Ende — verbatim User-Markdown für die
    # Chronik-Anzeige. nil bei alten Events (BC), wird beim ersten Edit
    # via Hub-Form gefüllt.
    # Issue #724: in_game_day (kanonischer Tageszähler, Sort-Schlüssel) +
    # precision (Rendering) trailing. nil bei :chain-Events + alten Events (BC).
    # Issue #698 (I7): generation (UUIDv7) trailing — Ordnungsschlüssel für den
    # Clear-Watermark-Vergleich am Read + LWW-by-generation bei gleicher id.
    # Pipeline-Runs setzen `payload["generation"]` (eine pro Run, Clear + alle
    # Entries teilen sie → within-run zuverlässig). Solitäre Events (Hub-Manual-
    # Edit, Seeds) haben keine → Fallback auf die Envelope-event_id (frisch/
    # später → live + gewinnt LWW). Ein schlüsselloses Alt-Event überschreibt
    # eine reguläre Row NICHT (chronik_entry_supersedes?/2).
    #
    # Issue #766 (I7-Bucket-C): bewusst NICHT auf die generische fold_meta-
    # Sidecar migriert (anders als session_facts/session_faithfulness_scores,
    # siehe #816). `generation` hat einen zweiten Leser
    # (Worker.Repo.Artifacts.chronik_entry_live?/2, Bucket-D-Liveness-Vergleich
    # gegen chronik_clear_marks) — der Sidecar-Wechsel würde den Read-Pfad
    # mitreißen und Bucket-C/Bucket-D-Zuständigkeiten vermischen. Bleibt auf
    # der eigenen Spalte, bis Bucket D ohnehin angefasst wird.
    # Issue #1092: source_pos trailing — Position der frühesten Quelle im
    # geglätteten Transkript, Sekundärschlüssel innerhalb eines In-Game-Tages.
    # nil bei manuellen Edits, Seeds und Alt-Events (BC) → der Reader sortiert
    # die ans Ende ihres Tages.
    # Issue #914 (Cut 0): der manuelle Chronik-Edit (source="manual") schreibt
    # in das generation-immune chronik_overrides-Overlay statt in die Row, die
    # der nächste Regenerate-Clear leert. Der generierte Timeline-Publish
    # (source != "manual") läuft unverändert in chronik_entries.
    if payload["source"] == "manual" do
      Worker.Materializer.RenderSlots.chronik_curated(payload, meta)
    else
      id = payload["id"]
      generation = payload["generation"] || Map.get(meta, :event_id)

      if event_id_supersedes?(generation, existing_chronik_generation(id)) do
        :ok =
          :mnesia.write({
            S.chronik_entries(),
            id,
            payload["campaign_id"],
            payload["in_game_date"],
            payload["label"],
            payload["summary"],
            payload["session_id"],
            payload["source_refs"] || [],
            payload["markdown_body"],
            payload["in_game_day"],
            payload["precision"],
            generation,
            payload["source_pos"]
          })
      end

      :ok
    end
  end

  # Issue #227: Re-Run-Cleanup einer (campaign, session)-Chronik. Die Pipeline
  # emittiert das vor jedem Stage-4-Publish, damit Re-Runs keine Halluzinationen
  # früherer Läufe akkumulieren.
  #
  # Issue #698 (I7-Bucket-D): KEIN physisches Delete mehr — das war die
  # Resurrection-Quelle. Bei umgeordnetem Cold-Start-Replay konnte ein Clear VOR
  # den ChronikEntryChanged-Events eines früheren Runs greifen (löschte ins
  # Leere), dann lebten die Entries beim späteren Apply wieder auf (#698-Zombies,
  # #696-Klasse). Stattdessen: den Clear-Watermark der Session auf max(existing,
  # event_id) heben. `list_chronik_entries` filtert Rows mit event_id <= clear_key
  # raus. Der Producer emittiert den Clear VOR den Run-Entries → deren event_id
  # ist größer → live; Entries eines früheren Runs sind kleiner → unterdrückt.
  # Konvergent: egal in welcher Reihenfolge Clear/Entries applied werden, das
  # Endergebnis (Rows + Mark) und damit der gefilterte Read ist identisch.
  def apply_kind("ChronikClearedForSession", payload, _ts, meta) do
    campaign_id = payload["campaign_id"]
    session_id = payload["session_id"]
    generation = payload["generation"] || Map.get(meta, :event_id)

    if is_binary(session_id) and is_binary(generation) do
      new_key = max_clear_key(existing_clear_key(session_id), generation)
      :ok = :mnesia.write({S.chronik_clear_marks(), session_id, campaign_id, new_key})
    else
      Logger.warning(
        "ChronikClearedForSession: fehlende session_id/generation " <>
          "(sid=#{inspect(session_id)} gen=#{inspect(generation)}) — kein Clear-Mark gesetzt"
      )

      :ok
    end
  end

  # Kein Chronik-Kind → der Router probiert Apply2 (Sentinel-Konvention wie
  # in Apply1).
  def apply_kind(_kind, _payload, _ts, _meta), do: :__unhandled__

  # ─── Helfer ─────────────────────────────────────────────────────────

  # generation (12. Attribut → elem 11) der bestehenden Row, oder nil.
  defp existing_chronik_generation(id) do
    case :mnesia.read(S.chronik_entries(), id) do
      [row] when tuple_size(row) >= 12 -> elem(row, 11)
      _ -> nil
    end
  end

  # Clear-Watermark (elem 3) der Session, oder nil.
  defp existing_clear_key(session_id) do
    case :mnesia.read(S.chronik_clear_marks(), session_id) do
      [{_, _, _, key}] -> key
      [] -> nil
    end
  end

  defp max_clear_key(nil, new), do: new
  defp max_clear_key(existing, new), do: max(existing, new)
end
