defmodule Worker.Jack.Zeit.Zusammenfassung do
  @moduledoc """
  #1247 (Z2): Was nach einer Kompaktierung an die Stelle des weggeschnittenen
  Verlaufs tritt — ein Arbeitsstand, den die Werkzeuge aus ihren Daten
  schreiben, keine Zusammenfassung durch das Modell (Muster
  `Worker.Jack.Chronik.Zusammenfassung`).

  **Hier zählt vor allem eines: was noch ungelesen ist.** Der Zeit-Jack
  arbeitet sich durch tausende Äußerungen, sein Verlauf wird schnell lang,
  und die Leseabdeckung ist die Schranke vor `fertig()`. Steht sie nach dem
  Schnitt nicht da, fängt er von vorn an zu suchen — oder schlimmer, er hält
  sich für fertig.

  **Eine eigene Fassung statt `Resuemee.Zusammenfassung.fuer/2`:** Jene
  schreibt bei jedem Aufruf einen Journaleintrag über `Stand.journal/3`, und
  die gibt es im Zeit-Stand nicht. Ein Journal wäre hier auch das falsche
  Mittel — der Lauf hat keine Absätze, die man nachlesen will, sondern
  Anker, die ohnehin gespeichert werden.
  """

  alias Worker.Agent.Kontext
  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.Abschluss
  alias Worker.Jack.Zeit.Stand

  @doc "Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem Halter."
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter) do
    fn arg ->
      case Halter.lesen(halter, &text/1) do
        t when is_binary(t) -> t
        _ -> Kontext.standard_zusammenfassung(arg)
      end
    end
  end

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{} = s) do
    z = Stand.zahlen(s)

    Enum.join(
      [
        "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)",
        "",
        aufgabe(s.lauf),
        "",
        "## Zahlen",
        "Zeilen: #{z.utterances}, gelesen #{z.gelesen}, offen #{z.offen}",
        "Anker: #{z.anker} (Zeitpunkte #{z.zeitpunkte}, Spannen #{z.spannen}, " <>
          "Verschiebungen #{z.verschiebungen})",
        "Gelöst: #{z.geloest}, Konflikte: #{z.konflikte}",
        "",
        "## Was noch offen ist",
        offen(s),
        "",
        weiter(s.lauf, z)
      ],
      "\n"
    )
  end

  defp aufgabe(:gedaechtnis),
    do: "Du liest die Fakten der Kampagne und baust dir ein Bild vom Ablauf. Du setzt nichts."

  defp aufgabe(:pruefen),
    do:
      "Du prüfst die entstandene Linie und rückst gerade, was nicht stimmt. " <>
        "Geh von den Befunden aus, nicht von Zeile 1."

  defp aufgabe(_),
    do:
      "Du gehst durch den Mitschnitt und ordnest die Äußerungen ein: Anker, " <>
        "Spannen, Verschiebungen — oder begründet aus der Kette lösen."

  # Die Bereiche, nicht nur die Zahl: Ohne sie weiss Jack nach dem Schnitt,
  # DASS etwas fehlt, aber nicht wo — und liest von vorn.
  defp offen(%Stand{} = s) do
    case Stand.offen(s) do
      %{anzahl: 0} -> "Alle Zeilen gelesen."
      %{anzahl: n, zeilen: zeilen} -> "#{n} Zeilen ungelesen: #{Abschluss.bereiche(zeilen)}"
    end
  end

  defp weiter(_lauf, %{offen: 0}), do: "Alles gelesen — fertig() geht, wenn nichts mehr offen ist."

  defp weiter(_lauf, %{offen: n}),
    do: "Weiter mit mitschnitt(). Noch #{n} Zeilen ungelesen; fertig() lässt dich so nicht durch."
end
