defmodule Worker.Status.Lage do
  @moduledoc """
  Issue #1218: die Statusmap für den lesenden Endpunkt — **pur**.

  Nimmt die Läufe aus `Worker.Recording.Pipeline.Fortschritt`, das
  Aufnahme-Flag und (später) die Teilnehmer und baut daraus, was eine Anzeige
  braucht. Keine Prozesse, kein Mnesia, kein Socket: die ganze Ableitung ist
  hier testbar.

  Zwei Regeln aus #1122, die hier weiterleben:

  - **Zahlen nur, wo es zählbare Einheiten gibt.** Stufen ohne Einheit (das
    Schreiben von Resümee und Epos, die Chronik) bekommen keine — ein `1/1`
    wäre eine Attrappe.
  - **„Läuft" ist nicht dasselbe wie „regt sich".** Der Lauf-Zustand lebt im
    Arbeitsspeicher; stirbt der Prozess mitten im Lauf, bleibt die letzte Stufe
    als laufend stehen. Ab `Shared.PipelineStufen.still_ms/0` ohne Regung heißt
    der Zustand deshalb `"still"`, nicht `"laeuft"`. Eine Leuchte, die „läuft"
    sagt, obwohl nichts läuft, ist dieselbe Falle wie eine Anzeige, die es
    behauptet.
  """

  alias Shared.PipelineStufen

  @typedoc "Ein Lauf, wie ihn `Fortschritt.serialisiere/1` liefert."
  @type lauf :: map()

  @doc """
  Die Statusmap. `laeufe` ist die Liste aus `Fortschritt.alle/0` (jüngster
  zuerst), `aufnahme?` das Aufnahme-Flag, `teilnehmer` die pseudonyme
  Sprecherliste aus `Worker.Status.Praesenz` (leer heißt: keine Sprecherdaten —
  das ist etwas anderes als „niemand spricht").
  """
  @spec baue([lauf()], boolean(), [map()]) :: map()
  def baue(laeufe, aufnahme?, teilnehmer \\ []) when is_list(laeufe) and is_list(teilnehmer) do
    lauf = interessanter_lauf(laeufe)

    %{
      "aufnahme" => aufnahme? == true,
      "lauf" => lauf_map(lauf),
      "gruppen" => gruppen(lauf),
      "teilnehmer" => teilnehmer
    }
  end

  # Ein aktiver Lauf schlägt den jüngsten: nach einem abgeschlossenen Lauf steht
  # der nächste oft schon in der Liste, und die Anzeige soll den zeigen, an dem
  # gerade gearbeitet wird.
  defp interessanter_lauf(laeufe) do
    Enum.find(laeufe, &(&1["aktiv"] == true)) || List.first(laeufe)
  end

  defp lauf_map(nil), do: nil

  defp lauf_map(lauf) do
    stufe = laufende_stufe(lauf)

    %{
      "zustand" => zustand(lauf),
      "still_seit_ms" => lauf["still_seit_ms"],
      "stufe" => stufe && stufe["name"]
    }
    |> mit_zahlen(stufe)
  end

  # `fertig`/`gesamt` reisen nur mit, wenn die Stufe zählbare Einheiten hat und
  # ihre Gesamtzahl schon kennt. „3 von ?" ist keine Auskunft.
  defp mit_zahlen(map, %{"gesamt" => gesamt, "fertig" => fertig}) when is_integer(gesamt) do
    Map.merge(map, %{"erledigt" => fertig, "gesamt" => gesamt})
  end

  defp mit_zahlen(map, _), do: map

  defp laufende_stufe(lauf) do
    Enum.find(lauf["stufen"] || [], &(&1["status"] == "laeuft"))
  end

  defp zustand(lauf) do
    still? =
      is_integer(lauf["still_seit_ms"]) and lauf["still_seit_ms"] > PipelineStufen.still_ms()

    cond do
      pflicht_fehler?(lauf["stufen"] || []) -> "fehler"
      lauf["aktiv"] != true -> "fertig"
      still? -> "still"
      true -> "laeuft"
    end
  end

  @doc """
  Die Spaltengruppen in Laufreihenfolge, jede mit ihrem Zustand.

  Die Gruppen kommen aus `Shared.PipelineStufen`, nicht aus einer zweiten Liste:
  eine Stufe, die dort dazukommt, taucht hier von selbst auf. Stufen ohne Spalte
  (die Bogen-Progressionen) bilden die Gruppe `"boegen"`.

  Vorrang der Zustände: eine gescheiterte **Pflichtstufe** schlägt alles, dann
  „läuft", dann eine gescheiterte **Zugabe**, dann „fertig", sonst „offen". Die
  Unterscheidung ist der Punkt: eine gescheiterte Zugabe hält den Lauf nicht an,
  eine gescheiterte Pflichtstufe beendet ihn.
  """
  @spec gruppen(lauf() | nil) :: [map()]
  def gruppen(lauf) do
    stufen_nach_name = Map.new(lauf["stufen"] || [], &{&1["name"], &1})

    PipelineStufen.alle()
    |> Enum.map(&spalte/1)
    |> Enum.uniq()
    |> Enum.map(fn spalte ->
      stufen =
        PipelineStufen.alle()
        |> Enum.filter(&(spalte(&1) == spalte))
        |> Enum.map(
          &Map.get(stufen_nach_name, &1.name, %{"name" => &1.name, "status" => "offen"})
        )

      %{"spalte" => spalte, "zustand" => gruppenzustand(stufen)}
    end)
  end

  defp spalte(%{spalte: nil}), do: "boegen"
  defp spalte(%{spalte: s}), do: s

  defp gruppenzustand(stufen) do
    status = Enum.map(stufen, & &1["status"])

    cond do
      pflicht_fehler?(stufen) -> "fehler"
      "laeuft" in status -> "laeuft"
      "fehler" in status -> "zugabe_fehler"
      status != [] and Enum.all?(status, &(&1 == "fertig")) -> "fertig"
      true -> "offen"
    end
  end

  defp pflicht_fehler?(stufen) do
    Enum.any?(stufen, fn s ->
      s["status"] == "fehler" and
        match?(%{art: :pflicht}, PipelineStufen.finde(s["name"]))
    end)
  end
end
