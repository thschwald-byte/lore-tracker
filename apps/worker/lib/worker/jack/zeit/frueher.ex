defmodule Worker.Jack.Zeit.Frueher do
  @moduledoc """
  #1247: **der Zeit-Jack liest die früheren Sitzungen** — Mitschnitt, Glieder
  und die Gedanken seiner eigenen früheren Läufe.

  ## Warum

  Maintainer, 25.09.2026: „er muss die Sachen, die vor vorherigen Sessions
  erarbeitet wurden, lesen/bearbeiten können."

  Seit die Kette kampagnenweit geladen wird, **sieht** er die Glieder früherer
  Sitzungen — aber nur deren Titel („die Anreise", „der Überfall"). Was dort
  wirklich geschah, stand nirgends: Sein Mitschnitt ist die eigene Sitzung,
  und `suche_bisher`, `fakten` und `vorige_gedanken` der anderen Jacks hat er
  nicht. Für den einfachen Fall reicht das (die eigene Sitzung ist die
  neueste, kommt hinten dran); für den Fall, um den es geht, nicht: Erzählt
  die Runde am Anfang einen **Rückblick** auf die letzte Sitzung, muss er
  erkennen, WELCHES alte Glied gemeint ist. Dafür braucht er dessen Inhalt.

  ## Die Nummern bleiben getrennt

  Das ist die Falle, und sie ist die wichtigste Entscheidung hier: Jacks
  Zeilennummer n ist Position n in **seiner** Liste — nur so zeigt sie auf die
  richtige Utterance (`Mitschnitt.aufloesen/2`). Eine fremde Zeile mit
  derselben Nummer würde einen Anker an die falsche Stelle setzen, und zwar
  lautlos.

  Deshalb tragen fremde Zeilen hier ein **Sitzungs-Präfix** (`S2/45`) und sind
  über die setzenden Werkzeuge nicht erreichbar: Sie nehmen nackte Nummern,
  also immer die eigene Sitzung. Er kann fremde Sitzungen lesen und daraus
  schliessen — aber nicht in ihnen ankern. Deren Zeilen hat der Lauf jener
  Sitzung entschieden.

  **Bearbeiten heisst hier: Glieder.** Ein fremdes GLIED darf er erweitern,
  versetzen und (als Ausnahme) löschen — das geht über die Glied-Kennung und
  ist seit der kampagnenweiten Kette möglich. Fremde ZEILEN einzuordnen wäre
  etwas anderes und ist bewusst nicht vorgesehen.

  ## Geladen wird beim Zugriff

  Wie beim Resümee-Jack (#1210): Die Eingabe reicht einen Lader durch, der die
  Kontextliste einer Sitzung erst baut, wenn jemand sie anfordert — ein
  vorgeladener Mitschnitt aller Sitzungen wären bei seattleV5 rund 12.000
  Zeilen im Stand, für einen Lauf, der die meisten nie ansieht.
  """

  alias Worker.Jack.Zeit.Stand

  @fenster 80

  @doc """
  Die Werkzeuge. Sie stehen in allen drei Läufen — auch im Gedächtnis-Lauf, der
  gerade dort den Ablauf verstehen soll.
  """
  @spec werkzeuge() :: [map()]
  def werkzeuge do
    [
      %{
        name: "sitzungen",
        beschreibung:
          "Zeigt die Sitzungen dieser Kampagne: Nummer, Zeilenzahl, wie viele " <>
            "Kettenglieder daraus schon stehen und ob ein früherer Lauf Notizen " <>
            "hinterlassen hat. Fang hier an, wenn du wissen willst, was es ausser " <>
            "deiner Sitzung gibt.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :bis_aenderung,
        ausfuehren: &w_sitzungen/2
      },
      %{
        name: "lies_frueher",
        beschreibung:
          "Zeigt den Mitschnitt einer FRÜHEREN Sitzung. Nimm das, wenn ein " <>
            "Kettenglied aus einer anderen Sitzung stammt und du wissen musst, was " <>
            "dort geschah — etwa, weil deine Runde am Anfang darauf zurückblickt. " <>
            "Die Zeilennummern tragen ein Präfix („S2/45“) und sind NICHT zum " <>
            "Ankern gedacht: Setzende Werkzeuge nehmen nackte Nummern, also immer " <>
            "deine eigene Sitzung. Die Zeilen jener Sitzung hat ihr eigener Lauf " <>
            "entschieden.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "sitzung" => %{
              "type" => "integer",
              "description" => "Die Nummer aus sitzungen() — nicht deine eigene."
            },
            "ab" => %{"type" => "integer", "description" => "Erste Zeile dort (ab 1)."},
            "anzahl" => %{
              "type" => "integer",
              "description" => "Wie viele Zeilen (Standard und Höchstwert #{@fenster})."
            }
          },
          "required" => ~w(sitzung ab)
        },
        optional: ["anzahl"],
        wiederholung: :zaehlt,
        ausfuehren: &w_frueher/2
      },
      %{
        name: "vorige_gedanken",
        beschreibung:
          "Zeigt die Notizen, die ein früherer Zeit-Lauf über eine andere Sitzung " <>
            "gemacht hat — wie er den Ablauf dort verstanden hat. Das ist deine " <>
            "eigene Vorarbeit aus einer anderen Sitzung, nicht die eines anderen " <>
            "Jack.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "sitzung" => %{
              "type" => "integer",
              "description" => "Die Nummer aus sitzungen(). Ohne Angabe: alle, die etwas haben."
            }
          },
          "required" => []
        },
        optional: ["sitzung"],
        wiederholung: :bis_aenderung,
        ausfuehren: &w_gedanken/2
      }
    ]
  end

  # ─── Ausführung ─────────────────────────────────────────────────────

  defp w_sitzungen(%Stand{} = s, _f) do
    case s.sitzungen do
      [] ->
        {s, {:ok, "Ich kenne nur deine Sitzung — es gibt keine früheren."}}

      liste ->
        zeilen =
          Enum.map_join(liste, "\n", fn i ->
            eigen = if i.eigene?, do: "  ← deine", else: ""
            notiz = if i.notizen?, do: ", Notizen vorhanden", else: ""

            "S#{i.nummer}: #{i.zeilen} Zeilen, #{i.glieder} Kettenglied(er)#{notiz}#{eigen}"
          end)

        {s, {:ok, "Sitzungen dieser Kampagne:\n#{zeilen}"}}
    end
  end

  defp w_frueher(%Stand{} = s, f) do
    nr = f["sitzung"]
    ab = max(f["ab"] || 1, 1)
    anzahl = min(f["anzahl"] || @fenster, @fenster)

    cond do
      nr == s.sitzung_nr ->
        {s,
         {:error,
          "S#{nr} ist deine eigene Sitzung — nimm lies_sprechlinie(ab: #{ab}), " <>
            "dann kannst du die Zeilen auch einordnen."}}

      true ->
        laden(s, nr, ab, anzahl)
    end
  end

  defp laden(%Stand{} = s, nr, ab, anzahl) do
    case Map.fetch(s.mitschnitte, nr) do
      {:ok, zeilen} -> {s, {:ok, ausschnitt(zeilen, nr, ab, anzahl)}}
      :error -> ueber_lader(s, nr, ab, anzahl)
    end
  end

  defp ueber_lader(%Stand{lader: nil} = s, _nr, _ab, _anzahl) do
    {s, {:error, "Ich kann fremde Sitzungen hier nicht laden (kein Lader gesetzt)."}}
  end

  defp ueber_lader(%Stand{} = s, nr, ab, anzahl) do
    case s.lader.(nr) do
      {:ok, zeilen} ->
        s = %{s | mitschnitte: Map.put(s.mitschnitte, nr, zeilen)}
        {s, {:ok, ausschnitt(zeilen, nr, ab, anzahl)}}

      {:error, :keine_sitzung} ->
        {s, {:error, "Eine Sitzung S#{nr} kenne ich nicht — sieh in sitzungen() nach."}}

      {:error, grund} ->
        {s, {:error, "Die Sitzung S#{nr} liess sich nicht laden (#{inspect(grund)})."}}
    end
  end

  # Das Präfix ist der Riegel: Diese Nummern führen in kein setzendes Werkzeug.
  defp ausschnitt(zeilen, nr, ab, anzahl) do
    teil = zeilen |> Enum.drop(ab - 1) |> Enum.take(anzahl)

    if teil == [] do
      "In S#{nr} gibt es ab Zeile #{ab} nichts mehr — sie hat #{length(zeilen)} Zeilen."
    else
      text =
        Enum.map_join(teil, "\n", fn z ->
          "S#{nr}/#{z.nr}  #{z.sprecher}: #{z.text}"
        end)

      "Mitschnitt von S#{nr}, Zeile #{ab} bis #{ab + length(teil) - 1} " <>
        "(von #{length(zeilen)}). Diese Nummern sind zum LESEN — ankern kannst " <>
        "du nur in deiner Sitzung.\n\n#{text}"
    end
  end

  defp w_gedanken(%Stand{} = s, f) do
    nr = f["sitzung"]

    passend =
      s.vorige_notizen
      |> Enum.filter(fn {n, _} -> is_nil(nr) or n == nr end)
      |> Enum.sort()

    case passend do
      [] when is_integer(nr) ->
        {s, {:ok, "Zu S#{nr} hat kein früherer Lauf Notizen hinterlassen."}}

      [] ->
        {s, {:ok, "Kein früherer Lauf hat Notizen hinterlassen."}}

      liste ->
        text =
          Enum.map_join(liste, "\n\n", fn {n, notizen} ->
            "— S#{n} —\n" <> notiztext(notizen)
          end)

        {s, {:ok, text}}
    end
  end

  defp notiztext(notizen) when is_map(notizen) do
    notizen
    |> Enum.sort()
    |> Enum.map_join("\n", fn {schluessel, eintrag} ->
      "#{schluessel}: #{text_von(eintrag)}"
    end)
  end

  defp notiztext(_), do: "(unlesbar)"

  defp text_von(%{"text" => t}), do: t
  defp text_von(%{text: t}), do: t
  defp text_von(t) when is_binary(t), do: t
  defp text_von(x), do: inspect(x)
end
