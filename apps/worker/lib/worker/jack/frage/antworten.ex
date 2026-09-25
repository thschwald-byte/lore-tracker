defmodule Worker.Jack.Frage.Antworten do
  @moduledoc """
  `antworte` — das einzige schreibende Werkzeug des Frage-Jack (#850) und
  zugleich sein Abschluss: Es liefert `:halt`, der Lauf endet damit.

  **Die IDs werden übersetzt, nicht durchgereicht.** Das Modell nennt die
  kurzen (`S1-F12`, eine Position im Bestand); gespeichert wird die echte,
  inhaltsadressierte ID (`Worker.Jack.Chronik.Entwurf.karte/1`). Ohne diese
  Übersetzung zeigte jeder Beleg nach dem nächsten Regenerate stumm auf einen
  anderen Fakt — die K6-Klasse, die den Chronik-Jack bis zum Review vom
  18.09.2026 betraf.

  **Eine leere Faktenliste ist erlaubt und ausdrücklich gewollt.** Das Feld
  ist Pflicht, sein Inhalt nicht: Findet Jack nichts, ist `fakt_ids: []` die
  ehrliche Antwort. Erzwänge das Werkzeug mindestens einen Beleg, erfände das
  Modell einen, um durchzukommen — genau der Fehler, gegen den das Werkzeug da
  ist.

  **Geprüft wird hier nur die Existenz.** Ob die genannten Fakten die Antwort
  auch *stützen*, prüft `Worker.Jack.Frage.Stuetzung` **nach** dem Lauf: Diese
  Prüfung braucht ein Modell, und ein Werkzeug, das ein Modell ruft, wäre
  weder ohne Ollama testbar noch bei einem Fehlschlag folgenlos. Das Ergebnis
  ist deshalb `geprueft: :ids` — was die Oberfläche als „IDs geprüft" statt
  „gestützt" ausweist, solange die zweite Prüfung nicht gelaufen ist.
  """

  alias Worker.Jack.Antwort
  alias Worker.Jack.Chronik.Entwurf
  alias Worker.Jack.Resuemee.Stand

  @type ergebnis :: {Stand.t(), Worker.Agent.Werkzeug.ergebnis()}

  @doc "Das Werkzeug `antworte`, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "antworte",
        beschreibung:
          "Gibt deine Antwort auf die Frage und beendet damit den Lauf — der EINZIGE gültige " <>
            "Abschluss. Ein Satz in der letzten Nachricht zählt nicht. fakt_ids nennt die " <>
            "Fakten, auf die sich die Antwort stützt, in der Schreibweise von fakten() " <>
            "(S1-F12). Das Werkzeug LEHNT AB, wenn es einen dieser Fakten nicht gibt. " <>
            "Findest du nichts, was die Frage beantwortet, sag das im Text und gib fakt_ids " <>
            "leer an — eine leere Liste ist eine gültige Antwort, ein erfundener Beleg nicht.",
        parameter: schema(),
        wiederholung: :frei,
        ausfuehren: &antworte/2
      }
    ]
  end

  @doc "Die Antwort entgegennehmen (Werkzeug `antworte`)."
  @spec antworte(Stand.t(), map()) :: ergebnis()
  def antworte(%Stand{} = s, p) do
    with {:ok, text} <- text(p),
         {:ok, kurze, echte} <- fakt_ids(p, Entwurf.karte(s)) do
      antwort = %{text: text, kurze_ids: kurze, fakt_ids: echte, geprueft: :ids}
      s = %{s | antwort: antwort}
      s = Stand.journal(s, "antwort.jsonl", eintrag(antwort))

      {s,
       {:halt,
        Antwort.geordnet([
          {"ok", true},
          {"fertig", true},
          {"belege", length(echte)},
          {"hinweis", "Antwort angenommen. Du kannst aufhören."}
        ])}}
    else
      {:error, text} -> {s, {:error, text}}
    end
  end

  defp text(p) do
    case p["text"] do
      t when is_binary(t) ->
        case String.trim(t) do
          "" -> {:error, "text ist leer. Schreibe die Antwort, die am Tisch vorgelesen wird."}
          getrimmt -> {:ok, getrimmt}
        end

      _ ->
        {:error, "text fehlt oder ist kein Text. Schreibe die Antwort auf die Frage."}
    end
  end

  # Wie `Worker.Jack.Chronik.Entwurf.fakt_ids/2`, aber mit eigener Meldung
  # (dort spricht sie von der Chronik) und mit den kurzen IDs im Ergebnis: Die
  # Oberfläche zeigt sie dem Menschen, gespeichert wird die echte.
  defp fakt_ids(p, bekannte) do
    case Map.get(p, "fakt_ids") do
      ids when is_list(ids) ->
        case Enum.reject(ids, &Map.has_key?(bekannte, &1)) do
          [] ->
            kurze = Enum.uniq(ids)
            {:ok, kurze, kurze |> Enum.map(&Map.fetch!(bekannte, &1)) |> Enum.uniq()}

          fehlend ->
            {:error,
             "Diese Fakten gibt es nicht: #{Enum.join(fehlend, ", ")}. " <>
               "Nimm die IDs so, wie fakten() sie nennt. Die Antwort darf nur auf " <>
               "Fakten zeigen, die dastehen."}
        end

      _ ->
        {:error,
         "fakt_ids fehlt oder ist keine Liste. Nenne die Fakten, auf die sich deine " <>
           "Antwort stützt — oder eine leere Liste, wenn du nichts gefunden hast."}
    end
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "die Antwort auf die Frage, so wie sie am Tisch vorgelesen wird"
        },
        "fakt_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "die Fakten, auf die sich die Antwort stützt, als S1-F12; leer, wenn du nichts fandst"
        }
      }
    }
  end

  defp eintrag(a),
    do: %{
      "text" => a.text,
      "fakt_ids" => a.fakt_ids,
      "kurze_ids" => a.kurze_ids,
      "belege" => length(a.fakt_ids)
    }
end
