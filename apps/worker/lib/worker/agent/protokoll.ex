defmodule Worker.Agent.Protokoll do
  @moduledoc """
  Jede Runde eines Laufs als JSONL-Zeile in eine Datei — ohne das ist kein
  Lauf auswertbar.

  Jede Zeile trägt `t` (UTC, ISO 8601) und `ereignis`:

    * `start` — Modell, Werkzeugnamen, Deckel
    * `anfrage` — Runde und Zahl der Nachrichten, bevor das Modell gefragt
      wird; der Abstand zur `antwort` ist die Wartezeit auf das Modell
    * `antwort` — Runde, Dauer, Stoppgrund, Text, Denkspur, Aufrufe, `usage`
    * `ergebnis` — Runde, Aufruf-ID, Werkzeug, Art (`ok`/`error`/`halt`), Text
    * `kompaktierung` — Token vorher, weggefallene und behaltene Nachrichten,
      die neue Zusammenfassung (oder `weggefallen: 0`, wenn nichts zu
      schneiden war)
    * `folge` — die Nachricht, mit der `bei_stopp` den Lauf fortsetzt
    * `modell_fehler` — Runde, Grund
    * `ende` — Grund, Runden, Kompaktierungen, Nutzung, Dauer

  Lässt sich eine Zeile nicht als JSON schreiben, steht an ihrer Stelle eine
  `protokollfehler`-Zeile mit dem Grund — der Lauf läuft weiter, die Lücke
  bleibt sichtbar.

  Ohne Pfad schreibt das Protokoll nichts.

  ## Beobachter

  Ein Beobachter (ein Prozess) bekommt jede Zeile zusätzlich als Nachricht
  `{:agent, daten}` — `daten` mit `"t"` und `"ereignis"`, wie die Zeile, aber
  vor der JSON-Kodierung. Dazu kommen Ereignisse nur für ihn (`melden/3`),
  etwa die Deltas eines gestreamten Modells: sie in die Datei zu schreiben
  hieße eine Zeile je Token. Die Nachricht ist ein `send/2` und kann den Lauf
  weder aufhalten noch abstürzen lassen, auch wenn der Beobachter tot ist.
  Darauf baut die lokale Laufsicht (#1202).
  """

  defstruct io: nil, beobachter: nil

  @type t :: %__MODULE__{io: pid() | nil, beobachter: pid() | nil}

  @doc """
  Öffnet die Datei zum Anhängen; legt das Verzeichnis an. `nil` = keine
  Datei. `beobachter` siehe oben.
  """
  @spec oeffnen(Path.t() | nil, pid() | nil) :: t()
  def oeffnen(pfad, beobachter \\ nil)

  def oeffnen(_pfad, beobachter) when not (is_nil(beobachter) or is_pid(beobachter)),
    do: raise(ArgumentError, "beobachter: pid oder nil erwartet, erhalten #{inspect(beobachter)}")

  def oeffnen(nil, beobachter), do: %__MODULE__{beobachter: beobachter}

  def oeffnen(pfad, beobachter) do
    File.mkdir_p!(Path.dirname(pfad))
    %__MODULE__{io: File.open!(pfad, [:append, :binary]), beobachter: beobachter}
  end

  @doc "Schreibt eine Zeile und meldet sie dem Beobachter."
  @spec schreiben(t(), String.t(), map()) :: :ok
  def schreiben(%__MODULE__{} = p, ereignis, daten) do
    daten = Map.merge(daten, %{"t" => jetzt(), "ereignis" => ereignis})
    senden(p, daten)
    if p.io, do: IO.binwrite(p.io, [zeile(daten), ?\n])
    :ok
  end

  @doc "Meldet ein Ereignis nur dem Beobachter, ohne Zeile in der Datei."
  @spec melden(t(), String.t(), map()) :: :ok
  def melden(%__MODULE__{beobachter: nil}, _ereignis, _daten), do: :ok

  def melden(%__MODULE__{} = p, ereignis, daten) do
    senden(p, Map.merge(daten, %{"t" => jetzt(), "ereignis" => ereignis}))
    :ok
  end

  defp senden(%__MODULE__{beobachter: nil}, _daten), do: :ok
  defp senden(%__MODULE__{beobachter: pid}, daten), do: send(pid, {:agent, daten})

  defp jetzt, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp zeile(daten) do
    Jason.encode_to_iodata!(daten)
  rescue
    e ->
      Jason.encode_to_iodata!(%{
        "t" => daten["t"],
        "ereignis" => "protokollfehler",
        "fuer" => daten["ereignis"],
        "fehler" => Exception.message(e),
        "daten" => inspect(daten, limit: 50)
      })
  end

  @doc "Schließt die Datei."
  @spec schliessen(t()) :: :ok
  def schliessen(%__MODULE__{io: nil}), do: :ok

  def schliessen(%__MODULE__{io: io}) do
    _ = File.close(io)
    :ok
  end
end
