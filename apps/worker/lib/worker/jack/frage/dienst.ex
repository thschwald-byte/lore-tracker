defmodule Worker.Jack.Frage.Dienst do
  @moduledoc """
  Startet und beendet Frage-Läufe (#850).

  Jeder Lauf hat eine **Lauf-ID**, die der Hub vergibt. Sie leistet dreierlei:
  Der Worker findet den Lauf zum Abbrechen wieder, die Antwort findet ihren
  Weg zurück zu genau dem Frager (`HubWeb.PipelineStatus` routet darauf), und
  eine zweite Frage desselben Betrachters kollidiert nicht mit der ersten.

  **Der Erwerb der Karte ist atomar** (`Worker.GpuQueue.run_frei/2`): Ist ein
  anderer Job dran, kommt sofort eine Absage mit seinem Namen zurück, statt
  sich einzureihen. Eine Frage, die zwanzig Minuten hinter einer Extraktion
  wartet, beantwortet niemanden — und `Pipeline.busy?/0` davor wäre
  Check-then-Act.

  **Der Abbruch beendet den Task**, nicht erst den nächsten Rundenwechsel: Der
  Task hält den `Req.post` an Ollama; stirbt er, fällt die Verbindung. Eine
  Frist „bis zum Ende des laufenden Aufrufs" liesse die Karte bei einem
  27b-Modell auf 200 Fakten noch Dutzende Sekunden belegt — für niemanden.

  **Ehrliche Grenze:** Ob Ollama bei einem Verbindungsabbruch wirklich aufhört
  oder die Antwort zu Ende rechnet, ist **nicht gemessen**. Der Worker gibt
  die Karte in jedem Fall frei; ob die Grafikkarte es auch tut, steht dahin.
  """

  require Logger

  alias Worker.Jack.Frage

  @registry Worker.Jack.Frage.Registry

  @doc "Der Name der Registry für die Supervision."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Startet einen Frage-Lauf. Kehrt **sofort** zurück; das Ergebnis meldet
  `melden` als `{:frage_fertig, lauf_id, ergebnis}` bzw.
  `{:frage_fehler, lauf_id, grund}`.

  `{:error, {:belegt, label}}`, wenn die Karte besetzt ist — dann läuft nichts
  und es wird nichts gemeldet.
  """
  @spec starten(String.t(), String.t(), String.t(), (term() -> any()), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def starten(lauf_id, campaign_id, frage, melden, opts \\ []) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Registry.register(@registry, lauf_id, :frage) do
        {:ok, _} -> fahren(lauf_id, campaign_id, frage, melden, opts)
        {:error, {:already_registered, _}} -> melden.({:frage_fehler, lauf_id, :laeuft_schon})
      end
    end)
  end

  @doc """
  Bricht einen laufenden Frage-Lauf ab. `:ok` auch dann, wenn es ihn nicht
  (mehr) gibt — ein Abbruch auf etwas längst Beendetes ist kein Fehler.
  """
  @spec abbrechen(String.t()) :: :ok
  def abbrechen(lauf_id) do
    case Registry.lookup(@registry, lauf_id) do
      [{pid, _}] ->
        Logger.info("Frage-Jack: Lauf #{lauf_id} abgebrochen")
        Task.Supervisor.terminate_child(Worker.TaskSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  @doc "Läuft zu dieser Lauf-ID gerade etwas?"
  @spec laeuft?(String.t()) :: boolean()
  def laeuft?(lauf_id), do: Registry.lookup(@registry, lauf_id) != []

  defp fahren(lauf_id, campaign_id, frage, melden, opts) do
    ergebnis =
      Worker.GpuQueue.run_frei(
        fn ->
          with {:ok, eingabe} <- Frage.Eingabe.aus_repo(campaign_id, frage) do
            Frage.laufen(eingabe, opts)
          end
        end,
        label: "frage:#{String.slice(lauf_id, 0, 8)}"
      )

    case ergebnis do
      {:belegt, label} ->
        melden.({:frage_fehler, lauf_id, {:belegt, label}})

      {:ok, %{antwort: nil}} ->
        melden.({:frage_fehler, lauf_id, :keine_antwort})

      {:ok, %{antwort: a} = r} ->
        melden.({:frage_fertig, lauf_id, Map.put(a, :runden, r.runden)})

      {:error, grund} ->
        Logger.warning("Frage-Jack: Lauf #{lauf_id} gescheitert: #{inspect(grund)}")
        melden.({:frage_fehler, lauf_id, grund})
    end
  end
end
