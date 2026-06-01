defmodule Mix.Tasks.Lore.Seed.BackfillRefs do
  @shortdoc "Backfill source_refs in committed demo-seed JSONL (Issue #350)"

  @moduledoc """
  Hebt die committed statischen Demo-Seeds auf das Post-#114-Schema: hängt
  `source_refs` (Liste von Utterance-IDs) an die Derived-Stage-Events
  (SessionSummaryGenerated / EposEntryEdited / ChronikEntryChanged) an, berechnet
  deterministisch per lexical-overlap (`Mix.Tasks.Lore.Seed.SourceRefs`).

      mix lore.seed.backfill_refs paraphrase
      mix lore.seed.backfill_refs vox-machina
      mix lore.seed.backfill_refs schlegel-de

  **One-shot Dev-Tool**: schreibt die JSONL **in place**. Einmal pro Dataset
  laufen lassen, das Resultat committen. Der Task bleibt committed für
  Reproduzierbarkeit (re-run wenn sich Seeds ändern).

  Schreib-Mechanik (minimaler Diff): nur die Derived-Event-Zeilen werden neu
  encodet (parse → source_refs injizieren → Jason.encode!), alle anderen Zeilen
  (Utterances, Kommentare, Leerzeilen) werden **byte-identisch** durchgereicht.
  Trailing-Newline bleibt erhalten (split/join auf "\\n" round-trippt exakt).

  Sonderfall `schlegel-de`: die Summaries nutzen das alte `summary_text`-Feld
  (materialisiert LEER, weil der Materializer `content_md` liest) → wird zu
  `content_md` umbenannt (fixt den Empty-Render-Bug). Epos/Chronik-Generierung
  für schlegel-de ist NICHT Teil von #350 (eigenes Issue) — der Dataset hat
  keine, hier wird nur upgehoben was da ist (best-effort Refs auf den knappen
  Meta-Summaries).
  """

  use Mix.Task

  alias Mix.Tasks.Lore.Seed.SourceRefs

  @repo_root Path.expand("../../../../..", __DIR__)

  @datasets %{
    "paraphrase" => "apps/hub/priv/seeds/romeo/paraphrase",
    "vox-machina" => "apps/hub/priv/seeds/vox-machina",
    "schlegel-de" => "apps/hub/priv/seeds/romeo/schlegel-de"
  }

  @summary_kind "SessionSummaryGenerated"
  @epos_kind "EposEntryEdited"
  @chronik_kind "ChronikEntryChanged"
  @derived_kinds [@summary_kind, @epos_kind, @chronik_kind]

  @impl Mix.Task
  def run([dataset]) do
    dir =
      case Map.fetch(@datasets, dataset) do
        {:ok, rel} ->
          Path.join(@repo_root, rel)

        :error ->
          Mix.raise(
            "Unbekanntes Dataset #{inspect(dataset)}. Bekannt: #{Enum.join(Map.keys(@datasets), ", ")}"
          )
      end

    unless File.dir?(dir), do: Mix.raise("Seed-Verzeichnis nicht gefunden: #{dir}")

    files = dir |> Path.join("*.jsonl") |> Path.wildcard() |> Enum.sort()
    Mix.shell().info("Backfill source_refs → #{dataset} (#{length(files)} Dateien)")

    # Pass 1: alle Utterances sammeln, gruppiert nach session_id.
    utts_by_session = collect_utterances(files)

    # Pass 1.5: Summary-Refs pro Session vorberechnen; Epos-Refs = Union.
    summary_refs = precompute_summary_refs(files, utts_by_session)
    epos_refs = SourceRefs.union_refs(Map.values(summary_refs))

    # Pass 2: Dateien zeilenweise neu schreiben (nur Derived-Zeilen ändern sich).
    empty_count =
      Enum.reduce(files, 0, fn file, acc ->
        acc + rewrite_file(file, utts_by_session, summary_refs, epos_refs)
      end)

    Mix.shell().info("  fertig. Derived-Einträge ohne Refs (unter Schwelle): #{empty_count}")
  end

  def run(_),
    do: Mix.raise("Usage: mix lore.seed.backfill_refs <paraphrase|vox-machina|schlegel-de>")

  # ─── Pass 1: Utterances sammeln ──────────────────────────────────

  defp collect_utterances(files) do
    files
    |> Enum.flat_map(&parsed_events/1)
    |> Enum.filter(&(&1["kind"] == "UtteranceAppended"))
    |> Enum.group_by(& &1["session_id"], fn u ->
      %{"id" => u["id"], "text" => u["text"]}
    end)
  end

  # ─── Pass 1.5: Summary-Refs pro Session ──────────────────────────

  defp precompute_summary_refs(files, utts_by_session) do
    files
    |> Enum.flat_map(&parsed_events/1)
    |> Enum.filter(&(&1["kind"] == @summary_kind))
    |> Map.new(fn ev ->
      sid = ev["session_id"]
      {sid, SourceRefs.compute_refs(summary_text(ev), Map.get(utts_by_session, sid, []))}
    end)
  end

  # ─── Pass 2: Dateien neu schreiben ───────────────────────────────

  # Gibt die Anzahl der Derived-Einträge zurück, die unter Schwelle ref-leer
  # geblieben sind (für das Logging).
  defp rewrite_file(file, utts_by_session, summary_refs, epos_refs) do
    content = File.read!(file)
    lines = String.split(content, "\n")

    {new_lines, empty} =
      Enum.map_reduce(lines, 0, fn line, empty ->
        case derived_event(line) do
          nil ->
            {line, empty}

          ev ->
            {ev2, refs} = inject_refs(ev, utts_by_session, summary_refs, epos_refs)
            empty = if refs == [], do: empty + 1, else: empty
            {Jason.encode!(ev2), empty}
        end
      end)

    File.write!(file, Enum.join(new_lines, "\n"))
    empty
  end

  # Parst eine Zeile NUR wenn sie ein Derived-Event ist; sonst nil (Zeile bleibt
  # byte-identisch). Kommentare/Leerzeilen/andere Events → nil.
  defp derived_event(line) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, %{"kind" => k} = ev} when k in @derived_kinds -> ev
        _ -> nil
      end
    end
  end

  defp inject_refs(%{"kind" => @summary_kind} = ev, _utts, summary_refs, _epos) do
    sid = ev["session_id"]
    refs = Map.get(summary_refs, sid, [])

    ev
    # schlegel-de: summary_text → content_md (fixt Empty-Render). No-op wenn
    # content_md schon da ist (paraphrase/vox).
    |> migrate_summary_text()
    |> Map.put("source_refs", refs)
    |> then(&{&1, refs})
  end

  defp inject_refs(%{"kind" => @epos_kind} = ev, _utts, _summary, epos_refs) do
    {Map.put(ev, "source_refs", epos_refs), epos_refs}
  end

  defp inject_refs(%{"kind" => @chronik_kind} = ev, utts_by_session, _summary, _epos) do
    sid = ev["session_id"]
    refs = SourceRefs.compute_refs(ev["summary"], Map.get(utts_by_session, sid, []))
    {Map.put(ev, "source_refs", refs), refs}
  end

  defp migrate_summary_text(%{"content_md" => cm} = ev) when is_binary(cm), do: ev

  defp migrate_summary_text(%{"summary_text" => st} = ev) when is_binary(st) do
    ev |> Map.delete("summary_text") |> Map.put("content_md", st)
  end

  defp migrate_summary_text(ev), do: ev

  # ─── Helpers ─────────────────────────────────────────────────────

  defp summary_text(ev), do: ev["content_md"] || ev["summary_text"] || ""

  defp parsed_events(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, ev} -> [ev]
        _ -> []
      end
    end)
  end
end
