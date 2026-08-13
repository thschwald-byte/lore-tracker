defmodule Worker.Recording.Stage1Status do
  @moduledoc """
  Stage-1-Status-Meldung + Fehler-Taxonomie (herausgelöst aus
  `Worker.Recording.Transcribe`, Issue #979 — God-Module-Grenze #544; derselbe
  Schnitt wie `Pipeline` → `ErrorClass` in #1008).

  `notify/3` ist die EINE Melde-Stelle der Stage 1: Live-Status für Dashboard/
  CampaignLive (`pipeline_stage`-Payload) + bei `"failed"` der persistierte
  `/admin/errors`-Eintrag. `classify/1` mappt die Whisper-/ffmpeg-Fehler-Strings
  heuristisch auf `error_type`-Codes — String-Matching, weil an dieser Stelle
  nur das `error_msg`-Binary vorliegt (kein strukturierter Atom).
  """

  # Issue #249: Dashboard- und CampaignLive-Indikator für aktive Stage-1-
  # Transkription. Pattern analog zu `Worker.Recording.Pipeline.notify_status/4`
  # — Payload-Shape (`kind=pipeline_stage`, stage="stage1") identisch, damit
  # die Hub-Side ohne Extra-Verdrahtung mitlesen kann.
  def notify(nil, _status, _err), do: :ok

  def notify(campaign_id, status, error_msg) do
    payload =
      %{
        "kind" => "pipeline_stage",
        "campaign_id" => campaign_id,
        "stage" => "stage1",
        "status" => status,
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> then(fn p -> if error_msg, do: Map.put(p, "error", error_msg), else: p end)

    Worker.HubClient.publish_status(payload)
    Phoenix.PubSub.broadcast(Worker.PubSub, "pipeline_status", {:pipeline_stage, payload})

    # Issue #68 Phase 3 (Stage-1-Coverage): Persistierter Error-Log analog zu
    # Pipeline-Stage-2-4 (`Worker.Recording.Pipeline.publish_pipeline_error/5`),
    # damit Stage-1-Whisper-Fehler im /admin/errors-Dashboard auftauchen.
    if status == "failed" and is_binary(error_msg) do
      publish_error(campaign_id, error_msg)
    end
  end

  defp publish_error(campaign_id, error_msg) do
    payload = %{
      "kind" => Shared.Events.pipeline_error_logged(),
      "error_id" => UUIDv7.generate(),
      "session_id" => nil,
      "campaign_id" => campaign_id,
      "stage" => "stage1",
      "error_type" => classify(error_msg),
      "message" => error_msg,
      "context" => %{},
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Issue #430: Intents.publish/1 gibt immer {:ok, …} (kein toter {:error}-Branch).
    {:ok, _} = Worker.Intents.publish(payload)
    :ok
  end

  # Issue #68 Phase 3: Heuristisches Mapping von Whisper-Error-Strings auf
  # `error_type`-Codes. In `notify_stage1` haben wir nur das `error_msg`-binary
  # (kein strukturierter atom), daher Pattern-Match per `String.contains?`.
  def classify(msg) when is_binary(msg) do
    cond do
      String.contains?(msg, "Sidecar offline") ->
        "whisper_sidecar_offline"

      String.contains?(msg, "whisper-cli") and String.contains?(msg, "enoent") ->
        "whisper_binary_missing"

      # Issue #784: whisper_bin/ffmpeg_bin nicht konfiguriert (:no_default, kein
      # hartcodierter Fallback mehr) — die Guards liefern diese Atome direkt.
      String.contains?(msg, "whisper_binary_missing") ->
        "whisper_binary_missing"

      String.contains?(msg, "ffmpeg_binary_missing") ->
        "ffmpeg_binary_missing"

      # Issue #979: undecodierbares/leeres WAV nach dem Convert bzw. fehlende
      # Quell-webm — VOR den generischen whisper-Zweigen, damit die echte
      # Ursache nicht als "whisper_failed" mit VAD-Hilfetext-Rauschen erscheint.
      String.contains?(msg, "wav_decode_failed") ->
        "wav_decode_failed"

      String.contains?(msg, "source_webm_missing") ->
        "source_webm_missing"

      # Issue #470: whisper/ffmpeg/vad-Timeout — Prozess hart gekillt, Slot frei.
      String.contains?(msg, "timeout") ->
        "stage1_timeout"

      String.contains?(msg, "model") and String.contains?(msg, "not found") ->
        "whisper_model_missing"

      String.contains?(msg, "whisper_failed") ->
        "whisper_failed"

      String.contains?(msg, "whisper_empty") ->
        "whisper_empty"

      String.contains?(msg, "whisper_exception") ->
        "whisper_failed"

      true ->
        "whisper_failed"
    end
  end

  def classify(_), do: "whisper_failed"
end
