defmodule Worker.Agent do
  @moduledoc """
  Laufzeit für Agenten: ein Modell fordert Werkzeuge an, bekommt die Ergebnisse
  zurück und entscheidet weiter — über viele Runden und länger, als ein
  Kontextfenster reicht (Issue #1197, Epic #1195).

  Bis hierher schickt der Worker einen Prompt und liest eine Antwort
  (`Worker.LLM`). Der Spike #1174 hat gezeigt, dass ein Modell mit Werkzeugen
  mehr leistet; dort übernimmt pi die Schleife. Dieser Namensraum ist der Teil
  von pi, den ein Hintergrundjob braucht — ohne Terminal, Sitzungen und
  Provider:

    * `Worker.Agent.Lauf` — die Schleife mit Rundendeckel und Wanduhr
    * `Worker.Agent.Werkzeug` — ein Werkzeug als Datum
    * `Worker.Agent.Schema` — Prüfung der Argumente vor der Ausführung
    * `Worker.Agent.Kontext` — Kompaktierung, wenn der Verlauf zu groß wird
    * `Worker.Agent.Modell` — die Schnittstelle zum Modell, dazu
      `Worker.Agent.Modell.Ollama`
    * `Worker.Agent.Protokoll` — jede Runde als JSONL-Zeile

  **Hier gehört kein einziges Werkzeug hin.** Jacks Werkzeuge und Aufträge
  kommen später als `Worker.Jack.*` darauf (#1196); sie ändern sich mit dem
  Spike noch, diese Laufzeit nicht.

  ## Beispiel

      echo =
        Worker.Agent.Werkzeug.neu(
          name: "echo",
          beschreibung: "Gibt den Text zurück.",
          parameter: %{
            "type" => "object",
            "properties" => %{"text" => %{"type" => "string"}},
            "required" => ["text"]
          },
          ausfuehren: fn %{"text" => text} -> {:ok, text} end
        )

      Worker.Agent.laufen(
        modell: {Worker.Agent.Modell.Ollama, endpunkt: "http://localhost:11434", modell: "qwen3.8:27b"},
        system: "Du bist ein Assistent.",
        nachrichten: [%{role: :user, content: "Sag hallo über das Werkzeug echo."}],
        werkzeuge: [echo],
        protokoll: "/tmp/lauf.jsonl"
      )

  ## Herkunft

  Der Aufbau der Schleife und die Regel für den Schnittpunkt der Kompaktierung
  folgen pi (`pi-agent-core` `agent-loop.js`, `pi-coding-agent`
  `compaction.js`, Version 0.85.1), Copyright (c) 2025 Mario Zechner,
  MIT-Lizenz — der Lizenztext liegt in `LICENSES/pi-MIT.txt`. Neu geschrieben,
  nicht übersetzt; wo Verhalten übernommen ist oder bewusst abweicht, steht es
  am jeweiligen Modul.
  """

  alias Worker.Agent.Lauf

  @doc "Führt einen Lauf aus. Optionen und Ergebnis: `Worker.Agent.Lauf`."
  @spec laufen(keyword()) :: Lauf.ergebnis()
  defdelegate laufen(opts), to: Lauf
end
