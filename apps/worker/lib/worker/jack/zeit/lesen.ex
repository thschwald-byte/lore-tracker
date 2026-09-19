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
  alias Worker.Timeline.Linie

  @fenster 80

  @doc false
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "fakten",
        beschreibung:
          "Zeigt die FAKTEN der Kampagne ab einem Eintrag — das sind die geprüften " <>
            "Aussagen, die ein anderer Lauf aus dem Mitschnitt gezogen hat. Jeder " <>
            "nennt seine Sitzung und die Blöcke, auf die er sich stützt. Nicht " <>
            "jeder ist ein Ereignis der Spielwelt: Manche halten fest, was am " <>
            "Tisch besprochen wurde.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "ab" => %{"type" => "integer"},
            "anzahl" => %{"type" => "integer"}
          },
          "required" => []
        },
        optional: ~w(ab anzahl),
        wiederholung: :zaehlt,
        ausfuehren: &w_fakten/2
      },
      %{
        name: "fakt",
        beschreibung:
          "Ein einzelner Fakt mit allem, was er trägt: Aussage, Art, Figur, " <>
            "Sitzung und die Blöcke, auf die er sich stützt. nummer ist die " <>
            "laufende Nummer aus fakten(). Nimm das, wenn dir in der Liste etwas " <>
            "unklar ist.",
        parameter: %{
          "type" => "object",
          "properties" => %{"nummer" => %{"type" => "integer"}},
          "required" => ["nummer"]
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_fakt/2
      },
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
            "wo eine Zeile liegt, was belegt und was zwischen zwei Ankern " <>
            "interpoliert ist, wo Spannen greifen, was gelöst wurde, und welche " <>
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
          "Nennt, was fertig() noch im Weg steht: ungelesene Zeilen mit ihren " <>
            "Nummern, Verschiebungen ohne auflösbares Ziel. Frag das, statt zu " <>
            "raten — es ist billiger als ein abgelehntes fertig().",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_offen/2
      },
      %{
        name: "zahlen",
        beschreibung:
          "Der Stand dieses Laufs in Zahlen: gelesene Zeilen, Anker nach Art, " <>
            "Gelöstes, Konflikte. Die Zählung ist meine, nicht deine — nimm sie, " <>
            "statt selbst nachzuzählen.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_zahlen/2
      }
    ]
  end

  @fakten_fenster 40

  defp w_fakten(%Stand{} = s, f) do
    ab = max(f["ab"] || 1, 1)
    anzahl = min(f["anzahl"] || @fakten_fenster, @fakten_fenster)
    gewaehlt = s.fakten |> Enum.drop(ab - 1) |> Enum.take(anzahl)

    case gewaehlt do
      [] ->
        {s, {:ok, "Ab Fakt #{ab} gibt es nichts mehr — es sind #{length(s.fakten)}."}}

      _ ->
        s = Stand.fakten_gelesen(s, gewaehlt)
        z = Stand.zahlen(s)
        sitzungen = Stand.sitzungsnummern(s)

        {s,
         {:ok,
          Enum.map_join(Enum.with_index(gewaehlt, ab), "\n", &fakt_zeile(&1, sitzungen)) <>
            "\n\n(Fakt #{ab}–#{ab + length(gewaehlt) - 1} von #{z.fakten}; gelesen " <>
              "#{z.fakten_gelesen}, offen #{z.fakten_offen}.)"}}
    end
  end

  defp w_fakt(%Stand{} = s, f) do
    nr = f["nummer"]

    case nr && nr >= 1 && Enum.at(s.fakten, nr - 1) do
      nil ->
        {s, {:error, "Einen Fakt #{inspect(nr)} gibt es nicht — es sind #{length(s.fakten)}."}}

      false ->
        {s, {:error, "Einen Fakt #{inspect(nr)} gibt es nicht — es sind #{length(s.fakten)}."}}

      fakt ->
        {Stand.fakten_gelesen(s, [fakt]), {:ok, fakt_voll(fakt)}}
    end
  end

  # **Die Sitzung gehört in die Zeile** (Befund des zweiten echten Laufs):
  # Die Fakten sind kampagnenweit, und ohne die Nummer sieht das Modell 418
  # Einträge aus vier Sitzungen als eine flache Liste. Es rätselte mehrfach —
  # „facts 205 through 239 seem to repeat earlier content, suggesting they
  # might be from a different session or out of sequence" — und baute sich
  # daraus ein falsches Bild vom Ablauf. Raten statt nachsehen ist immer ein
  # fehlendes Feld.
  defp fakt_zeile({fakt, nr}, sitzungen) do
    s = Map.get(sitzungen, feld(fakt, :session_id))
    "#{nr}  [S#{s || "?"}] #{feld(fakt, :claim)}"
  end

  defp fakt_voll(fakt) do
    Enum.map_join(
      [:fakt_id, :claim, :fact_type, :character_alias, :session_id, :source_refs],
      "\n",
      fn k -> "#{k}: #{inspect(feld(fakt, k), limit: 8)}" end
    )
  end

  defp feld(f, k), do: Map.get(f, k) || Map.get(f, to_string(k))

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
      "Lauf: #{z.lauf}\n" <>
        "Fakten: #{z.fakten}, gelesen #{z.fakten_gelesen}, offen #{z.fakten_offen}\n" <>
        "Zeilen: #{z.utterances}, gelesen #{z.gelesen}, offen #{z.offen}\n" <>
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
        "#{nr}  #{zeit(e)}  #{text}"
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

  defp zeit(%{minute: nil}), do: "—        "
  defp zeit(%{minute: m, herkunft: :belegt}), do: "#{uhr(m)} belegt"
  defp zeit(%{minute: m}), do: "#{uhr(m)} gerechnet"

  defp uhr(m) do
    tag = Integer.floor_div(m, 1440)
    rest = rem(m, 1440)
    h = rest |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    min = rest |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    if tag > 0, do: "T+#{tag} #{h}:#{min}", else: "#{h}:#{min}"
  end
end
