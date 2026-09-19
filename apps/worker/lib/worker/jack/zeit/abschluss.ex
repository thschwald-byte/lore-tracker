defmodule Worker.Jack.Zeit.Abschluss do
  @moduledoc """
  #1247 (Z2): was `fertig()` verlangt, bevor ein Lauf enden darf. Pur.

  Maintainer (19.09.2026): **„fertig verlangt, dass jedes utt zugeordnet ist:
  entweder davor/danach oder fällt raus."**

  Das zerfällt in zwei Bedingungen, und die erste ist die, die man leicht für
  Diagnostik hält:

  ## 1. Jede Zeile muss ausgegeben worden sein

  Die Erzählposition **ist** eine Zuordnung — „danach", relativ zum Vorgänger.
  Wer nichts anfasst, hat damit nichts offen, und 3.679 Zeilen einzeln zu
  quittieren wäre ein Lauf, der nichts anderes mehr tut.

  **Aber genau deshalb muss Jack sie gesehen haben.** Der Unterschied zur
  Extraktion entscheidet das (Review, 19.09.2026): Dort heißt „kein Fakt" nur
  *nichts gefunden*, eine Aussage über die Ausbeute. Hier heißt „nicht
  angefasst" *die Grundordnung stimmt für diese Zeile* — eine Aussage über die
  Welt. Ohne die Schranke hieße `fertig` bloß „Jack hat aufgehört": Er könnte
  nach zehn Zeilen abschließen, und die übrigen gälten als richtig
  eingeordnet. Ein Fehler, der wie ein Ergebnis aussieht.

  Das Vorbild ist `Worker.Jack.Abschluss.nie_gelesen/1`.

  ## 2. Die Reihe muss eindeutig sein

  Offen ist, was angefasst und nicht zu Ende gebracht wurde: eine Verschiebung
  ohne auflösbares Ziel, zwei Anker, die dieselbe Stelle an zwei Orte ziehen.
  Was niemand angefasst hat, steht.

  ## Die Antwort nennt Zahlen, keine Andeutung

  `fertig` lehnt nie ab, ohne zu sagen **wie viel** fehlt und **wo** — sonst
  zählt Jack nach, statt zu arbeiten. Beim Chronik-Jack kostete genau das
  einen Lauf: Die Ablehnung verschwieg die gezählte Zahl, und er ging 112
  Fakten noch einmal durch, obwohl seine Arbeit vollständig war (#1211).
  """

  alias Worker.Jack.Zeit.Stand

  @deckel 12

  @doc """
  Die Hindernisse, die einem Abschluss entgegenstehen — leer heißt: darf
  abschließen. Jeder Eintrag ist ein Satz für das Modell, mit Zahl.
  """
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{lauf: :gedaechtnis} = s), do: fakten_ungelesen(s)
  def hindernisse(%Stand{} = s), do: ungelesen(s) ++ ohne_ziel(s)

  # **Der Gedächtnis-Lauf hat einen anderen Gegenstand** (#1247, Befund des
  # ersten echten Laufs): Er liest die FAKTEN, um den Ablauf zu verstehen, und
  # setzt nichts. Gegen die Zeilen-Abdeckung zu prüfen wäre dieselbe
  # Verwechslung, die beim Chronik-Jack den Überblick gegen die Einträge
  # prüfte, die es dort noch gar nicht gibt — `fertig` verwies auf ein
  # Werkzeug, das dieser Lauf nicht hat, und Jack wiederholte bis zur Sperre.
  defp fakten_ungelesen(%Stand{} = s) do
    case Stand.offene_fakten(s, @deckel) do
      %{anzahl: 0} ->
        []

      %{anzahl: n, fakten: naechste} ->
        [
          "#{n} von #{length(s.fakten)} Fakten hast du noch nicht gelesen. Ohne sie " <>
            "fehlt dir der Ablauf, gegen den der nächste Lauf die Äußerungen liest. " <>
            "Die nächsten: #{Enum.map_join(naechste, ", ", &Stand.fakt_id/1)}."
        ]
    end
  end

  @doc "Die Zeilen, die Jack nie ausgegeben bekommen hat."
  @spec nie_gelesen(Stand.t()) :: [map()]
  def nie_gelesen(%Stand{} = s) do
    Enum.reject(s.mitschnitt, &MapSet.member?(s.gelesen, &1.utterance_id))
  end

  defp ungelesen(s) do
    case nie_gelesen(s) do
      [] ->
        []

      fehlend ->
        [
          "#{length(fehlend)} von #{length(s.mitschnitt)} Zeilen hast du noch nicht " <>
            "gelesen. Eine ungelesene Zeile gilt als „steht an ihrer Erzählposition“ — " <>
            "das ist eine Aussage über die Welt, und die kannst du nur treffen, wenn du " <>
            "sie gesehen hast. Die nächsten: #{nummern(fehlend)}."
        ]
    end
  end

  # Eine Verschiebung ohne auflösbares Ziel lässt ihre Zeilen zwischen zwei
  # Orten hängen: Sie stehen weder an ihrer Erzählposition noch anderswo.
  defp ohne_ziel(s) do
    offen =
      s.anker
      |> Map.values()
      |> Enum.filter(fn a ->
        to_string(feld(a, :art)) == "ordnung" and not erreichbar?(s, feld(a, :ziel))
      end)

    case offen do
      [] ->
        []

      liste ->
        [
          "#{length(liste)} Verschiebung(en) nennen kein auflösbares Ziel und bleiben " <>
            "wirkungslos. Betroffen: #{liste |> Enum.map(&feld(&1, :anker_id)) |> Enum.join(", ")}."
        ]
    end
  end

  defp erreichbar?(_s, nil), do: false
  defp erreichbar?(_s, ""), do: false

  defp erreichbar?(s, ziel),
    do: Enum.any?(s.mitschnitt, &(&1.utterance_id == ziel))

  defp nummern(fehlend) do
    fehlend
    |> Enum.take(@deckel)
    |> Enum.map(&to_string(&1.nr))
    |> Enum.join(", ")
    |> Kernel.<>(if length(fehlend) > @deckel, do: " …", else: "")
  end

  defp feld(a, k) when is_map(a), do: Map.get(a, k) || Map.get(a, to_string(k))
end
