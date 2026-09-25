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
    do: ungesehene_befunde(s)

  def hindernisse(%Stand{} = s),
    do: ungelesen(s) ++ unentschieden(s)

  @doc """
  Die Befunde, die Jack noch nicht angesehen hat — leer heisst: alle
  gesehen. Öffentlich, weil `offen()` sie ebenfalls nennt.
  """
  @spec ungesehene_befunde(Stand.t()) :: [String.t()]
  def ungesehene_befunde(%Stand{} = s) do
    offen =
      s
      |> befunde()
      |> Enum.reject(&MapSet.member?(s.gesehen, &1.id))

    case offen do
      [] ->
        []

      liste ->
        [
          "#{length(liste)} Befund(e) hast du noch nicht angesehen. Das ist die " <>
            "Arbeit dieses Laufs: Jeder ist eine Stelle, an der die Rechnung " <>
            "stolpert — sieh sie dir an und entscheide, ob sie stimmt. " <>
            "Offen:\n" <>
            Enum.map_join(
              Enum.take(liste, @deckel),
              "\n",
              &("  - " <> String.slice(&1.text, 0, 120))
            )
        ]
    end
  end

  @doc "Die Befunde der gerechneten Linie."
  @spec befunde(Stand.t()) :: [map()]
  def befunde(%Stand{} = s) do
    stellen =
      Enum.map(s.mitschnitt, &%{utterance_id: &1.utterance_id, session_nr: 1, pos: &1.nr})

    Worker.Timeline.Linie.aus_kette(s.kette, Map.values(s.anker), stellen).befunde
  end

  # **Die Kette beginnt leer, also ist „offen" eindeutig** (Maintainer,
  # 20.09.2026: „Default beim Start: Kette ist leer — jack soll bewusst
  # einsortieren").
  #
  # Vorher trug die Linie die Sprechreihenfolge als Default, und „nicht
  # angefasst" hiess zweierlei zugleich: „die Erzählreihenfolge stimmt
  # hier" und „ich bin noch nicht hingekommen". Die Schranke musste das über
  # ein zweites Feld nachbilden (`einordnung`) und prüfte danach zweimal
  # dasselbe — einmal auf die Einordnung, einmal darauf, ob Tischgespräch
  # noch auf der Linie liegt.
  #
  # Mit der leeren Kette fällt beides zusammen: Eine Zeile liegt in einem
  # Glied, ist ausdrücklich draussen, oder sie ist offen. Tischgespräch kann
  # gar nicht mehr „auf der Linie liegen" — `nicht_in_die_kette` nimmt es
  # heraus, das ist derselbe Aufruf.
  defp unentschieden(%Stand{} = s) do
    case Stand.offene_zeilen(s) do
      %{anzahl: 0} ->
        []

      %{anzahl: n, zeilen: zeilen} ->
        [
          "#{n} von #{length(s.mitschnitt)} Zeilen sind noch nicht entschieden. Jede " <>
            "gehört entweder in ein Kettenglied (haenge_an_kette — nimm grosse " <>
            "Abschnitte) oder ausdrücklich heraus (nicht_in_die_kette für " <>
            "Tischgespräch). Offen: #{bereiche(zeilen)}."
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

  # **`ohne_ziel` ist entfallen** (#1247, 20.09.2026). Es meldete
  # Verschiebungen, deren Ziel es nicht gibt — eine Nachprüfung, die es
  # brauchte, solange eine Verschiebung ein Anker war, der still wirkungslos
  # blieb. Seit die Kette die Operation ausführt, lehnt sie ein fehlendes
  # Ziel **beim Aufruf** ab und sagt warum; ein Befund hinterher wäre
  # dieselbe Auskunft, nur Runden später.

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
        fn
          nr, nil -> {:cont, {nr, nr}}
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
end
