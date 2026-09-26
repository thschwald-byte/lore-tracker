defmodule Worker.Agent.Laeufe do
  @moduledoc """
  Wer gerade einen Agentenlauf fährt (#1259).

  **Der Anlass ist ein Prod-Vorfall.** Am 26.09.2026 um 12:06 löste ein
  Hub-Deploy auf `worker_prod` das Selbstupdate aus, und der Updater hielt den
  Node mitten in einem 50-minütigen Zeit-Jack-Lauf. `Updater.idle?/0` prüfte
  Aufnahme, Replay, GPU-Warteschlange und Pipeline — **keines davon sieht einen
  Jack, der nicht innerhalb der Pipeline läuft**. Live gemessen, während der
  Jack rechnete: `Pipeline.busy? == false`, `GpuQueue` leer, `idle? == true`.

  Der Schutz der Jacks hing bis dahin an einem Zufall: `pipeline.ex` wickelt
  den **ganzen** Pipeline-Lauf in `GpuQueue.run/2`, und dadurch waren die Jacks
  darin mit abgedeckt. In `worker/jack/` und `worker/agent/` gibt es keinen
  einzigen `GpuQueue`-Aufruf — wer einen Jack von Hand fährt
  (`Zeit.Pipeline.einordnen`, `Epos.Pipeline.schreiben/3`, die Messläufe; alle
  in CLAUDE.md als Weg genannt), lief ungeschützt.

  **Angemeldet wird in `Worker.Agent.laufen/1`**, dem einen Punkt, durch den
  jeder Lauf geht — nicht bei den Aufrufern. Läge es dort, müsste jeder
  Einstieg es kennen, und der eine, der es vergisst, ist wieder ungeschützt.
  Genau diese Lehre steht in CLAUDE.md an drei Stellen (#1153, #1204, #1090).

  **Eine Registry, kein Zähler.** Der Eintrag hängt am Prozess: Stirbt der
  Lauf — Absturz, Abbruch, harter Kill —, verschwindet er von selbst. Ein
  Zähler, den ein abgestürzter Lauf nicht herunterzählt, hielte das Update
  **für immer** auf, und das wäre schlimmer als der Vorfall, gegen den er
  gebaut ist.

  **Best-effort in beide Richtungen.** Läuft die Registry nicht (Messlauf per
  `mix`, Test ohne Anwendungsbaum), darf ein Lauf daran nicht scheitern —
  `anmelden/1` schluckt das. `anzahl/0` liefert dann 0: Ohne Registry gibt es
  keinen registrierten Lauf, und ein erfundenes „busy" blockierte das Update
  auf jeder Maschine ohne laufenden Worker.
  """

  @registry __MODULE__.Registry

  @doc "Der Name der Registry für die Supervision."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Meldet den aufrufenden Prozess als laufenden Agentenlauf an. `label` ist
  nur zur Anzeige (`liste/0`).
  """
  @spec anmelden(String.t()) :: :ok
  def anmelden(label) when is_binary(label) do
    _ = Registry.register(@registry, :lauf, label)
    :ok
  catch
    # Registry nicht gestartet (Messlauf, Test) oder schon registriert.
    _, _ -> :ok
  end

  @doc "Meldet den aufrufenden Prozess ab. Die Registry räumt auch ohne das auf."
  @spec abmelden() :: :ok
  def abmelden do
    Registry.unregister(@registry, :lauf)
    :ok
  catch
    _, _ -> :ok
  end

  @doc "Wie viele Agentenläufe gerade laufen."
  @spec anzahl() :: non_neg_integer()
  def anzahl do
    Registry.count(@registry)
  catch
    _, _ -> 0
  end

  @doc "Die Label der laufenden Agentenläufe (für Log und Telemetrie)."
  @spec liste() :: [String.t()]
  def liste do
    @registry |> Registry.lookup(:lauf) |> Enum.map(&elem(&1, 1))
  catch
    _, _ -> []
  end
end
