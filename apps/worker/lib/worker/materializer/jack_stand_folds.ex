defmodule Worker.Materializer.JackStandFolds do
  @moduledoc """
  J4 (#1207): der `JackStandAbgelegt`-Fold — Schwester-Modul von
  `Worker.Materializer.Apply2` (God-Module-Budget), dort nur eine
  Dünn-Dispatch-Klausel.

  1 Row/Session (`worker_jack_staende`): Jacks Stand nach seinem letzten Lauf,
  damit „noch N Iterationen“ auf jedem Worker weitermachen kann (Tom,
  11.09.2026). Whole-Snapshot ⇒ Voll-Ersatz, LWW inline über die
  `event_id`-Spalte (Muster `TranscriptSmoothed`): nur der letzte Stand
  zählt. Kodiert wird erst hier — der Payload reist als Map, ein vorkodierter
  String würde im Kanal ein zweites Mal escaped.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @doc false
  def jack_stand_abgelegt(payload, ts, meta) do
    sid = payload["session_id"]
    cid = payload["campaign_id"]
    stand = payload["stand"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(sid) and is_binary(cid)) ->
        Logger.warning(
          "JackStandAbgelegt: bad session_id/campaign_id (#{inspect(sid)}/#{inspect(cid)}) — dropping"
        )

      not is_map(stand) ->
        Logger.warning("JackStandAbgelegt: kein stand für session=#{sid} — dropping")

      not event_id_supersedes?(event_id, bestehende_event_id(sid)) ->
        :ok

      true ->
        :ok = :mnesia.write({S.jack_staende(), sid, cid, Jason.encode!(stand), ts, event_id})
    end
  end

  defp bestehende_event_id(sid) do
    case :mnesia.read(S.jack_staende(), sid) do
      [row] when tuple_size(row) >= 6 -> elem(row, 5)
      _ -> nil
    end
  end
end
