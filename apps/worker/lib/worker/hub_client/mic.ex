defmodule Worker.HubClient.Mic do
  @moduledoc """
  Issue #585: Mic/Recording-Topic-Bündel aus `Worker.HubClient`.

  - `start_recording` — UI-Trigger via Recorder.start_for_owner/3 (Issue #355: 3-Tuple-Error)
  - `audio_chunk` — Audio-Frame in AudioBuffer.append/3
  - `mic_leave` — graceful Streamer-Removal (Issue #392)
  - `stop_recording` — Recorder.stop_for_campaign/1 + Fallback-SessionEnded-Logik (Issue #233)
  - `transcribe_clip_request` — Mic-Setup-Phrasen-Transkription (Issue #400)
  """

  require Logger

  alias Worker.HubClient

  def on_start_recording(%{"discord_id" => did, "campaign_id" => cid} = payload, socket) do
    # Issue #19: "single_source" = Tisch-Raummikro (Diarisierung post-session).
    # Fehlt das Feld (Version-Skew während Deploy), fällt's auf :default zurück.
    mode = if payload["mode"] == "single_source", do: :single_source, else: :default

    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Recording.Recorder.start_for_owner(did, cid, mode) do
        {:ok, info} ->
          Logger.info(
            "HubClient: UI-triggered recording started session=#{info.session_id} mode=#{mode}"
          )

        # Issue #355 cleanup: Recorder returnt {:error, :already_recording,
        # existing_info} als 3-Tuple — vorher hat der 2-Tuple-only Match das
        # crashing-loop'd (siehe Worker-Log-Floods bei Doppelklick auf
        # rec_start). Jetzt: warning + Existing-Session-ID loggen.
        {:error, :already_recording, existing} ->
          Logger.warning(
            "HubClient: UI start_recording rejected — already recording session=#{existing.session_id} campaign=#{existing.campaign_id}"
          )

        {:error, reason} ->
          Logger.warning("HubClient: UI start_recording failed: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  def on_audio_chunk(
        %{"session_id" => sid, "discord_id" => did, "chunk" => chunk},
        socket
      ) do
    Worker.Recording.AudioBuffer.append(sid, did, chunk)
    {:ok, socket}
  end

  # Issue #392: graceful Mic-Stop vom Hub (expliziter Stop-Button). Entfernt
  # den Streamer sofort aus der Presence statt auf den Chunk-Recency-Sweep
  # (~4s) zu warten.
  def on_mic_leave(%{"session_id" => sid, "discord_id" => did}, socket) do
    Worker.Recording.AudioBuffer.drop_streamer(sid, did)
    {:ok, socket}
  end

  def on_stop_recording(%{"campaign_id" => cid}, socket) do
    Task.Supervisor.start_child(Worker.TaskSupervisor, fn ->
      case Worker.Recording.Recorder.stop_for_campaign(cid) do
        {:ok, info} ->
          Logger.info("HubClient: UI-triggered recording stopped session=#{info.session_id}")

        {:error, :not_recording} ->
          # Recorder doesn't have an entry — could be either:
          # (a) Worker restarted while a session was active → AudioBuffer hat
          #     auch nichts pending → wir publishen Fallback-SessionEnded
          #     damit die UI nicht hängen bleibt.
          # (b) Race-Window: Recorder hat State schon gepoppt, AudioBuffer.
          #     finalize hat den Transcribe-Task gestartet, der publisht das
          #     echte SessionEnded selber wenn Stage 1 durch ist. KEIN Fallback
          #     in diesem Fall (Issue #233 — Doppel-SessionEnded triggerte die
          #     Pipeline doppelt mit halbem Transcript).
          handle_no_recorder_entry(cid)

        {:error, reason} ->
          Logger.warning("HubClient: UI stop_recording failed: #{inspect(reason)}")
      end
    end)

    {:ok, socket}
  end

  # Issue #400: Mic-Setup-Phrase-Clip transkribieren. Kein Session-Kontext,
  # kein Initial-Prompt — der Hub vergleicht den rohen ASR-Output gegen die
  # erwartete Test-Phrase. Fehler (undecodebare Base64, ffmpeg/whisper) →
  # leerer Text, der Hub behandelt das als Fehlschlag + lässt erneut lauschen.
  def on_transcribe_clip_request(
        %{"request_id" => rid, "chunk" => b64, "discord_id" => did},
        socket
      ) do
    text =
      with {:ok, bin} <- Base.decode64(b64),
           {:ok, t} <- Worker.Recording.Transcribe.transcribe_clip(bin) do
        t
      else
        :error ->
          Logger.warning("HubClient: transcribe_clip_request mit undecodebarer Base64")
          ""

        {:error, reason} ->
          Logger.warning("HubClient: transcribe_clip fehlgeschlagen: #{inspect(reason)}")
          ""
      end

    HubClient.push_event(socket, "transcribe_clip_response", %{
      request_id: rid,
      text: text,
      discord_id: did
    })

    {:ok, socket}
  end

  defp handle_no_recorder_entry(cid) do
    case Worker.Repo.active_session_for(cid) do
      nil ->
        Logger.warning("HubClient: UI stop with no Recorder entry and no active session")

      session ->
        if Worker.Recording.AudioBuffer.has_pending_transcribe?(session.id) do
          Logger.info(
            "HubClient: UI stop_recording during Transcribe — let Transcribe.run publish SessionEnded for session=#{session.id}"
          )
        else
          Logger.warning(
            "HubClient: Recorder has no entry; fallback SessionEnded for session=#{session.id}"
          )

          {:ok, _} =
            Worker.Intents.publish(%{
              "kind" => Shared.Events.session_ended(),
              "id" => session.id
            })
        end
    end
  end
end
