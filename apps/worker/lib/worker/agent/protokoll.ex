defmodule Worker.Agent.Protokoll do
  @moduledoc """
  Jede Runde eines Laufs als JSONL-Zeile in eine Datei — ohne das ist kein
  Lauf auswertbar.

  Jede Zeile trägt `t` (UTC, ISO 8601) und `ereignis`:

    * `start` — Modell, Werkzeugnamen, Deckel
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
  """

  defstruct io: nil

  @type t :: %__MODULE__{io: pid() | nil}

  @doc "Öffnet die Datei zum Anhängen; legt das Verzeichnis an. `nil` = kein Protokoll."
  @spec oeffnen(Path.t() | nil) :: t()
  def oeffnen(nil), do: %__MODULE__{}

  def oeffnen(pfad) do
    File.mkdir_p!(Path.dirname(pfad))
    %__MODULE__{io: File.open!(pfad, [:append, :binary])}
  end

  @doc "Schreibt eine Zeile."
  @spec schreiben(t(), String.t(), map()) :: :ok
  def schreiben(%__MODULE__{io: nil}, _ereignis, _daten), do: :ok

  def schreiben(%__MODULE__{io: io}, ereignis, daten) do
    zeit = DateTime.utc_now() |> DateTime.to_iso8601()

    zeile =
      try do
        Jason.encode_to_iodata!(Map.merge(daten, %{"t" => zeit, "ereignis" => ereignis}))
      rescue
        e ->
          Jason.encode_to_iodata!(%{
            "t" => zeit,
            "ereignis" => "protokollfehler",
            "fuer" => ereignis,
            "fehler" => Exception.message(e),
            "daten" => inspect(daten, limit: 50)
          })
      end

    IO.binwrite(io, [zeile, ?\n])
  end

  @doc "Schließt die Datei."
  @spec schliessen(t()) :: :ok
  def schliessen(%__MODULE__{io: nil}), do: :ok

  def schliessen(%__MODULE__{io: io}) do
    _ = File.close(io)
    :ok
  end
end
