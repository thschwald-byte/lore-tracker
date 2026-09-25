defmodule Worker.Jack.Zeit.Werkzeuge do
  @moduledoc """
  #1247 (Z2): die Werkzeuge des Zeit-Jack, je Lauf.

      :gedaechtnis   nur lesen. Den Ablauf verstehen, nichts setzen.
      :einsortieren  die Utterances einordnen: Anker, Spannen, Verschiebungen,
                     oder begründet aus der Kette lösen.
      :pruefen       dieselben Werkzeuge, anderer Gegenstand: die entstandene
                     Linie lesen und geraderücken.

  **Die Regeln stehen in den Werkzeugen, nicht im Auftrag** — wie beim
  Chronik-Jack (#1211). Ein Auftrag wird einmal gelesen und nach einer
  Kompaktierung vergessen; eine Werkzeugbeschreibung steht bei jedem Aufruf
  da, und was das Werkzeug ablehnt, kann das Modell nicht übersehen.

  **Jede Antwort rechnet nach und nennt Zahlen.** Kein „geht nicht" ohne
  Grund und ohne Ausweg: Beim Chronik-Jack kostete eine Ablehnung, die ihre
  gezählte Zahl verschwieg, 28 von 51 Runden.

  ## Adressiert wird über die Zeilennummer des Mitschnitts

  Eine Zeile ist eine **Utterance** — nicht ein Block. Die Nummer ist Jacks
  Zeigefinger im Gespräch; gespeichert wird die Utterance-ID, und nur die
  überlebt ein Re-Smoothing. Mehrere Zeilen ergeben eine Menge: eine Szene,
  ein Gespräch, eine Passage.
  """

  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam
  alias Worker.Jack.Zeit.{Abschluss, Anker, Kettenwerkzeuge, Lesen, Notizen, Stand}

  # `hilfe` steht hier NICHT: `Gemeinsam.aus/3` stellt es jedem Lauf von
  # selbst voran (Maintainer, 18.09.2026 — die Beschreibungen tragen die
  # Regeln und stehen nur einmal im Gespräch; nach einer Kompaktierung ist
  # der Wortlaut weg).
  @lesend ~w(lies_sprechlinie lies_kette offen zahlen)
  # Nur der Gedächtnis-Lauf notiert: Er SETZT nichts, und sein Ergebnis ist
  # genau diese Notiz — ohne sie wäre er wirkungslos (Befund des zweiten
  # echten Laufs, 19.09.2026). Die beiden anderen Läufe legen ihr Ergebnis in
  # Ankern ab.
  #
  # **Alle drei Läufe lesen die ÄUSSERUNGEN** (Maintainer, 19.09.2026: „wir
  # stellen den jacklauf ganz auf die utts um — also auch datensammeln aus
  # utts, werkzeug für fakten weg"). Der Gedächtnis-Lauf las bis dahin die
  # Fakten; die sind eine andere Schicht mit anderer Körnung (418 gegen 2168),
  # sie kommen aus allen Sitzungen der Kampagne, und ihre Reihenfolge ist
  # nicht die des Gesprächs — das Modell rätselte darüber mehrfach. Jetzt ist
  # es Jacks eigenes Muster: Phase 1 und Phase 2 lesen denselben Mitschnitt,
  # die eine versteht ihn, die andere ordnet ein.
  @notierend ~w(notiz notizen_lesen)
  # **Die Kette zuerst, die Anker danach** — in dieser Reihenfolge sieht sie
  # das Modell, und in dieser Reihenfolge ist die Arbeit gedacht: erst
  # einreihen, dann datieren.
  @kette ~w(haenge_an_kette unterhaenge_kettenglied erweitere_kettenglied
            versetze_kettenglied loesche_kettenglied nicht_in_die_kette)
  @setzend ~w(setz_zeitpunkt setz_spanne setz_frist anker_dazu anker_ersetzen
              nimm_anker_zurueck melde_konflikt kettenplatz_unklar)

  @doc """
  Die Namen der Werkzeuge eines Laufs, in der Reihenfolge der Liste.

  Der **Gedächtnis-Lauf setzt nichts** — er versteht den Ablauf, gegen den
  die beiden anderen lesen. Seine Notizen bekommt er mit dem Lauf selbst
  (noch nicht gebaut).
  """
  @spec namen(Stand.t()) :: [String.t()]
  def namen(%Stand{lauf: :gedaechtnis}), do: @lesend ++ @notierend ++ ["fertig"]

  def namen(%Stand{lauf: lauf}) when lauf in [:einsortieren, :pruefen],
    do: @lesend ++ @kette ++ @setzend ++ ["fertig"]

  def namen(%Stand{lauf: lauf}) do
    raise ArgumentError,
          "Worker.Jack.Zeit.Werkzeuge kennt die Laufart #{inspect(lauf)} nicht. " <>
            "Wer einen Lauf ergänzt, ergänzt seine Werkzeugliste — ein Rückfall " <>
            "auf eine fremde gäbe dem Modell Werkzeuge, die sein Auftrag nicht " <>
            "nennt (die Auffangzweig-Klasse aus #1211)."
  end

  @doc "Die Werkzeuge für den Stand im Halter; jedes ruft den Halter."
  @spec fuer(pid()) :: [Worker.Agent.Werkzeug.t()]
  def fuer(halter) do
    s = Halter.stand(halter)
    Gemeinsam.aus(definitionen(s), namen(s), halter)
  end

  @doc false
  def definitionen(%Stand{} = s) do
    Lesen.werkzeuge(s) ++
      Notizen.werkzeuge() ++
      Kettenwerkzeuge.werkzeuge() ++
      Anker.werkzeuge() ++ abschluss_werkzeuge(s.lauf)
  end

  # ─── Abschluss ──────────────────────────────────────────────────────

  # **Der Gedächtnis-Lauf hat einen anderen Abschluss, und das muss in der
  # Beschreibung stehen** (Befund des zweiten echten Laufs): Die gemeinsame
  # Fassung sprach von Zeilen, die zugeordnet sein müssen. Das Modell hielt
  # inne — „fertig() requires that every row of the transcript has been
  # assigned… but this run is about facts, not about the transcript" — kam
  # zur richtigen Antwort und verlor eine Runde. Dieselbe Klasse wie die
  # geteilten Werkzeugbeschreibungen beim Chronik-Jack (#1211).
  defp abschluss_werkzeuge(:gedaechtnis) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Schliesst den Lauf ab. Geht, wenn du JEDE Zeile gelesen hast — nicht, " <>
            "wenn du jede notiert hast: Notiert wird, was der nächste Lauf " <>
            "braucht, und das ist viel weniger. Was noch fehlt, sagt dir diese " <>
            "Antwort mit Zahlen, und offen() sagt es dir vorher.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :frei,
        ausfuehren: &w_fertig/2
      }
    ]
  end

  # **Der Prüf-Lauf hat eine andere Schranke, und sie muss in der
  # Beschreibung stehen.** Leseabdeckung und Einordnung erbt er vom
  # Einsortier-Lauf; was er leisten muss, ist der Blick auf jeden Befund.
  # Stünde hier die Einsortier-Fassung, schickte sie ihn durch 2168 Zeilen,
  # die er längst gelesen hat — genau der Auffangzweig, der beim
  # Chronik-Jack einen ganzen Lauf gekostet hat (#1211).
  defp abschluss_werkzeuge(:pruefen) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Schliesst den Prüf-Lauf ab. Du musst NICHT noch einmal lesen und " <>
            "nicht noch einmal einordnen — beides steht schon. Was dieser Lauf " <>
            "verlangt: Jeden BEFUND der Rechnung einmal angesehen zu haben. " <>
            "Angesehen heisst, die Stelle angefasst zu haben — mit lies_kette(), " <>
            "lies_sprechlinie() oder einem setzenden Werkzeug; bestätigen musst du " <>
            "nichts. Dazu darf kein Tischgespräch mehr auf der Linie liegen und " <>
            "keine Verschiebung ins Leere zeigen. Was noch fehlt, sagt dir diese " <>
            "Antwort mit Zahlen, und offen() sagt es dir vorher.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :frei,
        ausfuehren: &w_fertig/2
      }
    ]
  end

  defp abschluss_werkzeuge(:einsortieren) do
    [
      %{
        name: "fertig",
        beschreibung:
          "Schliesst den Lauf ab. Dafür muss JEDE Zeile zweierlei haben: eine " <>
            "EINORDNUNG (ingame / loesen / zweifel — gespielt, Tisch oder unklar) " <>
            "und einen Platz in der Reihe. Und alles, was du als Tischgespräch " <>
            "eingeordnet hast, muss mit loesche_kettenplatz() aus der Kette heraus sein: Was " <>
            "auf der Linie liegt, bekommt eine Spielzeit, auch wenn es keine " <>
            "hat. Zum Platz in der Reihe: Sie " <>
            "steht in der Reihe — das tut sie durch die Erzählreihenfolge, solange " <>
            "du sie nicht anfasst — oder sie ist gelöst. Dazu musst du jede Zeile " <>
            "GELESEN haben: „nicht angefasst“ heisst „die Erzählreihenfolge stimmt " <>
            "hier“, und das ist eine Aussage über die Welt, die du nur treffen " <>
            "kannst, wenn du die Zeile gesehen hast. Was fehlt, sagt dir diese " <>
            "Antwort mit Zahlen.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :frei,
        ausfuehren: &w_fertig/2
      }
    ]
  end

  defp abschluss_werkzeuge(lauf) do
    raise ArgumentError,
          "Worker.Jack.Zeit.Werkzeuge hat für die Laufart #{inspect(lauf)} keinen " <>
            "Abschluss. Jeder Lauf sagt selbst, was fertig() von ihm verlangt."
  end

  # **`:halt` beendet den Lauf, `:error` lehnt ab** — und beides ist tragend.
  # Der erste Wurf lieferte hier wie überall einen blanken String: Der Lauf
  # hätte auch bei sonst fehlerfreier Arbeit NIE geendet, weil
  # `Worker.Jack.Resuemee.Lauf` auf `%{ende: :halt}` prüft. Er wäre in den
  # Rundendeckel gelaufen, nach Stunden, mit vollständiger Arbeit und ohne
  # Ergebnis.
  defp w_fertig(s, _f) do
    case Abschluss.hindernisse(s) do
      [] ->
        {s, {:halt, "Abgeschlossen. " <> Anker.reststand(s)}}

      hindernisse ->
        {s, {:error, "Noch nicht fertig:\n" <> Enum.map_join(hindernisse, "\n", &("- " <> &1))}}
    end
  end
end
