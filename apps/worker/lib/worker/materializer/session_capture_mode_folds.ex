defmodule Worker.Materializer.SessionCaptureModeFolds do
  @moduledoc """
  Issue #987 (Nachtrag zu #985): der `SessionCaptureModeSet`-Fold —
  Schwester-Modul von `Worker.Materializer.Apply2` (God-Module-Budget),
  dort nur eine Dünn-Dispatch-Klausel (Muster `DiscordConfigFolds`).

  1 Row/Session (`worker_session_capture_modes`), LWW via fold_meta-Sidecar.
  Die eigentliche Exklusivität (Discord XOR Browser-Mikro) wird NICHT hier
  erzwungen — der Fold konvergiert nur deterministisch über mehrere Worker
  hinweg, exakt wie jeder andere LWW-Fold in dieser Codebase. Die
  Caller-Seite (`Worker.Recording.Recorder.choose_capture_mode/2`) prüft den
  aktuell bekannten Zustand VOR dem Publish — ein enges Race zwischen zwei
  gleichzeitigen Klicks verschiedener Modi bleibt ein dokumentiertes,
  akzeptiertes Restrisiko (wie überall sonst in diesem LWW-Modell).
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @doc false
  def session_capture_mode_set(payload, ts, meta) do
    sid = payload["session_id"]
    cid = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not (is_binary(sid) and is_binary(cid)) ->
        Logger.warning(
          "SessionCaptureModeSet: bad session_id/campaign_id (#{inspect(sid)}/#{inspect(cid)}) — dropping"
        )

      payload["mode"] not in ["discord", "browser"] ->
        Logger.warning("SessionCaptureModeSet: bad mode (#{inspect(payload["mode"])}) — dropping")

      not fold_supersedes?(S.session_capture_modes(), sid, :session_capture_mode_set, event_id) ->
        :ok

      true ->
        :ok =
          :mnesia.write(
            {S.session_capture_modes(), sid, cid, payload["mode"], payload["set_by"], ts}
          )

        record_fold_winner!(S.session_capture_modes(), sid, :session_capture_mode_set, event_id)
    end
  end
end
