defmodule Worker.Agent.Werkzeug do
  @moduledoc """
  Ein Werkzeug als Datum: Name, Beschreibung, JSON-Schema der Parameter und
  die Funktion, die es ausführt.

  Die Funktion bekommt die geprüften Argumente (Map mit String-Schlüsseln, so
  wie das Modell sie geschickt hat, nach `Worker.Agent.Schema` angeglichen)
  und liefert eines von vier Ergebnissen:

    * `{:ok, inhalt}` — geht als Werkzeugantwort an das Modell.
    * `{:error, inhalt}` — dasselbe, als Fehler markiert. Das Modell soll
      darauf reagieren können; ein Fehler beendet den Lauf nicht.
    * `{:halt, inhalt}` — das Werkzeug will den Lauf beenden. Wie bei pi
      (`shouldTerminateToolBatch`) endet er nur, wenn **alle** Aufrufe einer
      Antwort `:halt` liefern: ein Abschluss-Werkzeug neben noch laufender
      Arbeit beendet nichts.
    * `{:abbruch, inhalt}` — das Werkzeug bricht den Lauf sofort ab, als
      Fehlschlag (`ende: {:abbruch, {:werkzeug, name}}`); übrige Aufrufe
      derselben Antwort laufen nicht mehr. Für `weiter()`, das nach dem Ende
      zum dritten Mal gerufen wird (Tom: „nach 3 mal meckern von weiter()
      abbruch“).

  `inhalt` ist ein Text; eine Map oder Liste wird als JSON an das Modell
  gegeben. Eine Ausnahme im Werkzeug wird zum Fehlerergebnis mit ihrer
  Meldung — ein Werkzeug kann den Lauf nicht abstürzen lassen.

  Angelegt wird mit `neu/1`. Es prüft beim Anlegen, was sonst erst im Lauf
  oder gar nicht auffiele: einen Namen, den die Chat-API ablehnt, und
  Schema-Schlüssel, die `Worker.Agent.Schema` nicht prüft.

  ## Streng per Default

  `neu/1` macht die Parameter streng (`Worker.Agent.Schema.streng/2`): jedes
  Feld ist Pflicht, fremde Felder sind verboten, ein Pflicht-Text darf nicht
  leer sein. Ein Werkzeug, das Halbes annimmt, lädt den Agenten ein, es mit
  Probeaufrufen abzutasten, statt eine durchdachte, vollständige Angabe zu
  machen (Toms Vorgabe für #1195: „so viele Pflichtfelder wie sinnvoll“).
  Ein Feld ist nur optional, wenn es in `optional:` steht — die Ausnahme ist
  damit eine sichtbare Entscheidung am Werkzeug, kein Versehen.

  Pflichtfelder helfen nur, solange die Ablehnung die erwarteten Werte nicht
  selbst verrät: eine Fehlermeldung, die die richtige Zahl nennt, macht aus
  jeder Pflicht einen Abschreibeweg. Das liegt beim einzelnen Werkzeug.

  Ein Werkzeug als Struct-Literal umgeht die Strenge; `pruefen!/1` sieht nur,
  was es prüfen kann.

  ## Gewollte Wiederholungen

  Die Wiederholungssperre (`Worker.Agent.Wiederholung`) führt einen Aufruf
  nicht mehr aus, wenn er im Lauf zu oft gleich wiederkommt. Wie ein
  Werkzeug dabei zählt, sagt `wiederholung:`:

    * `:zaehlt` (Default) — jeder gleiche Aufruf im Lauf zählt.
    * `:frei` — nie gezählt; für Werkzeuge, deren gleicher Aufruf gewollt ist
      (`weiter()`: keine Argumente, jedes Mal der nächste Abschnitt) oder
      harmlos (`notizen_lesen`, `cast`, `straenge`, `fertig`).
    * `:bis_aenderung` — zählt nur, solange sich der Bestand nicht geändert
      hat; für Werkzeuge, deren Antwort am Bestand hängt (`aussagen`,
      `aenderungen`, `ablehnungen`).

  `aendert_bestand: true` markiert die Werkzeuge, deren erfolgreicher Aufruf
  den Bestand ändert; danach beginnt die Zählung der `:bis_aenderung`-Aufrufe
  neu. Die Zuordnung hat Tom am 10.09.2026 bestätigt; wie bei `optional:` ist
  jede Ausnahme eine sichtbare Entscheidung am Werkzeug.
  """

  alias Worker.Agent.Schema

  @enforce_keys [:name, :beschreibung, :parameter, :ausfuehren]
  defstruct @enforce_keys ++ [wiederholung: :zaehlt, aendert_bestand: false]

  @type ergebnis :: {:ok, term()} | {:error, term()} | {:halt, term()} | {:abbruch, term()}
  @type t :: %__MODULE__{
          name: String.t(),
          beschreibung: String.t(),
          parameter: map(),
          ausfuehren: (map() -> ergebnis()),
          wiederholung: :zaehlt | :frei | :bis_aenderung,
          aendert_bestand: boolean()
        }

  # Die Grenze der OpenAI-Chat-API für Funktionsnamen.
  @name_muster ~r/^[A-Za-z0-9_-]{1,64}$/

  @doc """
  Legt ein Werkzeug an. Optionen: `:name`, `:beschreibung`, `:parameter`
  (JSON-Schema, oberste Ebene `"type" => "object"`; Atom-Schlüssel sind
  erlaubt), `:ausfuehren` (Funktion mit einem Argument), `:optional` (Pfade
  der Felder, die nicht Pflicht sind, siehe „Streng per Default“),
  `:wiederholung` und `:aendert_bestand` (siehe „Gewollte Wiederholungen“,
  Default `:zaehlt` und `false`). Wirft
  `ArgumentError`, wenn etwas davon nicht passt.
  """
  @spec neu(keyword()) :: t()
  def neu(opts) do
    name = Keyword.fetch!(opts, :name)

    parameter =
      case Schema.streng(Keyword.fetch!(opts, :parameter), Keyword.get(opts, :optional, [])) do
        {:ok, schema} -> schema
        {:error, grund} -> raise ArgumentError, "Werkzeug #{inspect(name)}: #{grund}"
      end

    pruefen!(%__MODULE__{
      name: name,
      beschreibung: Keyword.fetch!(opts, :beschreibung),
      parameter: parameter,
      ausfuehren: Keyword.fetch!(opts, :ausfuehren),
      wiederholung: Keyword.get(opts, :wiederholung, :zaehlt),
      aendert_bestand: Keyword.get(opts, :aendert_bestand, false)
    })
  end

  @doc """
  Prüft ein Werkzeug und gibt es unverändert zurück. `Worker.Agent.Lauf`
  ruft das für jedes Werkzeug auf — auch für eines, das als Struct-Literal
  statt über `neu/1` entstanden ist.
  """
  @spec pruefen!(t()) :: t()
  def pruefen!(%__MODULE__{name: name} = w) do
    cond do
      not (is_binary(name) and Regex.match?(@name_muster, name)) ->
        raise ArgumentError,
              "Werkzeugname #{inspect(name)}: erlaubt sind 1–64 Zeichen aus A–Z, a–z, 0–9, _ und -"

      not is_binary(w.beschreibung) ->
        raise ArgumentError, "Werkzeug #{name}: beschreibung muss ein Text sein"

      not is_function(w.ausfuehren, 1) ->
        raise ArgumentError,
              "Werkzeug #{name}: ausfuehren muss eine Funktion mit einem Argument sein"

      w.wiederholung not in [:zaehlt, :frei, :bis_aenderung] ->
        raise ArgumentError,
              "Werkzeug #{name}: wiederholung muss :zaehlt, :frei oder :bis_aenderung sein"

      not is_boolean(w.aendert_bestand) ->
        raise ArgumentError, "Werkzeug #{name}: aendert_bestand muss true oder false sein"

      Schema.normalisieren(w.parameter)["type"] != "object" ->
        raise ArgumentError,
              ~s(Werkzeug #{name}: parameter braucht "type" => "object" auf oberster Ebene)

      (unbekannt = Schema.unbekannte(w.parameter)) != [] ->
        raise ArgumentError,
              "Werkzeug #{name}: nicht unterstützt im Schema: #{Enum.join(unbekannt, ", ")} — " <>
                "es würde nicht geprüft (unterstützt: #{Enum.join(Schema.schluessel(), ", ")})"

      true ->
        w
    end
  end

  @doc "Das Werkzeug im Format des `tools`-Felds der Chat-API."
  @spec als_json(t()) :: map()
  def als_json(%__MODULE__{} = w) do
    %{
      "type" => "function",
      "function" => %{
        "name" => w.name,
        "description" => w.beschreibung,
        "parameters" => Schema.normalisieren(w.parameter)
      }
    }
  end
end
