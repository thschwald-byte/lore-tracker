defmodule Worker.Jack.Felder do
  @moduledoc """
  Felder und erlaubte Werte einer Aussage, und die Parameter-Schemas für
  `aussage` und `aussage_entscheiden`.

  **Issue #1066: eine Aussage kann mehrere Figuren tragen.** Bis dahin gab es
  zwei Skalare (`character` + `cast_match`), und „Double Tap stabilisiert Lucky
  mit dem Medkit“ konnte nur eine der beiden festhalten — an der Fable-Referenz
  gemessen wären 42 von 419 Aussagen für eine Figurensicht unsichtbar gewesen,
  bei Lucky jede fünfte. Jetzt ist es EIN Feld `characters`, eine Liste von
  Objekten `%{"name", "cast"}`. **Eine Liste von Objekten, nicht zwei parallele
  Listen:** das Werkzeug kann jede Form erzwingen, auch gleiche Länge — aber
  nicht die ZUORDNUNG. Zwei gleich lange Listen mit vertauschter Reihenfolge
  wären formal einwandfrei und semantisch still falsch; im Objekt ist das
  strukturell unmöglich.

  Die Enums sind dieselben wie in der Pipeline (`Parsing`: `@narration_times`,
  `@precisions`, `@fact_types`) — ein Quelltext-Wächter hält beide gleich,
  denn J4 gibt Jacks Aussagen später an genau diese Normalisierung.

  Die Schemas gehen durch `Worker.Agent.Werkzeug.neu/1` und werden dort streng
  (jedes Feld Pflicht, Pflicht-Texte nicht leer). Bewusste Ausnahmen:

    * `characters` darf leer sein (`[]`): eine Weltaussage hat keine Figur.
      Innerhalb eines Eintrags ist `name` Pflicht und nicht leer — ein Eintrag
      ohne Namen wäre keine Figur —, `cast` dagegen darf leer sein
      (`minLength: 0`). Für den Cast-Abgleich hat der Spike den Escape-Wert
      „(kein Cast-Treffer)“ gemessen und verworfen — ein Wort, das „nichts“
      heißt, landete prompt im Namensfeld, und die Pipeline las den Vorgänger
      „(kein Treffer)“ als Figurennamen (123 von 230 Aussagen). Leer ist für
      die Pipeline gleichbedeutend mit dem Escape-Wert.
    * `in_game_date` darf leer sein: eine Aussage ohne Zeitausdruck hat kein
      Datum.
    * `time_offset` und `precision` sind optional, wie im Spike.

  Die Enums liegen im Schema; ein unbekannter Wert wird damit schon von der
  Laufzeit abgelehnt. Die Antwort an Jack schreibt aber
  `Worker.Jack.Aussage.formfehler/4`, im Wortlaut des Spikes.
  """

  @narration_times ~w(present flashback future unknown)
  @time_anchors ~w(absolute session unknown)
  @fact_types ~w(ereignis zustand zustandsänderung beziehung absicht enthüllung auflösung)
  @precisions ~w(day month season year decade)
  @einheiten ~w(day week month year)

  @inhalt ~w(claim characters narration_time time_anchor in_game_date fact_type
             threads source_refs beleg time_offset precision)
  @steuerung ~w(verifikations_guid entscheidung begruendung weitere_guids)

  @doc "Die erlaubten Werte je Enum-Feld."
  @spec enums() :: %{String.t() => [String.t()]}
  def enums do
    %{
      "narration_time" => @narration_times,
      "time_anchor" => @time_anchors,
      "fact_type" => @fact_types,
      "precision" => @precisions
    }
  end

  @doc "Einheiten von `time_offset.unit` — die, mit denen der Resolver rechnet."
  @spec einheiten() :: [String.t()]
  def einheiten, do: @einheiten

  @doc "Die Felder, die den Inhalt einer Aussage bilden."
  @spec inhaltsfelder() :: [String.t()]
  def inhaltsfelder, do: @inhalt

  @doc "Die Steuerfelder von `aussage_entscheiden` — sie gehören nicht in den Bestand."
  @spec steuerfelder() :: [String.t()]
  def steuerfelder, do: @steuerung

  @doc "Felder, die nicht Pflicht sind (für `Worker.Agent.Werkzeug.neu/1`, `optional:`)."
  @spec optional() :: [String.t()]
  def optional, do: ["time_offset", "precision"]

  @doc "Parameter von `aussage` (einreichen)."
  @spec einreichen_schema() :: map()
  def einreichen_schema, do: %{"type" => "object", "properties" => inhalt()}

  @doc "Parameter von `aussage_entscheiden`: der Inhalt noch einmal, dazu die Entscheidung."
  @spec entscheiden_schema() :: map()
  def entscheiden_schema do
    %{"type" => "object", "properties" => Map.merge(inhalt(), steuerung())}
  end

  defp inhalt do
    %{
      "claim" => %{"type" => "string"},
      "characters" => %{
        "type" => "array",
        "description" =>
          "wer in dieser Aussage handelt, spricht oder an ihr beteiligt ist — " <>
            "die handelnde Figur zuerst. [] bei einer Weltaussage, in der niemand handelt.",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "der Figurenname, wie er im Text steht"
            },
            "cast" => %{
              "type" => "string",
              "minLength" => 0,
              "description" =>
                "der Eintrag aus cast(), der genau auf diesen Namen passt, in " <>
                  "identischer Schreibweise; leer, wenn keiner passt"
            }
          }
        }
      },
      "narration_time" => %{"type" => "string", "enum" => @narration_times},
      "time_anchor" => %{"type" => "string", "enum" => @time_anchors},
      "in_game_date" => %{"type" => "string", "minLength" => 0},
      "fact_type" => %{"type" => "string", "enum" => @fact_types},
      "threads" => %{"type" => "array", "items" => %{"type" => "string"}},
      "source_refs" => %{"type" => "array", "items" => %{"type" => "integer"}, "minItems" => 1},
      "beleg" => %{
        "type" => "string",
        "description" =>
          "woertliches Zitat — aus JEDEM Block in source_refs eines; mehrere Zitate " <>
            "mit „ … “ trennen. Eine Frage nur zusammen mit ihrer Antwort."
      },
      "time_offset" => %{
        "type" => ["object", "null"],
        "properties" => %{
          "value" => %{"type" => "integer"},
          "unit" => %{"type" => "string", "enum" => @einheiten}
        }
      },
      "precision" => %{"type" => "string", "enum" => @precisions}
    }
  end

  defp steuerung do
    %{
      "verifikations_guid" => %{
        "type" => "string",
        "description" => "die GUID aus der Antwort, die dir die bestehende Aussage vorgelegt hat"
      },
      "entscheidung" => %{
        "type" => "string",
        "enum" => ["neu", "ersetzt"],
        "description" => "\"neu\" oder \"ersetzt\""
      },
      "begruendung" => %{
        "type" => "string",
        "description" =>
          "worin sich deine Aussage von der vorgelegten unterscheidet (bei \"neu\") bzw. " <>
            "was deine Fassung besser macht (bei \"ersetzt\")"
      },
      "weitere_guids" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" =>
          "nur bei entscheidung \"ersetzt\": weitere GUIDs aus derselben Antwort, deren " <>
            "Aussagen deine Fassung ebenfalls abdeckt. Sie werden verworfen und auf deine " <>
            "verwiesen. Sonst eine leere Liste."
      }
    }
  end
end
