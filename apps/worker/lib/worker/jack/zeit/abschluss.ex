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

  # Höchstens so viele BEREICHE — nicht Zeilen. Wer 1700 von 2168 Zeilen
  # offen hat, dem sagen zwölf Einzelnummern nichts; er braucht die Lücken.
  @deckel 12

  @doc """
  Die Hindernisse, die einem Abschluss entgegenstehen — leer heißt: darf
  abschließen. Jeder Eintrag ist ein Satz für das Modell, mit Zahl.
  """
  @spec hindernisse(Stand.t()) :: [String.t()]
  def hindernisse(%Stand{lauf: :gedaechtnis} = s), do: ungelesen(s)

  # **Der Prüf-Lauf hat eine andere Schranke** (#1247): Leseabdeckung und
  # Einordnung erbt er vom Einsortier-Lauf, sie noch einmal zu verlangen
  # hiesse, 2168 Zeilen doppelt zu lesen. Was er leisten muss, ist der Blick
  # auf jeden Befund — und dass das Ergebnis trägt (kein Tischgespräch auf
  # der Linie, keine Verschiebung ins Leere).
  def hindernisse(%Stand{lauf: :pruefen} = s),
    do: ungesehene_befunde(s) ++ tisch_auf_der_linie(s) ++ ohne_ziel(s)

  def hindernisse(%Stand{} = s),
    do: ungelesen(s) ++ nicht_eingeordnet(s) ++ tisch_auf_der_linie(s) ++ ohne_ziel(s)

  @doc """
  Die Befunde, die Jack noch nicht angesehen hat — leer heisst: alle
  gesehen. Öffentlich, weil `offen()` sie ebenfalls nennt.
  """
  @spec ungesehene_befunde(Stand.t()) :: [String.t()]
  def ungesehene_befunde(%Stand{} = s) do
    offen =
      s
      |> befunde()
      |> Enum.reject(&MapSet.member?(s.gesehen, &1.anker_id))

    case offen do
      [] ->
        []

      liste ->
        [
          "#{length(liste)} Befund(e) hast du noch nicht angesehen. Das ist die " <>
            "Arbeit dieses Laufs: Jeder ist eine Stelle, an der die Rechnung " <>
            "stolpert — sieh sie dir an und entscheide, ob sie stimmt. " <>
            "Offen:\n" <>
            Enum.map_join(Enum.take(liste, @deckel), "\n", &("  - " <> String.slice(&1.text, 0, 120)))
        ]
    end
  end

  @doc "Die Befunde der gerechneten Linie."
  @spec befunde(Stand.t()) :: [map()]
  def befunde(%Stand{} = s) do
    stellen =
      Enum.map(s.mitschnitt, &%{utterance_id: &1.utterance_id, session_nr: 1, pos: &1.nr})

    Worker.Timeline.Linie.bauen(stellen, Map.values(s.anker)).befunde
  end

  # **Jede Zeile braucht eine Einordnung** (Maintainer, 19.09.2026): Was auf
  # der Linie liegt, soll Spielwelt sein. Eine nicht eingeordnete Zeile wird
  # trotzdem interpoliert und bekommt eine Spielzeit, die es nicht gibt — und
  # sie sieht hinterher aus wie jede andere. „Gelesen" allein reicht dafür
  # nicht: Es ist die Aussage „ich habe hingesehen", nicht „ich habe
  # entschieden".
  defp nicht_eingeordnet(%Stand{} = s) do
    case Stand.ohne_einordnung(s) do
      %{anzahl: 0} ->
        []

      %{anzahl: n, zeilen: zeilen} ->
        [
          "#{n} von #{length(s.mitschnitt)} Zeilen sind noch nicht eingeordnet. Jede " <>
            "braucht eine Antwort auf die Frage, ob hier gespielt oder am Tisch " <>
            "geredet wird: ingame() für die Welt, loesen() für Tischgespräch, " <>
            "zweifel() wenn du es nicht entscheiden kannst. Ohne Einordnung: " <>
            "#{bereiche(zeilen)}."
        ]
    end
  end

  # **Tischgespräch gehört aus der Kette heraus, nicht bloss etikettiert.**
  # Praktisch tritt der Fall nur ein, wenn jemand `loesen` rückgängig macht
  # oder eine Zeile doppelt einordnet — die Regel steht trotzdem hier, weil
  # sie die Zusage der Linie ist und nicht die Disziplin eines Werkzeugs.
  defp tisch_auf_der_linie(%Stand{} = s) do
    case Stand.tisch_in_der_kette(s) do
      [] ->
        []

      zeilen ->
        [
          "#{length(zeilen)} Zeile(n) sind als Tischgespräch eingeordnet, liegen aber " <>
            "noch auf der Linie — sie werden interpoliert und bekommen eine Spielzeit, " <>
            "die es nicht gibt. Mit loesen() heraus: #{bereiche(zeilen)}."
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
            "sie gesehen hast. Ungelesen: #{bereiche(fehlend)}."
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

  @doc """
  Die ungelesenen Zeilen als **Bereiche**, nicht als Einzelnummern.

  Eine Liste der „nächsten zwölf" ist bei tausend offenen Zeilen keine
  Auskunft: Sie sagt nicht, WO die Lücken sind, und sie legt nahe, es seien
  nur diese. `1–60, 500–2168` sagt in zwei Angaben, was zu tun ist — und
  deckt den häufigen Fall ab, dass Jack mitten im Mitschnitt weitergelesen
  hat und vorn eine Lücke blieb.
  """
  @spec bereiche([map()]) :: String.t()
  def bereiche(fehlend) do
    gruppen =
      fehlend
      |> Enum.map(& &1.nr)
      |> Enum.sort()
      |> Enum.chunk_while(
        nil,
        fn nr, nil -> {:cont, {nr, nr}}
           nr, {von, bis} when nr == bis + 1 -> {:cont, {von, nr}}
           nr, offen -> {:cont, offen, {nr, nr}}
        end,
        fn
          nil -> {:cont, nil}
          offen -> {:cont, offen, nil}
        end
      )
      |> Enum.reject(&is_nil/1)

    text =
      gruppen
      |> Enum.take(@deckel)
      |> Enum.map_join(", ", fn
        {n, n} -> "#{n}"
        {von, bis} -> "#{von}–#{bis}"
      end)

    if length(gruppen) > @deckel, do: text <> " … (#{length(gruppen)} Lücken)", else: text
  end

  defp feld(a, k) when is_map(a), do: Map.get(a, k) || Map.get(a, to_string(k))
end
