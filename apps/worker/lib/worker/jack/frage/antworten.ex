defmodule Worker.Jack.Frage.Antworten do
  @moduledoc """
  Die beiden Abschlüsse des Frage-Jack (#850). Beide liefern `:halt`, der Lauf
  endet damit — es gibt keinen dritten Weg hinaus.

  **`antworte(text, fakt_ids)`** — eine Antwort, die auf Fakten steht. Die
  Liste ist Pflicht **und darf nicht leer sein**.

  **`keine_antwort(text)`** — es gibt nichts in den Fakten. Kein Feld für
  Belege, weil es keine gibt.

  **Warum zwei Werkzeuge und nicht ein Feld, das leer bleiben darf**
  (Maintainer, 25.09.2026): Wäre die leere Liste erlaubt, müsste das Werkzeug
  jede Antwort ohne Belege durchlassen — auch die, bei der das Modell die
  Belege schlicht vergessen hat. Am Messlauf desselben Tages genau so
  gesehen: Eine Antwort nannte „in Dante's Inferno engagiert", was stimmt und
  in vier Fakten steht, zitierte aber keinen davon.

  Als getrennte Werkzeuge ist „ich habe nichts gefunden" ein **bewusster Akt**
  statt eines weggelassenen Feldes, und `antworte` kann streng sein. Dieselbe
  Logik wie `NICHT_ZEITLEISTE` beim Chronik-Jack (#1211): eine eigene Ablage
  für „gehört nicht hierher" statt eines stillen Auslassens.

  **Die IDs werden übersetzt, nicht durchgereicht.** Das Modell nennt die
  kurzen (`S1-F12`, eine Position im Bestand); gespeichert wird die echte,
  inhaltsadressierte ID (`Worker.Jack.Chronik.Entwurf.karte/1`). Ohne diese
  Übersetzung zeigte jeder Beleg nach dem nächsten Regenerate stumm auf einen
  anderen Fakt — die K6-Klasse, die den Chronik-Jack bis zum Review vom
  18.09.2026 betraf.

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

  @doc "Die beiden Abschluss-Werkzeuge, siehe `Worker.Jack.Lesen.werkzeuge/1`."
  @spec werkzeuge(Stand.t()) :: [map()]
  def werkzeuge(%Stand{}) do
    [
      %{
        name: "antworte",
        beschreibung:
          "Gibt deine Antwort auf die Frage und beendet den Lauf. Nimm es, wenn die Fakten " <>
            "die Frage beantworten. fakt_ids nennt die Fakten, auf die sich die Antwort " <>
            "stützt, in der Schreibweise von fakten() (S1-F12) — mindestens einer, und jeder " <>
            "muss existieren; das Werkzeug lehnt sonst ab. Nenne die, die die Antwort TRAGEN, " <>
            "nicht alle, die du gelesen hast. Findest du nichts, nimm keine_antwort().",
        parameter: schema_antwort(),
        wiederholung: :frei,
        ausfuehren: &antworte/2
      },
      %{
        name: "keine_antwort",
        beschreibung:
          "Beendet den Lauf mit der Auskunft, dass die Fakten die Frage nicht beantworten. " <>
            "Das ist ein vollwertiger Abschluss, kein Scheitern: „dazu steht nichts in den " <>
            "Fakten\" ist eine richtige Antwort, ein erfundener Beleg nicht. Sag im Text, was " <>
            "du gesucht hast und was stattdessen dasteht, damit der Fragende weiß, woran es " <>
            "liegt.",
        parameter: schema_keine(),
        wiederholung: :frei,
        ausfuehren: &keine_antwort/2
      }
    ]
  end

  @doc "Die Antwort mit Belegen entgegennehmen (Werkzeug `antworte`)."
  @spec antworte(Stand.t(), map()) :: ergebnis()
  def antworte(%Stand{} = s, p) do
    with {:ok, text} <- text(p),
         {:ok, kurze, echte} <- fakt_ids(p, Entwurf.karte(s)) do
      abschluss(s, %{
        text: text,
        kurze_ids: kurze,
        fakt_ids: echte,
        geprueft: :ids,
        belegt?: true
      })
    else
      {:error, text} -> {s, {:error, text}}
    end
  end

  @doc "Die Auskunft, dass es nichts gibt (Werkzeug `keine_antwort`)."
  @spec keine_antwort(Stand.t(), map()) :: ergebnis()
  def keine_antwort(%Stand{} = s, p) do
    case text(p) do
      {:ok, text} ->
        abschluss(s, %{
          text: text,
          kurze_ids: [],
          fakt_ids: [],
          geprueft: :ohne_beleg,
          belegt?: false
        })

      {:error, text} ->
        {s, {:error, text}}
    end
  end

  defp abschluss(s, antwort) do
    s = %{s | antwort: antwort}
    s = Stand.journal(s, "antwort.jsonl", eintrag(antwort))

    {s,
     {:halt,
      Antwort.geordnet([
        {"ok", true},
        {"fertig", true},
        {"belege", length(antwort.fakt_ids)},
        {"hinweis", "Antwort angenommen. Du kannst aufhören."}
      ])}}
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
      [] ->
        {:error,
         "fakt_ids ist leer. Wenn die Fakten die Frage beantworten, nenne die, auf die " <>
           "sich deine Antwort stützt. Wenn nicht, nimm keine_antwort() — das ist ein " <>
           "vollwertiger Abschluss."}

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
           "Antwort stützt — oder nimm keine_antwort(), wenn du nichts gefunden hast."}
    end
  end

  defp schema_antwort do
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
          "minItems" => 1,
          "description" => "die Fakten, die die Antwort tragen, als S1-F12 — mindestens einer"
        }
      }
    }
  end

  defp schema_keine do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "was du gesucht hast und was stattdessen dasteht — damit der Fragende weiß, woran es liegt"
        }
      }
    }
  end

  defp eintrag(a),
    do: %{
      "text" => a.text,
      "fakt_ids" => a.fakt_ids,
      "kurze_ids" => a.kurze_ids,
      "belege" => length(a.fakt_ids),
      "belegt" => a.belegt?
    }
end
