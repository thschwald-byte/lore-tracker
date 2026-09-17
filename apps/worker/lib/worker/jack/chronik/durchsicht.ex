defmodule Worker.Jack.Chronik.Durchsicht do
  @moduledoc """
  Die Durchsicht der Chronik (J7, #1211): Jack bekommt jeden Eintrag einzeln
  vorgelegt und entscheidet, ob er steht.

  Die Mechanik ist die des Resümee- und des Epos-Jack
  (`Worker.Jack.Resuemee.Durchsicht`): ein laufender Durchgang, je Eintrag
  bestätigen oder ersetzen, höchstens drei Durchgänge, und `fertig` lehnt ab,
  solange im laufenden Durchgang etwas unbearbeitet ist.

  **Ein Zyklus ist hier ein Korrekturauftrag, kein Abbruch.** Beziehen sich
  Einträge im Kreis aufeinander, gibt es keine Reihenfolge — aber die Chronik
  ist deswegen nicht verloren. `Worker.Jack.Chronik.Lesen` zeigt den Kreis
  samt Beteiligten, und Jack löst ihn mit `eintrag_einordnen` auf. Deshalb
  hat die Durchsicht als einziger der drei Läufe auch die beiden Werkzeuge
  zum Ändern der Ordnung: Was sie findet, soll sie beheben können.

  **Kuratiertes kann sie nicht ersetzen.** `eintrag_ersetzen` prüft das
  genauso wie `eintrag_streichen` — der Text gehört dem Spielleiter. Sie kann
  ihn fortschreiben und einordnen.
  """

  alias Worker.Jack.Chronik.Lesen
  alias Worker.Jack.Resuemee.Stand

  @doc "Die Werkzeuge der Durchsicht."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "durchsicht",
        beschreibung:
          "Legt dir den Eintrag mit der Nummer vor — Titel, Text, Fakten, Wichtigkeit " <>
            "und Bezug, dazu die Nachbarn in der Reihenfolge. Danach entscheidest du " <>
            "mit eintrag_bestaetigen() oder eintrag_ersetzen().",
        parameter: %{
          "type" => "object",
          "properties" => %{"nummer" => %{"type" => "integer"}},
          "required" => ["nummer"]
        },
        wiederholung: :bis_aenderung,
        ausfuehren: &vorlegen/2
      },
      %{
        name: "eintrag_bestaetigen",
        beschreibung:
          "Lässt den Eintrag stehen, wie er ist. Das ist die richtige Antwort, wenn " <>
            "die Flughöhe stimmt, kein Einschnitt darin verschwindet und der Bezug " <>
            "passt.",
        parameter: %{
          "type" => "object",
          "properties" => %{"nummer" => %{"type" => "integer"}},
          "required" => ["nummer"]
        },
        wiederholung: :zaehlt,
        ausfuehren: &bestaetigen/2
      },
      %{
        name: "eintrag_ersetzen",
        beschreibung:
          "Schreibt den Eintrag neu — Titel, Text, Fakten und Wichtigkeit. grund: was " <>
            "nicht stimmte. Einen Eintrag, den der Spielleiter kuratiert hat, ersetzt " <>
            "das Werkzeug NICHT; dort sind eintrag_ergaenzen() und " <>
            "eintrag_einordnen() die Wege.",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "nummer" => %{"type" => "integer"},
            "titel" => %{"type" => "string"},
            "text" => %{"type" => "string"},
            "fakt_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
            "wichtigkeit" => %{"type" => "string", "enum" => ~w(phase schluesselszene)},
            "grund" => %{"type" => "string"}
          },
          "required" => ~w(nummer titel text fakt_ids wichtigkeit grund)
        },
        wiederholung: :zaehlt,
        ausfuehren: &ersetzen/2
      }
    ]
  end

  @doc """
  Der Text, den `durchsicht(nummer)` zeigt. Pur und öffentlich, damit ein
  Test ihn ohne Halter prüfen kann.
  """
  @spec vorlage(Stand.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def vorlage(%Stand{eintraege: eintraege}, nummer) do
    case Enum.at(eintraege, nummer - 1) do
      nil ->
        {:error,
         "Den Eintrag #{nummer} gibt es nicht — die Chronik hat #{length(eintraege)} " <>
           "Einträge. chronik() zeigt sie alle."}

      e ->
        {:ok,
         "Eintrag #{nummer} von #{length(eintraege)}\n" <>
           "  [#{e.id}] #{e.titel}\n" <>
           "  Wichtigkeit: #{e.wichtigkeit}\n" <>
           "  Fakten: #{fakten(e)}\n" <>
           "  Bezug: #{bezug(e.zeit_bezug)}#{kuratiert(e)}\n\n#{e.text}"}
    end
  end

  defp vorlegen(s, %{"nummer" => nummer}) when is_integer(nummer) do
    case vorlage(s, nummer) do
      {:ok, text} -> {%{s | durchsicht: merken(s.durchsicht, nummer)}, {:ok, text}}
      {:error, m} -> {s, {:error, m}}
    end
  end

  defp vorlegen(s, _), do: {s, {:error, "nummer fehlt oder ist keine Zahl."}}

  defp bestaetigen(s, %{"nummer" => nummer}) when is_integer(nummer) do
    case Enum.at(s.eintraege, nummer - 1) do
      nil -> {s, {:error, "Den Eintrag #{nummer} gibt es nicht."}}
      e -> {erledigt(s, nummer, :bestaetigt), {:ok, "Eintrag #{e.id} bestätigt."}}
    end
  end

  defp bestaetigen(s, _), do: {s, {:error, "nummer fehlt oder ist keine Zahl."}}

  defp ersetzen(s, %{"nummer" => nummer} = p) when is_integer(nummer) do
    case Enum.at(s.eintraege, nummer - 1) do
      nil ->
        {s, {:error, "Den Eintrag #{nummer} gibt es nicht."}}

      %{kuratiert?: true} = e ->
        {s,
         {:error,
          "Eintrag #{e.id} ist vom Spielleiter kuratiert und wird nicht ersetzt. " <>
            "Schreib ihn mit eintrag_ergaenzen() fort oder setz ihn mit " <>
            "eintrag_einordnen() an eine andere Stelle."}}

      e ->
        neu = %{
          e
          | titel: Map.get(p, "titel", e.titel),
            text: Map.get(p, "text", e.text),
            fakt_ids: Map.get(p, "fakt_ids", e.fakt_ids),
            wichtigkeit: Map.get(p, "wichtigkeit", e.wichtigkeit)
        }

        s = %{s | eintraege: List.replace_at(s.eintraege, nummer - 1, neu)}
        {erledigt(s, nummer, :ersetzt), {:ok, "Eintrag #{e.id} ersetzt."}}
    end
  end

  defp ersetzen(s, _), do: {s, {:error, "nummer fehlt oder ist keine Zahl."}}

  # Der Zustand der Durchsicht: welcher Durchgang läuft und was darin schon
  # bearbeitet ist. Dieselbe Gestalt wie beim Resümee-Jack, damit
  # `Worker.Jack.Resuemee.Abschluss.hindernisse/2` sie lesen kann.
  defp merken(nil, nummer), do: %{durchgang: 1, vorgelegt: [nummer], erledigt: %{}}

  defp merken(d, nummer),
    do: %{d | vorgelegt: Enum.uniq([nummer | d.vorgelegt])}

  defp erledigt(s, nummer, art) do
    d = s.durchsicht || %{durchgang: 1, vorgelegt: [], erledigt: %{}}
    %{s | durchsicht: %{d | erledigt: Map.put(d.erledigt, nummer, art)}}
  end

  defp fakten(%{fakt_ids: []}), do: "keine"
  defp fakten(%{fakt_ids: ids}) when length(ids) <= 8, do: Enum.join(ids, ", ")

  defp fakten(%{fakt_ids: ids}),
    do: (ids |> Enum.take(8) |> Enum.join(", ")) <> " und #{length(ids) - 8} weitere"

  defp bezug(%{"art" => "isoliert"}), do: "ohne"
  defp bezug(%{"art" => "absolut", "zeit" => z}), do: "absolut, #{z}"
  defp bezug(%{"art" => a, "ziel" => z}), do: "#{a} #{z}"
  defp bezug(_), do: "ohne"

  defp kuratiert(%{kuratiert?: true}),
    do: "\n  VOM SPIELLEITER KURATIERT — nicht ersetzen, nicht streichen"

  defp kuratiert(_), do: ""

  @doc "Der Chronik-Text für den Auftrag der Durchsicht."
  @spec uebersicht(Stand.t()) :: String.t()
  def uebersicht(%Stand{} = s), do: Lesen.text(s)
end
