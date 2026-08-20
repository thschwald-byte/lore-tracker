defmodule Worker.Repo.PipelineStand do
  @moduledoc """
  Issue #1122: Snapshot-Scope `campaign_pipeline` — der Stand der
  Pipeline-Läufe einer Kampagne, für das Laufband.

  Der Scope beantwortet die Frage „was sieht jemand, der die Seite MITTEN im
  Lauf öffnet?". Ohne ihn bliebe die Anzeige leer, bis zufällig die nächste
  Stufenmeldung eintrifft: der Zustand lebt im Koordinator-Prozess und wurde
  bislang nirgends erfragt. Genau diese Lücke ließ eine frühere Replay-Anzeige
  einen längst toten Lauf als aktiv zeigen.

  **Warum ein eigenes Modul und nicht `Worker.Repo.Snapshots`:** zwei Gründe,
  der erste ist der inhaltliche. Alle Scopes dort lesen Mnesia; dieser liest
  einen laufenden Prozess, dessen Zustand nach einem Neustart weg ist. Das ist
  eine andere Art von Wahrheit und verdient einen eigenen Ort. Der zweite Grund
  ist mechanisch: `snapshots.ex` steht mit 602 Code-Zeilen auf der
  Ratschen-Liste des God-Module-Checks und darf nicht wachsen. Die Ratsche
  anzuheben wäre die falsche Antwort gewesen — sie soll schrumpfen, nicht
  mitwachsen.

  Eingehängt wird der Scope in `Worker.Repo.snapshot/1`, vor der Delegation an
  `Snapshots`.
  """

  import Worker.Repo, only: [member?: 2]

  alias Worker.Recording.Pipeline.Fortschritt

  @doc """
  Member-gated wie die übrigen schmalen Kampagnen-Scopes.

  Liefert die Läufe dieser Kampagne, jüngster zuerst — jeder mit allen Stufen,
  auch den noch nicht gelaufenen. Ohne die offenen Stufen könnte die Anzeige
  nicht sagen, was noch aussteht.
  """
  @spec snapshot(map()) :: map()
  def snapshot(%{"id" => id, "viewer_discord_id" => viewer}) do
    if member?(id, viewer) do
      %{"laeufe" => Enum.filter(Fortschritt.alle(), &(&1["campaign_id"] == id))}
    else
      %{"forbidden" => true}
    end
  end
end
