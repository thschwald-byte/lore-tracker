defmodule Worker.PipelineErrorLog do
  @moduledoc """
  Issue #605: Retention/Prune fuer die `worker_pipeline_errors`-Tabelle.

  `Worker.Materializer` schreibt pro `PipelineErrorLogged`-Event eine Row;
  gelesen wird nur via `Worker.Repo.last_n_pipeline_errors/1` fuer
  `/admin/errors`. Append-only ohne Cap → bei mehrtaegigem `worker_prod`-
  Daemon und flakigem LLM-Backend waechst die Tabelle monoton an.

  Strategie: **Keep-last-N**. Nach jedem Trim haelt die Tabelle hoechstens
  N Rows (Default 1000 via `Worker.Settings.get(:pipeline_errors_keep_n)`),
  sortiert nach `occurred_at` desc. `last_n_pipeline_errors/1`-UI ist davon
  unberuehrt — sie liest auf demselben Sort und nimmt das Top-N.

  Trigger:

  - **Boot** — `prune_keep_last/0` einmal aus `Worker.Application.start/2`
    nach `bootstrap_storage!`. Synchron, schnell (Tabelle wird mit dem
    Cap klein gehalten).
  - **Periodisch** — `Worker.PipelineErrorLog.Pruner` (Mini-GenServer
    im Application-Tree). `Process.send_after`-Loop alle
    `:pipeline_errors_prune_interval_ms` (Default 1h).

  Multi-Worker-Konvergenz: pipeline_errors ist **worker-lokal** (nicht
  Teil des Gossip-EventLogs), prune-Differenzen zwischen Workern sind
  irrelevant. Anders als bei `Worker.EventLog` (#97) braucht es hier
  keinen signierten Prune-Event.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  @doc """
  Trimmt `worker_pipeline_errors` auf hoechstens `n` Rows (Default aus
  Settings). Sortiert nach `occurred_at` desc, behaelt das Top-`n`, loescht
  den Rest in EINER Transaktion. Returns `{:ok, %{kept: k, deleted: d}}`.
  """
  @spec prune_keep_last(pos_integer() | nil) ::
          {:ok, %{kept: non_neg_integer(), deleted: non_neg_integer()}}
  def prune_keep_last(n \\ nil) do
    keep = n || Worker.Settings.get(:pipeline_errors_keep_n, 1000)
    table = S.pipeline_errors()

    {:atomic, result} =
      :mnesia.transaction(fn ->
        rows =
          :mnesia.match_object({table, :_, :_, :_, :_, :_, :_, :_, :_})

        total = length(rows)

        if total <= keep do
          %{kept: total, deleted: 0}
        else
          to_delete =
            rows
            |> Enum.sort_by(&sort_key/1)
            |> Enum.drop(keep)

          Enum.each(to_delete, fn row ->
            :mnesia.delete({table, elem(row, 1)})
          end)

          %{kept: total - length(to_delete), deleted: length(to_delete)}
        end
      end)

    if result.deleted > 0 do
      Logger.info(
        "Worker.PipelineErrorLog: prune_keep_last(#{keep}) — " <>
          "kept=#{result.kept}, deleted=#{result.deleted}"
      )
    end

    {:ok, result}
  end

  # Sort by occurred_at DESC: negate the unix-microseconds so the newest
  # row sorts first. Non-DateTime rows (Altdaten) go to the end and get
  # pruned first.
  defp sort_key({_, _id, %DateTime{} = ts, _, _, _, _, _, _}),
    do: -DateTime.to_unix(ts, :microsecond)

  defp sort_key(_), do: 0
end
