defmodule Worker.Timeline.Befunde do
  @moduledoc """
  #1247: die Widersprüche der Linie — **gemeldet, nicht korrigiert**.

  Ein Befund ist eine Meldung für die Kurationsliste (#1243) und für Jacks
  Prüf-Lauf; er ändert an der Rechnung nichts. Genau das ist der Grund für
  das eigene Modul: `Worker.Timeline.Linie` rechnet, hier wird nur gelesen
  und beurteilt.

  **Gerechnet wird nichts doppelt.** `aus/1` bekommt die festen Punkte und
  die Spannen, die die Linie ohnehin gebildet hat, statt sie erneut zu
  bilden — vor diesem Schnitt lief `feste_punkte/2` je Aufruf von
  `Linie.bauen/2` **dreimal** (einmal fürs Verteilen, je einmal für zwei
  Befundarten). Die Kopplung sichtbar zu machen war das Ziel; dass sie dabei
  billiger wird, ist die Dreingabe.
  """

  alias Worker.Timeline.Linie

  @minuten_pro_tag 1440

  @doc """
  Alle Befunde einer gebauten Linie.

  `teile` trägt, was die Linie schon gerechnet hat: `reihe` (die Kette),
  `anker`, `feste` (die festen Punkte) und `spannen`.
  """
  @spec aus(map()) :: [map()]
  def aus(%{reihe: reihe, anker: anker, feste: feste, spannen: spannen}) do
    (ohne_ziel(anker, reihe) ++
       spannen_ueberlauf(feste, spannen) ++
       uneinige_zeitpunkte(reihe, anker) ++
       grosse_spruenge(feste) ++
       zweifel(anker))
    |> Enum.map(&Map.put(&1, :id, kennung(&1)))
    |> Enum.map(&mit_stellen(&1, anker))
  end

  @doc """
  Hängt an einen Befund die **Stellen**, auf die er sich bezieht: je Anker
  seine `utterance_ids` und den gesetzten Ausdruck.

  #1247, am laufenden Lauf gefunden (25.09.2026): Die Adresse war da und wurde
  weggeworfen. Jack bekam sechs Befunde als reinen Text, konnte keinen einem
  Anker zuordnen und hat dreissig Mal denselben Absatz geschrieben, um sie aus
  den Zahlen zurückzurechnen („*The Befunde list doesn't indicate positions*")
  — bis die neue Schleifen-Erkennung greifen würde. Ein Befund ohne Stelle ist
  keine Meldung, sondern ein Rätsel.

  `anker_id` allein trägt nicht: Für das Modell ist sie ein Hash. Seine
  Adresse ist die **Zeilennummer**, und die entsteht erst beim Leser
  (`Worker.Jack.Zeit.Lesen`), der den Mitschnitt hat — hier reisen deshalb die
  `utterance_ids`, die stabile Form.

  Der Spannen-Überlauf betrifft zwei Anker (`anker_ids`) und hat selbst
  keinen; er bekommt beide Stellen.
  """
  @spec mit_stellen(map(), [map()]) :: map()
  def mit_stellen(befund, anker) do
    ids =
      case befund do
        %{anker_ids: [_ | _] = liste} -> liste
        %{anker_id: id} when is_binary(id) and id != "" -> String.split(id, ", ")
        _ -> []
      end

    stellen =
      for id <- ids,
          a = Enum.find(anker, &(Map.get(&1, :anker_id) == id)),
          do: %{
            anker_id: id,
            utterance_ids: Map.get(a, :utterance_ids) || [],
            wert: Map.get(a, :wert)
          }

    Map.put(befund, :stellen, stellen)
  end

  @doc """
  Die Kennung eines Befundes — **jeder hat eine, auch der ohne Anker**.

  Ein Befund hängt nicht immer an einem Anker: Der Spannen-Überlauf gilt der
  Strecke *zwischen* zweien und trägt `anker_id: nil`. Wer solche Befunde
  über die Anker-ID abhakt, hakt sie nie ab — und eine Schranke, die sie
  verlangt (die des Prüf-Laufs, #1247), wäre unter keinen Umständen zu
  erfüllen. Genau diese Klasse hat beim Chronik-Jack 28 von 51 Runden
  gekostet (#1211).

  Deshalb entsteht die Kennung **hier**, an der einen Stelle, an der Befunde
  gebaut werden, und nicht bei jedem Leser neu.
  """
  @spec kennung(map()) :: String.t()
  def kennung(%{anker_id: id}) when is_binary(id) and id != "", do: id

  def kennung(befund) do
    roh = "#{Map.get(befund, :art)}|#{Map.get(befund, :text)}"
    "b_" <> (:crypto.hash(:sha, roh) |> Base.encode16(case: :lower) |> String.slice(0, 16))
  end

  # s. `sprung?/3` — jeder grosse Vorwärtssprung ist eine Annahme und steht
  # deshalb in der Liste, die ein Mensch durchsieht.
  defp grosse_spruenge(feste) do
    for {_i, %{sprung?: true} = p} <- feste do
      %{
        art: :zeitsprung_angenommen,
        anker_id: p.anker_id,
        text:
          "Diese Uhrzeit liegt vor der vorhergehenden; gerechnet wird mit einem " <>
            "Sprung nach vorn von mehr als sechs Stunden. Stimmt das nicht, ist es " <>
            "vermutlich ein Rückblick, der noch verschoben werden muss."
      }
    end
  end

  defp ohne_ziel(anker, reihe) do
    ids = MapSet.new(reihe, & &1.utterance_id)

    for a <- anker,
        Linie.art(a) == :ordnung,
        ziel = Map.get(a, :ziel),
        is_nil(ziel) or not MapSet.member?(ids, ziel) do
      %{
        art: :verschiebung_ohne_ziel,
        anker_id: Map.get(a, :anker_id),
        text: "Die Verschiebung nennt kein auflösbares Ziel — sie bleibt wirkungslos."
      }
    end
  end

  # Der Widerspruch, der im Plan Punkt 6 heisst: die genannten Dauern
  # zwischen zwei festen Punkten ergeben mehr Zeit, als zwischen ihnen liegt.
  # Gemeldet, nicht weggerechnet.
  defp spannen_ueberlauf(feste, spannen) do
    feste
    |> Enum.sort_by(fn {i, _} -> i end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{vi, %{minute: vm} = vp}, {ni, %{minute: nm} = np}] ->
      summe = Linie.gelaufen(vi, ni, spannen)
      abstand = nm - vm

      if summe > abstand do
        [
          %{
            art: :spannen_ueberlauf,
            anker_id: nil,
            # Der Befund gilt der STRECKE und hat keinen eigenen Anker — aber
            # er hat zwei Endpunkte, und ohne sie ist er unauflösbar (#1247).
            anker_ids: Enum.reject([vp[:anker_id], np[:anker_id]], &is_nil/1),
            text:
              "Zwischen zwei Ankern liegen #{dauer_wort(abstand)}, die genannten Dauern " <>
                "ergeben #{dauer_wort(summe)}. Entweder ist eine Dauer falsch gelesen " <>
                "oder ein Anker sitzt falsch."
          }
        ]
      else
        []
      end
    end)
  end

  # **Im Befund steht, was GESAGT wurde** — „Ende 2011" und „kurz nach acht",
  # nicht zwei Minutenzahlen. Jack hat die Ausdrücke gesetzt; er erkennt sie
  # wieder, eine Restminutenzahl nicht.
  defp gesagt_wort([_ | _] = werte, _minuten), do: Enum.map_join(werte, " und ", &"„#{&1}“")
  defp gesagt_wort(_, minuten), do: Enum.map_join(minuten, " und ", &dauer_wort/1)

  @doc """
  Eine Minutenzahl in Worten — „zwei Stunden" statt „120", „69 Jahre" statt
  „−1057331035".

  **Rohminuten sind in einem Befund keine Auskunft** (#1247, 20.09.2026). Am
  echten Lauf stand „Zwischen zwei Ankern liegen -1057331035 Minuten" — das
  ist die Differenz zwischen 2011 und Jahr 0, formal richtig und praktisch
  unlesbar. Ein Modell, das so etwas liest, sucht den Fehler in der Zahl
  statt in den zwei Ankern.
  """
  @spec dauer_wort(integer()) :: String.t()
  def dauer_wort(minuten) when is_integer(minuten) do
    vor = if minuten < 0, do: "minus ", else: ""
    m = abs(minuten)

    cond do
      m < 60 -> "#{vor}#{m} Minuten"
      m < @minuten_pro_tag -> "#{vor}#{runde(m, 60)} Stunden"
      m < 60 * 24 * 365 -> "#{vor}#{runde(m, @minuten_pro_tag)} Tage"
      true -> "#{vor}#{runde(m, @minuten_pro_tag * 365)} Jahre"
    end
  end

  defp runde(zahl, teiler) do
    wert = zahl / teiler
    if wert < 10, do: Float.round(wert, 1), else: round(wert)
  end

  defp zweifel(anker) do
    for a <- anker,
        z = Map.get(a, :zweifel),
        is_binary(z) and z != "" do
      %{art: :zweifel, anker_id: Map.get(a, :anker_id), text: z}
    end
  end

  defp uneinige_zeitpunkte(reihe, anker) do
    index = reihe |> Enum.with_index() |> Map.new(fn {s, i} -> {s.utterance_id, i} end)

    anker
    |> Enum.filter(&(Linie.art(&1) == :zeitpunkt and zahl_traegt?(&1)))
    |> Enum.group_by(&frueheste(&1, index))
    |> Enum.reject(fn {i, gruppe} -> is_nil(i) or length(gruppe) < 2 end)
    |> Enum.flat_map(fn {_i, gruppe} ->
      minuten =
        gruppe |> Enum.map(&(Map.get(&1, :minute) || Map.get(&1, :tagesminute))) |> Enum.uniq()

      werte = gruppe |> Enum.map(&to_string(Map.get(&1, :wert) || "")) |> Enum.reject(&(&1 == ""))

      if length(minuten) > 1 do
        wer = if Enum.any?(gruppe, &abgesegnet?/1), do: "der abgesegnete", else: "der frühere"

        [
          %{
            art: :zeitpunkte_uneinig,
            anker_id: gruppe |> Enum.map(&Map.get(&1, :anker_id)) |> Enum.join(", "),
            text:
              "An derselben Stelle stehen zwei verschiedene Zeitpunkte " <>
                "(#{gesagt_wort(werte, minuten)}). Gerechnet wird mit #{wer}."
          }
        ]
      else
        []
      end
    end)
  end

  # Ein Zeitpunkt trägt eine Zahl, wenn er ein Datum ODER eine Uhrzeit
  # hergegeben hat. Nur auf `:minute` zu prüfen liesse den häufigsten Fall am
  # Spieltisch aus dem Befund fallen: zwei widersprechende Uhrzeiten an einer
  # Stelle wären still.
  defp zahl_traegt?(a),
    do: is_integer(Map.get(a, :minute)) or is_integer(Map.get(a, :tagesminute))

  # Die früheste Stelle, an der ein Anker hängt — die eigene kleine Fassung
  # statt eines weiteren öffentlichen Zugangs zur Linie: Sie ist drei Zeilen
  # lang, und ein Export nur für einen Leser koppelte zwei Module über etwas,
  # das keine Zusage ist.
  defp frueheste(a, index) do
    a
    |> Map.get(:utterance_ids, [])
    |> Enum.map(&Map.get(index, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp abgesegnet?(a) do
    case Map.get(a, :abgesegnet_am) do
      s when is_binary(s) -> s != ""
      _ -> false
    end
  end
end
