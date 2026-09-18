defmodule Worker.Recording.AudioBuffer.Archivierung do
  @moduledoc """
  Issue #1054: Entscheidet nach einem Transkriptions-Lauf, was mit dem Audio
  geschieht — und zwar **je Spur**, nicht je Sitzung.

  Vorher hing die Entscheidung allein am Ende-Grund des Tasks: `:normal` →
  archivieren, sonst liegen lassen. Weil die `GpuQueue` jede Ausnahme abfängt
  und als Rückgabewert weiterreicht (`gpu_queue.ex`, `rescue` im Job-Prozess)
  und der Task diesen Wert verwarf, endete der Task **auch nach einem
  Fehlschlag normal**. Damit war der `else`-Zweig mit dem Versprechen „Audio
  bleibt liegen für Crash-Recovery-Retry" für jede Ausnahme in der
  Transkription toter Code — genau das ist am 13.08.2026 passiert: Spur 2 von
  18 riss den Lauf hoch, die restlichen 16 wurden nie transkribiert, und das
  Audio wurde trotzdem weggeräumt.

  ## Warum je Spur und nicht je Sitzung

  Naheliegend wäre: sobald irgendetwas schiefging, das ganze Verzeichnis
  liegen lassen. Das wäre eine **Verschlechterung**, denn die
  Wiederherstellung (`Recovery.recover_files/2`) baut ihre Arbeitsliste aus
  den `.webm`-Dateien, die sie im Verzeichnis **vorfindet**. Läge alles noch
  da, transkribierte sie beim nächsten Durchgang auch die bereits geglückten
  Spuren erneut — in einer Discord-Sitzung sind das hunderte Segmente
  (real gemessen: 651 Spuren in einer Sitzung), und jede erzeugte ihre
  Utterances ein zweites Mal. Aus einem Loch im Protokoll würde ein doppeltes
  Protokoll.

  Deshalb wandern die geglückten Spuren ins Archiv und **nur die
  gescheiterten bleiben liegen**. Die vorhandene Wiederherstellung braucht
  dafür keine Zeile Änderung: sie findet beim nächsten Durchgang genau die
  Spuren vor, die noch offen sind.

  ## Fail-closed, wenn nichts gemeldet wurde

  Ein Task, der normal endet, ohne sein Ergebnis gemeldet zu haben, ist kein
  Beleg für Erfolg — er ist ein unbekannter Zustand. Dann bleibt alles
  liegen. Das Risiko ist damit ein doppeltes Protokoll (sichtbar, korrigierbar)
  statt eines verlorenen Spielabends (unsichtbar, endgültig); bei `audio_done_dir
  = nil` bedeutet Archivieren nämlich Löschen.
  """

  @typedoc "Was mit dem Audio der Sitzung geschehen soll."
  @type entscheid :: :alles | {:teilweise, [String.t()]} | :liegen_lassen

  @typedoc """
  Was der Transkriptions-Task gemeldet hat: `:ok` (alle Spuren durch),
  `{:teilweise, keys}` (diese Spuren sind gescheitert), ein Fehler der
  Warteschlange (der Auftrag lief gar nicht), oder `nil` (nichts gemeldet).
  """
  @type ergebnis :: :ok | {:teilweise, [String.t()]} | {:error, term()} | nil

  @doc """
  Der Archivierungs-Entscheid aus Ende-Grund des Tasks und gemeldetem Ergebnis.

  Der Ende-Grund allein reicht nicht (er ist nach einem abgefangenen Fehler
  `:normal`), das Ergebnis allein auch nicht (bei einem harten Kill wird keins
  mehr gesendet). Beide zusammen ergeben die Aussage.
  """
  @spec entscheide(term(), ergebnis()) :: entscheid()
  def entscheide(:normal, :ok), do: :alles

  def entscheide(:normal, {:teilweise, keys}) when is_list(keys) do
    case Enum.uniq(keys) do
      [] -> :alles
      offen -> {:teilweise, offen}
    end
  end

  # Der Auftrag hat die Warteschlange nie verlassen oder ist in ihr gescheitert
  # — dann wurde nichts transkribiert, und nichts darf weggeräumt werden.
  def entscheide(:normal, {:error, _}), do: :liegen_lassen

  # Kein Ergebnis trotz normalem Ende: unbekannter Zustand, s. Moduldoc.
  def entscheide(:normal, nil), do: :liegen_lassen

  # Abnormales Ende (harter Kill, Absturz der Laufzeit): wie bisher.
  def entscheide(_reason, _ergebnis), do: :liegen_lassen

  @doc """
  Teilt die Dateinamen eines Sitzungs-Verzeichnisses in „darf ins Archiv" und
  „bleibt liegen" — gemessen an den Schlüsseln der gescheiterten Spuren.

  Eine Datei gehört zu einer Spur, wenn ihr Name der Schlüssel selbst ist oder
  mit `<schlüssel>.` beginnt. Bewusst **über den Präfix statt über eine Liste
  bekannter Endungen**: neben `<key>.webm` liegen `<key>.chunks.jsonl`
  (der Zeitanker aus #757) und `<key>.wav` (die Umwandlung), und wer später
  eine vierte Sorte dazulegt, bekommt sie hier geschenkt. Eine vergessene
  Endung hieße sonst, dass der Zeitanker einer offenen Spur ins Archiv wandert
  und die Wiederholung ohne ihn läuft — die Utterances bekämen falsche
  Zeitstempel, ohne dass irgendwo ein Fehler entsteht.

  Dateien, die zu keiner gescheiterten Spur gehören, wandern ins Archiv — mit
  einer Ausnahme, solange überhaupt eine Spur offen ist: **Verwaltungsdateien
  mit führendem Punkt bleiben liegen** (heute `.retention.json`). Sie
  beschreiben das Verzeichnis, nicht eine Spur; ihr Geburtsvermerk gehört zu
  der Sitzung, die dort weiterlebt. Im Archiv entsteht der Vermerk ohnehin
  frisch (`Retention.stamp_purge_after/2`), es geht also nichts verloren.
  """
  @spec aufteilen([String.t()], [String.t()]) :: {[String.t()], [String.t()]}
  def aufteilen(dateinamen, []), do: {dateinamen, []}

  def aufteilen(dateinamen, gescheiterte_keys) do
    Enum.split_with(dateinamen, fn name ->
      not String.starts_with?(name, ".") and not bleibt_liegen?(name, gescheiterte_keys)
    end)
  end

  @doc "Gehört diese Datei zu einer der gescheiterten Spuren?"
  @spec bleibt_liegen?(String.t(), [String.t()]) :: boolean()
  def bleibt_liegen?(name, gescheiterte_keys) do
    Enum.any?(gescheiterte_keys, fn key ->
      name == key or String.starts_with?(name, key <> ".")
    end)
  end
end
