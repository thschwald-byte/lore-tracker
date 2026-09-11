defmodule Worker.Agent.Modell do
  @moduledoc """
  Die Schnittstelle zum Modell: Verlauf und Werkzeuge hinein, eine Antwort
  heraus. Eine Implementierung übersetzt nur Formate — Schleife, Prüfung und
  Kompaktierung liegen in `Worker.Agent.Lauf`.

  ## Nachrichten

  Der Verlauf ist eine Liste von Maps mit Atom-Schlüsseln:

    * `%{role: :system | :user, content: text}`
    * `%{role: :assistant, content: text | nil, tool_calls: [aufruf]}`, dazu
      `denken: text`, wenn der Lauf die Denkspur zurückschickt
      (`denken_zurueck`, `Worker.Agent.Lauf`)
    * `%{role: :tool, tool_call_id: id, name: name, content: text, fehler: boolean}`

  ## Antwort

  `stopp` ist `:stop` (fertig), `:werkzeuge` (Aufrufe angefordert) oder
  `:laenge` (an der Ausgabegrenze abgeschnitten). `denken` ist die Denkspur,
  falls das Modell eine liefert; sie geht ins Protokoll und nur mit
  `denken_zurueck` zurück an das Modell. `argumente` ist `{:ok, map}` oder `{:error, roh}`, wenn das Modell
  kein JSON-Objekt geschickt hat — der Lauf antwortet dann mit einem
  Fehlerergebnis, statt abzustürzen.
  """

  alias Worker.Agent.Werkzeug

  @type aufruf :: %{
          id: String.t(),
          name: String.t(),
          argumente: {:ok, map()} | {:error, String.t()}
        }
  @type nutzung :: %{eingabe: non_neg_integer(), ausgabe: non_neg_integer()}
  @type antwort :: %{
          text: String.t() | nil,
          denken: String.t() | nil,
          aufrufe: [aufruf()],
          stopp: :stop | :werkzeuge | :laenge,
          nutzung: nutzung() | nil
        }

  @callback antworten(nachrichten :: [map()], werkzeuge :: [Werkzeug.t()], opts :: keyword()) ::
              {:ok, antwort()} | {:error, term()}

  @doc """
  Ruft die Implementierung auf. Eine Ausnahme oder ein Exit darin wird zu
  `{:error, _}` — ein kaputter Client beendet den Lauf mit einem Grund, nicht
  mit einem Absturz.
  """
  @spec aufrufen({module(), keyword()}, [map()], [Werkzeug.t()]) ::
          {:ok, antwort()} | {:error, term()}
  def aufrufen({modul, opts}, nachrichten, werkzeuge) do
    modul.antworten(nachrichten, werkzeuge, opts)
  rescue
    e -> {:error, {:ausnahme, Exception.message(e)}}
  catch
    :exit, grund -> {:error, {:exit, grund}}
  end
end
