defmodule Worker.Jack.Zeit.Notizen do
  @moduledoc """
  #1247: die Notiz-Werkzeuge des Zeit-Jack — **nur im Gedächtnis-Lauf**.

  Er setzt nichts; seine Notizen SIND sein Ergebnis, und was er nicht
  notiert, ist nach dem Lauf weg. Die beiden anderen Läufe legen ihres in
  Ankern ab und haben diese Werkzeuge nicht.

  Eigenes Modul, weil es eine eigene Verantwortlichkeit ist: Die Notizen
  berühren weder die Anker noch die Linie. (Der Anlass war die
  600-Zeilen-Grenze an `Worker.Jack.Zeit.Werkzeuge`; der Schnitt liegt
  dort, wo er ohnehin liegen würde.)
  """

  alias Worker.Jack.Zeit.Stand

  @abschnitte ~w(ABLAUF ZEITEN OFFEN)

  def werkzeuge do
    [
      %{
        name: "notiz",
        beschreibung:
          "Hält etwas fest, das der nächste Lauf wissen muss. Das ist das " <>
            "ERGEBNIS dieses Laufs — was du nicht notierst, ist nach dem Lauf weg. " <>
            "abschnitt: „ABLAUF“ für die Stationen der Handlung in der Welt " <>
            "(nicht das, was am Tisch besprochen wurde), „ZEITEN“ für jede " <>
            "Zeitangabe, die dir beim Lesen begegnet — mit der Zeilennummer, " <>
            "damit der nächste Lauf sie wiederfindet, „OFFEN“ für das, was du " <>
            "nicht einordnen konntest, mit Grund. schluessel: ein kurzes Wort, " <>
            "unter dem du es wiederfindest — derselbe Schlüssel ersetzt die " <>
            "Notiz, du kannst also korrigieren.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "abschnitt" => %{
              "type" => "string",
              "enum" => @abschnitte,
              "description" =>
                "ABLAUF (die Stationen der Handlung), ZEITEN (jede Zeitangabe mit Zeilennummer) oder OFFEN (was du nicht einordnen konntest)."
            },
            "schluessel" => %{
              "type" => "string",
              "description" =>
                "Kurzer Name des Eintrags. Derselbe Schlüssel ersetzt die bisherige Notiz — so korrigierst du, ohne zu wiederholen."
            },
            "text" => %{
              "type" => "string",
              "description" =>
                "Der Eintrag selbst. Bei ZEITEN gehört die Zeilennummer hinein, sonst muss der nächste Lauf sie suchen."
            }
          },
          "required" => ~w(abschnitt schluessel text)
        },
        wiederholung: :zaehlt,
        ausfuehren: &w_notiz/2
      },
      %{
        name: "notizen_lesen",
        beschreibung:
          "Zeigt, was du bisher notiert hast — ohne Angabe alles, mit " <>
            "abschnitt nur diesen. Nimm das, statt dich zu erinnern.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "abschnitt" => %{
              "type" => "string",
              "enum" => @abschnitte,
              "description" => "Nur diesen Abschnitt zeigen; ohne Angabe alle."
            }
          },
          "required" => []
        },
        optional: ["abschnitt"],
        wiederholung: :bis_aenderung,
        ausfuehren: &w_notizen_lesen/2
      }
    ]
  end

  defp w_notiz(s, f) do
    abschnitt = to_string(f["abschnitt"])
    schluessel = String.trim(to_string(f["schluessel"] || ""))
    text = String.trim(to_string(f["text"] || ""))

    cond do
      abschnitt not in @abschnitte ->
        {s, {:error, "abschnitt muss einer von #{Enum.join(@abschnitte, ", ")} sein."}}

      schluessel == "" ->
        {s, {:error, "Ohne schluessel findest du die Notiz nicht wieder."}}

      text == "" ->
        {s, {:error, "Eine leere Notiz hält nichts fest."}}

      true ->
        s = Stand.notieren(s, abschnitt, schluessel, text)
        z = Stand.zahlen(s)

        {s,
         {:ok,
          "Notiert unter #{abschnitt}/#{schluessel}. " <>
            "Notizen: #{map_size(s.notizen)}. Gelesen #{z.gelesen}/#{z.utterances}."}}
    end
  end

  defp w_notizen_lesen(s, f) do
    abschnitt = f["abschnitt"] && to_string(f["abschnitt"])

    case Stand.notizen(s, abschnitt) do
      [] ->
        {s, {:ok, "Noch nichts notiert#{if abschnitt, do: " unter #{abschnitt}", else: ""}."}}

      eintraege ->
        {s,
         {:ok,
          Enum.map_join(eintraege, "\n", fn n ->
            "- **#{n.schluessel}** (#{n.abschnitt}): #{n.text}"
          end)}}
    end
  end
end
