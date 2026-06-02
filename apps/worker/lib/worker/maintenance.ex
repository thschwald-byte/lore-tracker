defmodule Worker.Maintenance do
  @moduledoc """
  Einmalige Wartungs-/Migrations-Operationen, die als benannte Funktion über
  Erlang-Distribution-RPC gegen einen laufenden Worker gefahren werden.

  ## `purge_live/0` (Issue #418)

  Tilgt Alt-`status: :live`-Utterances aus der Mnesia, die vor dem Live-Removal
  (#418, keep-both #394) neben den `confirmed`-Batch-Rows liegen geblieben sind.
  Pro Session wird genau dann ein `LiveUtterancesCleared`-Event publisht (event-
  sourced + replay-durabel), wenn die Session **auch** Batch-Rows hat — Sessions
  mit nur live-Rows (kein Batch-Re-Pass gelaufen) werden zum Schutz vor
  Datenverlust übersprungen + geloggt.

  **Kanonischer Pfad (laufender Daemon):** per RPC, weil der Daemon die Mnesia
  exklusiv hält (Schema-Lock — kein zweiter BEAM auf demselben Dir):

      :rpc.call(:"worker_prod@<host>", Worker.Maintenance, :purge_live, [])

  Für einen gestoppten Worker / Dev-Mnesia geht auch `mix lore.purge_live`.
  """

  require Logger

  alias Worker.{Repo, Intents}

  @doc """
  Publisht `LiveUtterancesCleared` für jede Session mit live+batch-Rows.
  Gibt `%{cleared_sessions, cleared_utterances, orphan_sessions}` zurück.
  """
  @spec purge_live() :: %{
          cleared_sessions: non_neg_integer(),
          cleared_utterances: non_neg_integer(),
          orphan_sessions: non_neg_integer()
        }
  def purge_live do
    %{clearable: clearable, orphan: orphan} = Repo.live_purge_plan()

    for {sid, n} <- orphan do
      Logger.warning(
        "purge_live: session=#{sid} hat #{n} live-Utterance(s) aber KEINE Batch-Rows — " <>
          "übersprungen (kein Datenverlust). Pipeline für die Session neu laufen lassen, dann erneut purgen."
      )
    end

    {sessions, total} =
      Enum.reduce(clearable, {0, 0}, fn {sid, n}, {s_acc, t_acc} ->
        case Intents.publish(%{
               "kind" => Shared.Events.live_utterances_cleared(),
               "session_id" => sid
             }) do
          {:ok, _seq} ->
            {s_acc + 1, t_acc + n}

          err ->
            Logger.warning(
              "purge_live: LiveUtterancesCleared publish failed for session=#{sid}: #{inspect(err)}"
            )

            {s_acc, t_acc}
        end
      end)

    Logger.info(
      "purge_live: #{total} live-Utterance(s) in #{sessions} Session(s) getilgt; " <>
        "#{length(orphan)} orphan-Session(s) übersprungen"
    )

    %{cleared_sessions: sessions, cleared_utterances: total, orphan_sessions: length(orphan)}
  end
end
