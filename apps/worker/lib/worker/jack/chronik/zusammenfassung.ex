defmodule Worker.Jack.Chronik.Zusammenfassung do
  @moduledoc """
  Was nach einer Kompaktierung im Chronik-Jack an die Stelle des
  weggeschnittenen Verlaufs tritt (J7, #1211) — ein Arbeitsstand, den die
  Werkzeuge aus ihren Daten schreiben, keine Zusammenfassung durch das
  Modell (Muster `Worker.Jack.Resuemee.Zusammenfassung`).

  **Warum das hier besonders zählt.** Der Chronik-Jack sieht die ganze
  Kampagne; sein Verlauf wird schneller lang als der eines Resümee-Laufs, und
  er wird deshalb öfter kompaktiert. Was danach dasteht, ist alles, was er
  über seine eigene Arbeit weiss. Die Chronik selbst steht immer darin — mit
  ihrer Reihenfolge, damit er nach dem Schnitt nicht dieselben Einträge noch
  einmal anlegt.

  **Die offenen Fakten stehen ebenfalls darin.** Sie sind der Grund, warum
  `fertig` ablehnt, und ohne sie beginnt Jack nach jedem Schnitt die Suche
  von vorn.
  """

  alias Worker.Jack.Chronik.{Abschluss, Entwurf, Lesen}
  alias Worker.Jack.Resuemee.Stand
  alias Worker.Jack.Resuemee.Zusammenfassung, as: Gemeinsam

  @kopf "# Stand deiner Arbeit (von deinen Werkzeugen geschrieben, nicht zusammengefasst)"

  @doc "Der Rückruf für `kontext: [zusammenfassen: …]` eines Laufs mit diesem Halter."
  @spec fuer(pid()) :: (map() -> String.t())
  def fuer(halter), do: Gemeinsam.fuer(halter, &text/1)

  @doc "Der Arbeitsstand als Text."
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{lauf: :ueberblick} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "Du liest die Fakten der Kampagne (#{length(s.fakten)}) und teilst die Handlung " <>
          "in Abschnitte. Ein ganzer Auftrag ist EIN Abschnitt.",
        "",
        "## Deine Notizen",
        notizen(s),
        "",
        "## Was noch offen ist",
        offen(s),
        "",
        "Weiter mit notiz(). Wenn jedes Geschehen in einer Gruppe liegt: fertig()."
      ],
      "\n"
    )
  end

  def text(%Stand{lauf: :durchsicht} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "Du gehst die Chronik Eintrag für Eintrag durch.",
        "",
        "## Die Chronik",
        Lesen.text(s),
        "",
        "## Durchgang",
        durchgang(s),
        "",
        "Weiter mit durchsicht(nummer), dann eintrag_bestaetigen() oder " <>
          "eintrag_ersetzen()."
      ],
      "\n"
    )
  end

  def text(%Stand{} = s) do
    Enum.join(
      [
        @kopf,
        "",
        "Du schreibst die Chronik der Kampagne — gebündelte Phasen, kein " <>
          "Sitzungsprotokoll.",
        "",
        "## Die Chronik, wie sie jetzt aussieht",
        Lesen.text(s),
        "",
        "## Was noch offen ist",
        offen(s),
        "",
        "## Deine Notizen",
        notizen(s),
        "",
        "Weiter mit chronik_eintrag() oder eintrag_ergaenzen(). Wenn jedes " <>
          "Geschehen in einem Eintrag liegt: fertig()."
      ],
      "\n"
    )
  end

  defp offen(%Stand{} = s) do
    case Entwurf.offene_fakten(s.eintraege, Abschluss.ereignisse(s)) do
      [] ->
        "Jedes Geschehen liegt in einem Eintrag. Du kannst fertig() rufen."

      ids ->
        "#{length(ids)} Geschehen liegen in keinem Eintrag: " <>
          (ids |> Enum.take(20) |> Enum.join(", ")) <>
          if(length(ids) > 20, do: " und #{length(ids) - 20} weitere", else: "")
    end
  end

  defp notizen(%Stand{notizen: []}), do: "(noch keine)"

  defp notizen(%Stand{notizen: notizen}),
    do: Enum.map_join(notizen, "\n", &"- **#{&1.schluessel}** (#{&1.abschnitt}): #{&1.zeile}")

  defp durchgang(%Stand{durchsicht: nil}), do: "Noch nichts vorgelegt."

  defp durchgang(%Stand{durchsicht: d}) do
    "Durchgang #{d.durchgang}, #{map_size(d.erledigt)} von #{length(d.vorgelegt)} " <>
      "vorgelegten Einträgen bearbeitet."
  end
end
