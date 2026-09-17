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

  J5 (#1209, B4): `JackResuemeeStandAbgelegt` — der Stand des Resümee-Jack
  (`worker_jack_resuemee_staende`), dieselbe Form und dieselbe Regel; nur die
  Tabelle ist eine andere. Seine Notizen lesen spätere Sitzungen als „vorige
  Gedanken“ (`Worker.Jack.Resuemee.Eingabe`).

  J6 (#1210, E4): `JackEposStandAbgelegt` — der Stand des Epos-Jack
  (`worker_jack_epos_staende`), wieder dieselbe Form und Regel. Seine Notizen
  (FORM, SZENEN, ABWEICHUNG, OFFEN) lesen spätere Sitzungen ebenfalls als
  „vorige Gedanken“.
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @doc false
  def jack_stand_abgelegt(payload, ts, meta),
    do: ablegen(S.jack_staende(), "JackStandAbgelegt", payload, ts, meta)

  @doc false
  def jack_resuemee_stand_abgelegt(payload, ts, meta),
    do: ablegen(S.jack_resuemee_staende(), "JackResuemeeStandAbgelegt", payload, ts, meta)

  @doc false
  def jack_epos_stand_abgelegt(payload, ts, meta),
    do: ablegen(S.jack_epos_staende(), "JackEposStandAbgelegt", payload, ts, meta)

  defp ablegen(tabelle, kind, payload, ts, meta) do
    sid = payload["session_id"]
    cid = payload["campaign_id"]
    stand = payload["stand"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(sid) and is_binary(cid)) ->
        Logger.warning(
          "#{kind}: bad session_id/campaign_id (#{inspect(sid)}/#{inspect(cid)}) — dropping"
        )

      not is_map(stand) ->
        Logger.warning("#{kind}: kein stand für session=#{sid} — dropping")

      not event_id_supersedes?(event_id, bestehende_event_id(tabelle, sid)) ->
        :ok

      true ->
        :ok = :mnesia.write({tabelle, sid, cid, Jason.encode!(stand), ts, event_id})
    end
  end

  defp bestehende_event_id(tabelle, sid) do
    case :mnesia.read(tabelle, sid) do
      [row] when tuple_size(row) >= 6 -> elem(row, 5)
      _ -> nil
    end
  end
end
