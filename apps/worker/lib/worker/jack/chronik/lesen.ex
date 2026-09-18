defmodule Worker.Jack.Chronik.Lesen do
  @moduledoc """
  Das Werkzeug `chronik` (J7, #1211): zeigt, was schon dasteht — den Bestand
  der Kampagne und die Einträge dieses Laufs, in der gerechneten Reihenfolge.

  **Ohne dieses Werkzeug gäbe es keine Verfeinerung**, und die ist der
  Normalbetrieb: Der volle Lauf mit Überblick passiert genau einmal, solange
  die Chronik leer ist; ab dem ersten Eintrag liest Jack, was da ist,
  ergänzt und ordnet ein. Er muss dafür sehen, welche Phasen offen sind,
  welche Fakten schon belegt sind und **was der Spielleiter kuratiert hat** —
  Letzteres, weil er es fortschreiben, aber nicht streichen darf.

  **Die Reihenfolge steht dabei, nicht das Datum.** Was `chronik` zeigt, ist
  die Ordnung, die aus den Bezügen folgt (`Worker.Jack.Chronik.Ordnung`) —
  Gleichzeitiges nebeneinander, Widersprüche als Befund. Ein Tag steht nur
  dort, wo ein Anker ihn trägt; ohne Anker bleibt die Reihenfolge und das
  Feld leer. Das ist der ganze Punkt dieses Umbaus: lieber keine Angabe als
  eine gerechnete, die niemand nachprüfen kann.
  """

  alias Worker.Jack.Chronik.{Entwurf, Ordnung}
  alias Worker.Jack.Resuemee.Stand

  @doc "Das Werkzeug `chronik` für einen Stand."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "chronik",
        beschreibung:
          "Zeigt die Chronik: die Einträge in der Reihenfolge, die aus deinen Bezügen " <>
            "folgt, je mit ihren Fakten, ihrer Wichtigkeit und der Angabe, ob der " <>
            "Spielleiter sie kuratiert hat. Kuratierte Einträge darfst du " <>
            "fortschreiben (eintrag_ergaenzen) und einordnen (eintrag_einordnen), " <>
            "aber nicht streichen. Stehen zwei Einträge nebeneinander, hast du sie " <>
            "als gleichzeitig angegeben. Meldet das Werkzeug einen Widerspruch, " <>
            "beziehen sich Einträge im Kreis aufeinander — löse ihn mit " <>
            "eintrag_einordnen auf.",
        parameter: %{"type" => "object", "properties" => %{}, "required" => []},
        wiederholung: :frei,
        ausfuehren: fn s, _p -> {s, {:ok, text(s)}} end
      }
    ]
  end

  @doc """
  Der Text der Chronik. Öffentlich, weil die Durchsicht denselben Blick
  braucht — und damit ein Test ihn lesen kann, ohne den Halter zu starten.
  """
  @spec text(Stand.t()) :: String.t()
  def text(%Stand{eintraege: []}),
    do:
      "Die Chronik ist leer. Lege mit chronik_eintrag() die Abschnitte der Handlung an — " <>
        "ein ganzer Auftrag ist EIN Eintrag."

  def text(%Stand{eintraege: eintraege}) do
    kopf = "#{length(eintraege)} Einträge.\n"

    case Entwurf.ordnen(eintraege) do
      {:ok, %{reihenfolge: reihenfolge, verwaist: verwaist}} ->
        kopf <> geordnet(reihenfolge, eintraege) <> verwaist_hinweis(verwaist)

      {:zyklus, ids} ->
        kopf <>
          "\nACHTUNG, Widerspruch: Diese Einträge beziehen sich im Kreis aufeinander — " <>
          "#{Enum.join(ids, ", ")}. Solange das so ist, gibt es keine Reihenfolge. " <>
          "Ändere bei einem von ihnen den Bezug (eintrag_einordnen).\n\n" <>
          ungeordnet(eintraege)
    end
  end

  defp geordnet(reihenfolge, eintraege) do
    reihenfolge
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {klasse, stelle} ->
      gleichzeitig = if length(klasse) > 1, do: " (gleichzeitig)", else: ""

      "\n#{stelle}.#{gleichzeitig}\n" <>
        Enum.map_join(klasse, "\n", fn id ->
          eintraege |> Enum.find(&(&1.id == id)) |> zeile()
        end)
    end)
  end

  defp ungeordnet(eintraege), do: Enum.map_join(eintraege, "\n", &zeile/1)

  defp zeile(nil), do: ""

  defp zeile(e) do
    "  [#{e.id}] #{e.titel} — #{e.wichtigkeit}, #{length(e.fakt_ids)} Fakten#{kuratiert(e)}\n" <>
      "    Bezug: #{bezug(e.zeit_bezug)}\n" <>
      "    #{gekuerzt(e.text)}"
  end

  defp kuratiert(%{kuratiert?: true}), do: ", VOM SPIELLEITER KURATIERT (nicht streichen)"
  defp kuratiert(_), do: ""

  # Die Bezüge als Text — beide gespeicherten Formen über die eine Lesestelle.
  defp bezug(wert) do
    case Ordnung.bezuege(wert) do
      [] -> "ohne"
      liste -> Enum.map_join(liste, "; ", &einer/1)
    end
  end

  defp einer(%{"art" => "absolut", "zeit" => z}), do: "absolut, #{z}"
  defp einer(%{"art" => a, "ziel" => z}), do: "#{a} #{z}"
  defp einer(_), do: "ohne"

  defp gekuerzt(text) when byte_size(text) <= 200, do: text
  defp gekuerzt(text), do: binary_part(text, 0, 200) <> " …"

  defp verwaist_hinweis([]), do: ""

  defp verwaist_hinweis(ids),
    do:
      "\n\nDiese Einträge zeigen auf etwas, das es nicht gibt: #{Enum.join(ids, ", ")}. " <>
        "Ihr Bezug wird ignoriert — setz ihn mit eintrag_einordnen neu."

  @doc """
  Die Reihenfolge als Liste von IDs, für den Einbau: was `Ordnung.ordne/1`
  liefert, flach und in der Ordnung, in der die Einträge stehen sollen.
  """
  @spec rangfolge([Entwurf.eintrag()]) :: {:ok, [String.t()]} | {:zyklus, [String.t()]}
  def rangfolge(eintraege) do
    case Ordnung.ordne(Enum.map(eintraege, &%{"id" => &1.id, "zeit_bezug" => &1.zeit_bezug})) do
      {:ok, %{reihenfolge: r}} -> {:ok, List.flatten(r)}
      {:zyklus, ids} -> {:zyklus, ids}
    end
  end
end
