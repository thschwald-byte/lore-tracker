defmodule Worker.Jack.Zeit.Lesen do
  @moduledoc """
  #1247 (Z2): die lesenden Werkzeuge des Zeit-Jack.

  **`linie()` zeigt das ERGEBNIS, nicht die Eingaben** — und das ist der
  Gegensatz zur Extraktion, wo Jack den Bestand bewusst nicht sieht
  (`Worker.Jack.Tor`). Hier muss er ihn sehen: Ein einzelner Anker kann für
  sich richtig sein und die Reihe trotzdem falsch, und das ist nur am
  gerechneten Ergebnis zu erkennen (Maintainer, 19.09.2026: „im unterschied
  zur extraction das timejack die ergebnisse anschauen").

  **`mitschnitt()` zählt mit, was es ausgibt.** Die Buchführung ist Teil des
  Lesens, nicht ein zweiter Schritt, den jemand vergessen kann — `fertig()`
  hängt daran.
  """

  alias Worker.Jack.Zeit.{Abschluss, Mitschnitt, Stand}
  alias Worker.Timeline.{Calendar, Linie}

  @minuten_pro_tag 1440

  @fenster 80

  @doc false
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "mitschnitt",
        beschreibung:
          "Zeigt den Mitschnitt ab einer Zeile. Eine Zeile ist eine ÄUSSERUNG — " <>
            "mehrere gehören oft zu einem Block, dann steht der geglättete Text " <>
            "einmal darüber. Zeilen mit [ooc] hat die Glättung aussortiert; sie " <>
            "zählen trotzdem und wollen zugeordnet werden. Lies in Portionen und " <>
            "arbeite dich durch: Was du nicht gelesen hast, kannst du nicht " <>
            "einordnen, und fertig() lässt dich damit nicht durch.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "ab" => %{"type" => "integer"},
            "anzahl" => %{"type" => "integer"}
          },
          "required" => ["ab"]
        },
        optional: ["anzahl"],
        wiederholung: :zaehlt,
        ausfuehren: &w_mitschnitt/2
      },
      %{
        name: "linie",
        beschreibung:
          "Zeigt die LINIE, wie sie gerade gerechnet wird — nicht deine Eingaben: " <>
            "wo eine Zeile liegt, wo Spannen greifen, was gelöst wurde, und welche " <>
            "Widersprüche die Rechnung findet. Jede Zeit sagt, woher sie kommt: " <>
            "„belegt“ wurde gesagt und gilt — wie grob der Ausdruck auch war " <>
            "(„auf 3 Jahre genau“ heisst nicht unsicher, sondern ungenau). " <>
            "„gerechnet (70%)“ ist zwischen zwei Belegen geraten; die Zahl sagt, " <>
            "wie eng die beiden beieinander liegen. „fortgeschrieben“ hat keinen " <>
            "Beleg nach oben und ist nur ein Anhalt — kein Grund, an den Ankern " <>
            "zu zweifeln. Und welche " <>
            "Widersprüche die Rechnung findet. Nutz das, um dein Ergebnis zu " <>
            "prüfen: Ein einzelner Anker kann für sich richtig sein und die Reihe " <>
            "trotzdem falsch.",
        parameter: %{
          "type" => "object",
          "properties" => %{"ab" => %{"type" => "integer"}, "anzahl" => %{"type" => "integer"}},
          "required" => []
        },
        optional: ["ab", "anzahl"],
        wiederholung: :bis_aenderung,
        ausfuehren: &w_linie/2
      },
      %{
        name: "offen",
        beschreibung:
          "Nennt, was fertig() noch im Weg steht: ungelesene Zeilen, Zeilen ohne " <>
            "Einordnung, Tischgespräch das noch auf der Linie liegt, " <>
            "Verschiebungen ohne auflösbares Ziel — jeweils als Bereiche " <>
            "(„1–60, 501–899“). Frag das, statt zu raten — es ist billiger als " <>
            "ein abgelehntes fertig().",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_offen/2
      },
      %{
        name: "zahlen",
        beschreibung:
          "Der Stand dieses Laufs in Zahlen: gelesene und eingeordnete Zeilen, " <>
            "Anker nach Art, Gelöstes, Konflikte. Die Zählung ist meine, nicht " <>
            "deine — nimm sie, " <>
            "statt selbst nachzuzählen.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_zahlen/2
      }
    ]
  end

  defp w_mitschnitt(%Stand{} = s, f) do
    ab = max(f["ab"] || 1, 1)
    anzahl = min(f["anzahl"] || @fenster, @fenster)

    zeilen = s.mitschnitt |> Enum.drop(ab - 1) |> Enum.take(anzahl)

    case zeilen do
      [] ->
        {s, {:ok, "Ab Zeile #{ab} gibt es nichts mehr — der Mitschnitt hat #{length(s.mitschnitt)} Zeilen."}}

      _ ->
        s = Stand.gelesen(s, zeilen)
        letzte = List.last(zeilen).nr
        z = Stand.zahlen(s)

        {s,
         {:ok,
          Mitschnitt.als_text(zeilen) <>
            "\n\n(Zeile #{ab}–#{letzte} von #{z.utterances}; gelesen #{z.gelesen}, " <>
              "offen #{z.offen}.)"}}
    end
  end

  defp w_linie(%Stand{} = s, f) do
    linie = Linie.bauen(stellen(s), Map.values(s.anker))

    ab = max(f["ab"] || 1, 1)
    anzahl = min(f["anzahl"] || 40, 40)
    ausschnitt = linie.reihe |> Enum.drop(ab - 1) |> Enum.take(anzahl)

    {s, {:ok, linien_text(s, linie, ausschnitt, ab)}}
  end

  defp w_offen(%Stand{} = s, _f) do
    case Abschluss.hindernisse(s) do
      [] -> {s, {:ok, "Nichts steht im Weg — fertig() geht."}}
      h -> {s, {:ok, Enum.map_join(h, "\n", &("- " <> &1))}}
    end
  end

  defp w_zahlen(%Stand{} = s, _f) do
    z = Stand.zahlen(s)

    {s,
     {:ok,
      "Lauf: #{z.lauf}\nZeilen: #{z.utterances}, gelesen #{z.gelesen}, " <>
        "eingeordnet #{z.eingeordnet}, ohne Einordnung #{z.ohne_einordnung}\n" <>
        "Anker: #{z.anker} (Zeitpunkte #{z.zeitpunkte}, Spannen #{z.spannen}, " <>
        "Verschiebungen #{z.verschiebungen})\nGelöst: #{z.geloest}, Konflikte: #{z.konflikte}"}}
  end

  # Die Grundordnung dieses Laufs: der Mitschnitt in seiner Reihenfolge. Die
  # Sitzungsnummer ist hier überall dieselbe — die Linie über die ganze
  # Kampagne baut `Worker.Repo.Zeit`, nicht der Lauf.
  defp stellen(%Stand{mitschnitt: m}) do
    Enum.map(m, &%{utterance_id: &1.utterance_id, session_nr: 1, pos: &1.nr})
  end

  defp linien_text(s, linie, ausschnitt, ab) do
    nach_id = Map.new(s.mitschnitt, &{&1.utterance_id, &1})

    zeilen =
      Enum.map_join(ausschnitt, "\n", fn e ->
        z = nach_id[e.utterance_id]
        nr = (z && z.nr) || "?"
        text = ((z && z.text) || "") |> String.slice(0, 60)
        "#{nr}  #{zeit(e, s.kalender)}  #{text}"
      end)

    befunde =
      case linie.befunde do
        [] -> ""
        b -> "\n\nBefunde:\n" <> Enum.map_join(b, "\n", &("- " <> &1.text))
      end

    geloest =
      if MapSet.size(linie.geloest) > 0,
        do: "\n(#{MapSet.size(linie.geloest)} Zeilen sind aus der Kette gelöst.)",
        else: ""

    "Die Linie ab Zeile #{ab} (#{length(linie.reihe)} auf der Linie):\n" <>
      zeilen <> geloest <> befunde
  end

  # **Drei Grade von Gewissheit, und sie stehen an der Zeile.** „belegt" ist
  # gesagt worden, „gerechnet" liegt zwischen zwei Belegen und ist nach oben
  # begrenzt, „fortgeschrieben" hat keinen oberen Beleg und wächst mit dem
  # Abstand ins Beliebige. Der dritte Fall sah bis #1247 aus wie der zweite —
  # das Modell hielt die Zahl für eine Messung und begann, die Anker
  # zurückzunehmen, die sie erzeugt hatten.
  defp zeit(%{minute: nil}, _cal), do: "—        "

  defp zeit(%{minute: m, herkunft: :belegt} = e, cal),
    do: "#{uhr(m, cal)} belegt#{genauigkeit(e.aufloesung)}"

  defp zeit(%{minute: m, herkunft: :fortgeschrieben}, cal), do: "#{uhr(m, cal)} fortgeschrieben"
  defp zeit(%{minute: m} = e, cal), do: "#{uhr(m, cal)} gerechnet (#{e.gewissheit}%)"

  # Wie fein der Ausdruck war — nur bei belegten Zeiten, und nur wenn es
  # gröber als eine Stunde ist: „22:45 belegt" braucht keinen Zusatz,
  # „Ende 2011 belegt" schon.
  defp genauigkeit(nil), do: ""
  defp genauigkeit(u) when u <= 60, do: ""
  defp genauigkeit(u) when u < @minuten_pro_tag, do: " (auf #{div(u, 60)} h genau)"
  defp genauigkeit(u) when u < 60 * @minuten_pro_tag, do: " (auf #{div(u, @minuten_pro_tag)} Tage genau)"
  defp genauigkeit(u), do: " (auf #{Float.round(u / (365 * @minuten_pro_tag), 1)} Jahre genau)"

  # **Ein Tageszähler ist für niemanden lesbar** — das ist die #1092-Lehre, und
  # der erste Wurf hat sie hier wiederholt: Für das Jahr 2000 stand in der
  # Linie `T+730000 00:00`. Das Modell konnte die Zahl nicht deuten, riet
  # („the timestamps seem to be in seconds, so T+730000 would be roughly 202
  # hours") und schloss daraus, die Anker seien falsch gemessen. Eine falsch
  # verstandene Zahl ist schlechter als keine Angabe.
  #
  # Gezeigt wird deshalb das DATUM, sobald der Zähler über den ersten Tag
  # hinausgeht, und die Uhrzeit nur dort, wo sie etwas aussagt. Ohne Kalender
  # bleibt es beim relativen `T+n` — dann ist die Linie ohnehin relativ, und
  # ein erfundenes Datum wäre schlimmer.
  defp uhr(m, cal) do
    tag = Integer.floor_div(m, @minuten_pro_tag)
    rest = Integer.mod(m, @minuten_pro_tag)
    h = rest |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    min = rest |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    cond do
      tag == 0 -> "#{h}:#{min}"
      is_nil(cal) -> "T+#{tag} #{h}:#{min}"
      true -> "#{Calendar.format(cal, tag, :day)} #{h}:#{min}"
    end
  end
end
