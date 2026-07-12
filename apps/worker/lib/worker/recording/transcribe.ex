defmodule Worker.Recording.Transcribe do
  @moduledoc """
  Stage 1: convert per-speaker recording files to text via `whisper-cli`.

  Input: list of `{discord_id, webm_path}` from `AudioBuffer.finalize/1`.
  For each file: convert webm/opus → 16k mono WAV via `ffmpeg`, run
  whisper-cli with `-ojf` (Full-JSON, Issue #376) to get a JSON transcript
  inkl. Per-Token-Probabilities, parse segments, und emit ein
  `UtteranceAppended` Event pro nicht-leerem Segment mit aggregierter
  Confidence (`%{"mean_p" => f, "min_p" => f}`).

  After all files have been processed, emit `SessionEnded` so the
  pipeline (stages 2-4) sees a complete transcript.

  Env-driven config:
  - `:whisper_bin`   (kein Default seit #784 — in `/settings` setzen, z.B. `whisper-cli`)
  - `:whisper_model` (Default via `Worker.Settings.whisper_model_fallback/0`)
  - `:whisper_lang`  (default `auto`)
  - `:ffmpeg_bin`    (kein Default seit #784 — in `/settings` setzen, z.B. `ffmpeg`)
  - `:whisper_timeout_ms` / `:ffmpeg_timeout_ms` / `:vad_timeout_ms`
    (Issue #470) — Prozess-Timeouts für die externen Tools; bei Überschreitung
    wird der Prozess hart gekillt statt den GpuQueue-Slot dauerhaft zu blockieren.
  """

  require Logger

  alias Worker.Intents
  alias Worker.Recording.Transcribe.Confidence

  # Issue #791: die reinen Confidence-/Halluzinations-/Dedup-Value-Transformer
  # wohnen jetzt in Worker.Recording.Transcribe.Confidence (God-Module-Split
  # #544, Worker.Repo-#719-Muster). defdelegate-Fassade hält die Call-Sites
  # stabil — externe Aufrufer (Probelauf, BenchReader, PromptBuilder, Tests)
  # UND die internen (transcribe_one, emit_utterances, read_segments) nutzen
  # dieselben unqualifizierten Namen weiter.
  defdelegate dedupe_consecutive(segments), to: Confidence
  defdelegate filter_hallucinations(segments), to: Confidence
  defdelegate hallucination?(text), to: Confidence
  defdelegate aggregate_token_confidence(tokens), to: Confidence
  defdelegate to_confidence_map(value), to: Confidence

  @doc """
  Per-Spieler-Batch-Transkription (eine Datei pro discord_id). Dünner Wrapper
  auf `run_mixed/3` (Issue #642).
  """
  def run(session_id, files), do: run_mixed(session_id, files, [])

  @doc """
  Issue #19: Single-Source-Transkription. Eine kombinierte WebM-Datei wird
  diarisiert (pyannote-Sidecar) + per-Segment transkribiert, Utterances mit
  Pseudo-Sprecher-Label (`speaker:<session_id>:<n>`) statt discord_id. Dünner
  Wrapper auf `run_mixed/3` (Issue #642).
  """
  def run_single_source(session_id, webm_path),
    do: run_mixed(session_id, [], [{"single_source", webm_path}])

  @doc """
  Issue #642: gemischte Stage-1-Transkription für EINE Session. `per_player_files`
  (`[{discord_id, path}]`) werden je discord_id transkribiert; `multi_files`
  (`[{key, path}]`, je ein Raummikro-Gerät) werden diarisiert + als Pseudo-
  Sprecher emittiert. Beide Pfade emittieren `UtteranceAppended`-Events; **genau
  ein** `UtterancesTranscribed` (mit Gesamt-Count) wird am Ende publisht — sonst
  würde die Pipeline (Stage 2-4) pro Pfad einmal triggern (doppelte LLM-Kosten).

  Mehrere Raummikro-Files in einer Session: die Pseudo-Sprecher-Labels
  (`speaker:<sid>:<n>`) sind pro Diarisierungs-Lauf nummeriert → bei >1 Raummikro
  können Indizes kollidieren (zwei physische Sprecher, gleiches Label). Bekannte
  v1-Grenze; der GM ordnet ohnehin manuell via `SpeakerAssigned` zu.
  """
  def run_mixed(session_id, per_player_files, multi_files) do
    campaign_id = resolve_campaign_id(session_id)
    notify_stage1(campaign_id, "started", nil)

    try do
      started_at = session_started_at(session_id)

      pp_count =
        transcribe_per_player_files(session_id, campaign_id, per_player_files, started_at)

      ms_count =
        Enum.reduce(multi_files, 0, fn {key, path}, acc ->
          acc + transcribe_single_source_file(session_id, campaign_id, key, path, started_at)
        end)

      count = pp_count + ms_count

      Logger.info(
        "Transcribe: session=#{session_id} → #{count} utterances (per_player=#{pp_count}, multi=#{ms_count})"
      )

      # Issue #355: SessionEnded firet bereits beim Recording-Stop in
      # AudioBuffer.finalize. Hier EIN `UtterancesTranscribed`, das die Pipeline
      # (Stage 2-4) genau einmal triggert — auch bei gemischten Files.
      {:ok, _} =
        Intents.publish(%{
          "kind" => Shared.Events.utterances_transcribed(),
          "session_id" => session_id,
          "campaign_id" => campaign_id,
          "utterance_count" => count
        })

      notify_stage1(campaign_id, "ended", nil)
      :ok
    rescue
      e ->
        notify_stage1(campaign_id, "failed", Exception.message(e))
        reraise e, __STACKTRACE__
    end
  end

  # Per-Spieler-Files → je discord_id eine Spur. Liefert die Utterance-Anzahl.
  defp transcribe_per_player_files(_session_id, _campaign_id, [], _started_at), do: 0

  defp transcribe_per_player_files(session_id, campaign_id, files, started_at) do
    # Issue #469: der `flat_key` aus `AudioBuffer` kann jetzt `<did>` ODER
    # `<did>.<seg>` (rotierte Segmente) sein. Der eigentliche Speaker (für
    # UtteranceAppended-Discord-ID) ist der Base-Part vor dem ersten Punkt —
    # jedes Segment wird als eigene File transkribiert, seine Utterances
    # bekommen aber die Base als discord_id. Timestamps kommen weiter aus
    # dem per-Segment Sidecar (#757, `manifest_key = flat_key`).
    files
    |> Enum.map(fn {flat_key, path} ->
      transcribe_one(session_id, campaign_id, base_did(flat_key), path, started_at)
    end)
    |> Enum.sum()
  end

  # Issue #469: "did-alice.1" → "did-alice"; "did-alice" → "did-alice". Erlaubt
  # Discord-IDs mit Punkten nicht (Discord-IDs sind rein numerisch — kein
  # realer Kollisionsfall).
  defp base_did(flat_key) do
    flat_key
    |> String.split(".", parts: 2)
    |> hd()
  end

  # Eine Raummikro-Datei: WAV → Diarisierung → per-Segment-Whisper → Pseudo-
  # Sprecher-Utterances. Liefert die Anzahl; bei Sidecar-/Convert-Fehler 0
  # (loggt + notify_stage1 "failed", der per-Spieler-Count bleibt unberührt).
  # Issue #304: gar kein Whisper-Prompt (kurze Slices → Prompt blutet).
  defp transcribe_single_source_file(session_id, campaign_id, key, webm_path, started_at) do
    opts = [
      session_id: session_id,
      campaign_id: campaign_id,
      discord_id: "single_source",
      no_prompt: true
    ]

    with {:ok, wav_path} <- to_wav(webm_path, "single_source"),
         {:ok, diar_segments} <- diarize(wav_path, campaign_id),
         {:ok, whisper_segments} <- transcribe_wav(wav_path, opts) do
      # Issue #298: Whisper EINMAL über die volle Spur; jedes Segment dem
      # Sprecher-Turn mit größtem Zeit-Overlap zuordnen.
      whisper_segments
      |> filter_hallucinations()
      |> assign_speakers(diar_segments, session_id)
      |> emit_by_speaker(session_id, started_at, key, webm_path)
    else
      {:error, :sidecar_offline} ->
        Logger.error(
          "Transcribe: single_source session=#{session_id} — Diarisierungs-Sidecar offline, keine Sprecher-Trennung möglich"
        )

        notify_stage1(campaign_id, "failed", "Diarisierungs-Sidecar offline")
        0

      {:error, reason} ->
        Logger.error(
          "Transcribe: single_source session=#{session_id} diarize/convert failed: #{inspect(reason)}"
        )

        notify_stage1(campaign_id, "failed", inspect(reason))
        0
    end
  end

  @doc """
  Issue #400: einen kurzen WebM-Clip (vom Mic-Setup-Phrase-Test) ad-hoc
  transkribieren — ohne Session-Kontext, ohne Initial-Prompt, ohne
  Hallucination-Filter (der Setup-Vergleich braucht den rohen ASR-Output,
  inkl. eventueller Slips, um den Wort-Overlap fair zu messen).

  Nimmt das rohe WebM-Binary, schreibt es in eine Temp-Datei, konvertiert
  nach 16-kHz-Mono-WAV und jagt es per `whisper-cli` durch. Fügt die
  Segment-Texte zusammen und gibt `{:ok, text}` zurück (Temp-Dateien werden
  in jedem Fall aufgeräumt). Bei Konvertierungs-/Transkriptions-Fehlern
  `{:error, reason}` — der Hub behandelt das wie leeren Text (Retry).
  """
  @spec transcribe_clip(binary()) :: {:ok, String.t()} | {:error, term()}
  def transcribe_clip(webm_binary) when is_binary(webm_binary) and byte_size(webm_binary) > 0 do
    tmp_base = Path.join(System.tmp_dir!(), "lore_clip_#{:erlang.unique_integer([:positive])}")
    webm_path = tmp_base <> ".webm"

    try do
      with :ok <- File.write(webm_path, webm_binary),
           {:ok, wav_path} <- to_wav(webm_path, "mic_setup"),
           {:ok, segments} <- transcribe_wav(wav_path, no_prompt: true) do
        text =
          segments
          |> Enum.map(fn seg -> seg |> Map.get("text", "") |> String.trim() end)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")
          |> String.trim()

        {:ok, text}
      end
    after
      File.rm(webm_path)
      File.rm(tmp_base <> ".wav")
    end
  end

  def transcribe_clip(_), do: {:error, :invalid_clip}

  defp diarize(wav_path, campaign_id) do
    hint = num_speakers_hint(campaign_id)
    opts = if hint, do: [num_speakers: hint], else: []
    Worker.Recording.Diarize.run(wav_path, opts)
  end

  # num_speakers-Hint reduziert pyannote-Clustering-Fehler (TTRPG-Audio hat
  # hohe Confusion-Rate). Override via Setting; sonst aus Member-Count — aber
  # NUR ab 2 Membern. Bei 0/1 Membern ist der Count kein verlässliches Signal
  # (Solo-GM-Test, oder Mitspieler sind noch nicht beigetreten) und würde
  # pyannote fälschlich auf 1 Sprecher zwingen → keine Trennung. Dann lieber
  # Auto-Detect (nil) und der GM korrigiert per Picker.
  defp num_speakers_hint(campaign_id) do
    case Worker.Settings.get(:diarization_num_speakers) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case campaign_id && Worker.Repo.list_members(campaign_id) do
          members when is_list(members) and length(members) >= 2 -> length(members)
          _ -> nil
        end
    end
  end

  # Issue #298: ordnet jedes Whisper-Segment dem Diarisierungs-Turn mit größtem
  # zeitlichem Overlap zu → [{speaker_ref, whisper_seg}, ...].
  defp assign_speakers(whisper_segments, diar_segments, session_id) do
    Enum.map(whisper_segments, fn seg ->
      label = best_speaker_label(seg, diar_segments)
      {"speaker:#{session_id}:#{speaker_label_to_index(label)}", seg}
    end)
  end

  defp best_speaker_label(_seg, []), do: "SPEAKER_00"

  defp best_speaker_label(seg, diar_segments) do
    ws = seg["offset_ms"] || 0
    we = max(seg["end_ms"] || ws, ws)
    best = Enum.max_by(diar_segments, fn d -> overlap_ms(ws, we, d.start_ms, d.end_ms) end)

    if overlap_ms(ws, we, best.start_ms, best.end_ms) > 0 do
      best.speaker_label
    else
      # kein Overlap (Segment in einer Lücke) → nächstgelegener Turn am Start.
      Enum.min_by(diar_segments, fn d -> abs(d.start_ms - ws) end).speaker_label
    end
  end

  defp overlap_ms(a_s, a_e, b_s, b_e), do: max(0, min(a_e, b_e) - max(a_s, b_s))

  # Gruppiert die zugeordneten Segmente pro Sprecher und emittiert sie.
  # emit_utterances rechnet Timestamps absolut aus offset_ms → Gruppen-
  # Reihenfolge egal, das Protokoll sortiert beim Lesen chronologisch.
  # Alle Diarisierungs-Gruppen teilen sich denselben `webm_path`/`manifest_key`
  # (eine Raummikro-Datei) — der Sidecar (Issue #757) wird von emit_utterances
  # daraus geladen, dieselbe Datei je Sprecher-Gruppe, das ist ok.
  defp emit_by_speaker(assigned, session_id, started_at, manifest_key, webm_path) do
    assigned
    |> Enum.group_by(fn {ref, _} -> ref end, fn {_, seg} -> seg end)
    |> Enum.reduce(0, fn {ref, segs}, acc ->
      acc + emit_utterances(session_id, ref, segs, started_at, manifest_key, webm_path)
    end)
  end

  # "SPEAKER_00" → 0, "SPEAKER_12" → 12. Fallback auf 0 bei unerwartetem Format.
  defp speaker_label_to_index(label) when is_binary(label) do
    case label |> String.split("_") |> List.last() |> Integer.parse() do
      {n, _} -> n
      :error -> 0
    end
  end

  defp speaker_label_to_index(_), do: 0

  defp resolve_campaign_id(session_id) do
    case Worker.Repo.get_session(session_id) do
      %{campaign_id: cid} -> cid
      _ -> nil
    end
  end

  # Issue #249: Dashboard- und CampaignLive-Indikator für aktive Stage-1-
  # Transkription. Pattern analog zu `Worker.Recording.Pipeline.notify_status/4`
  # — Payload-Shape (`kind=pipeline_stage`, stage="stage1") identisch, damit
  # die Hub-Side ohne Extra-Verdrahtung mitlesen kann.
  defp notify_stage1(nil, _status, _err), do: :ok

  defp notify_stage1(campaign_id, status, error_msg) do
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
      publish_stage1_error(campaign_id, error_msg)
    end
  end

  defp publish_stage1_error(campaign_id, error_msg) do
    payload = %{
      "kind" => Shared.Events.pipeline_error_logged(),
      "error_id" => UUIDv7.generate(),
      "session_id" => nil,
      "campaign_id" => campaign_id,
      "stage" => "stage1",
      "error_type" => classify_stage1_error(error_msg),
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
  defp classify_stage1_error(msg) when is_binary(msg) do
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

  defp classify_stage1_error(_), do: "whisper_failed"

  # ─── per-file ────────────────────────────────────────────────────

  defp transcribe_one(session_id, campaign_id, discord_id, webm_path, started_at) do
    size = file_size(webm_path)

    Logger.info("Transcribe: did=#{discord_id} file=#{Path.basename(webm_path)} size=#{size}")

    if size < 256 do
      Logger.info(
        "Transcribe: skipping #{discord_id} (size=#{size} bytes — likely no real audio)"
      )

      0
    else
      with {:ok, wav_path} <- to_wav(webm_path, discord_id),
           {:ok, segments} <-
             transcribe_wav(wav_path,
               session_id: session_id,
               campaign_id: campaign_id,
               discord_id: discord_id
             ) do
        filtered = filter_hallucinations(segments)
        dropped_hal = length(segments) - length(filtered)

        if dropped_hal > 0 do
          Logger.info(
            "Transcribe: did=#{discord_id} dropped #{dropped_hal} hallucination segment(s)"
          )
        end

        # Issue #757/#469: der Sidecar-Key ist der Datei-Basename ohne
        # `.webm` — für unrotierte Files == `discord_id`, für rotierte Files
        # `<did>.<seg>`. Aus dem `webm_path` ableiten statt aus `discord_id`,
        # damit `emit_utterances` immer den richtigen `.chunks.jsonl` findet.
        emit_utterances(
          session_id,
          discord_id,
          filtered,
          started_at,
          Path.basename(webm_path, ".webm"),
          webm_path
        )
      else
        {:error, reason} ->
          # Issue #704: NICHT mehr still (nur Logger.warning). Der SL muss
          # erfahren, dass eine consent-erteilte Spur ausgefallen ist —
          # notify_stage1 rendert einen Flash in der CampaignLive + einen
          # /admin/errors-Eintrag (PipelineErrorLogged). Zusätzlich wird die
          # gescheiterte webm für einen manuellen Rerun bewahrt.
          who = speaker_display(campaign_id, discord_id)
          msg = "Spur von #{who} nicht transkribiert (#{inspect(reason)})"

          Logger.error(
            "Transcribe: failed for did=#{discord_id} path=#{webm_path}: #{inspect(reason)}"
          )

          notify_stage1(campaign_id, "failed", msg)
          preserve_failed_track(session_id, discord_id, webm_path)
          0
      end
    end
  end

  # Issue #704: best-effort Sprecher-Anzeige für die Fehlermeldung. Fällt nie
  # auf die Nase — ohne campaign_id/Member schlicht die discord_id.
  defp speaker_display(nil, discord_id), do: to_string(discord_id)

  defp speaker_display(campaign_id, discord_id) do
    case Enum.find(
           Worker.Repo.list_members(campaign_id),
           &(to_string(&1.discord_id) == to_string(discord_id))
         ) do
      %{character_name: n} when is_binary(n) and n != "" -> "#{n} (#{discord_id})"
      _ -> to_string(discord_id)
    end
  end

  defp emit_utterances(session_id, discord_id, segments, started_at, manifest_key, webm_path) do
    deduped = dedupe_consecutive(segments)
    dropped = length(segments) - length(deduped)

    if dropped > 0 do
      Logger.info(
        "Transcribe: did=#{discord_id} dropped #{dropped} duplicate segment(s) (whisper repetition)"
      )
    end

    # Issue #757: pro Segment die Wall-Clock aus dem Chunk-Arrival-Sidecar
    # rekonstruieren. `resolve_ctx` lädt Manifest + Dateigröße + geschätzte
    # decodierte Dauer einmal für alle Segmente dieser Datei. Leerer Sidecar /
    # 0-Bytes / 0-Duration → `nil`, `wall_clock_for/3` fällt dann auf
    # `started_at + offset_ms` zurück (Backwards-Compat für Alt-Sessions).
    resolve_ctx =
      Worker.Recording.ChunkManifest.build_resolve_ctx(webm_path, manifest_key, deduped)

    # Issue #702: EIN gebatchter Publish statt ein Frame pro Segment — der
    # Einzel-Publish-Sturm des Backlogs (1 Broadcast + 1 LV-Diff pro Utterance)
    # war der Hub-OOM-Treiber. Local-Apply bleibt pro Event (publish_batch).
    payloads =
      deduped
      |> Enum.map(fn seg ->
        text = seg |> Map.get("text", "") |> String.trim()

        if text == "" do
          nil
        else
          offset_ms = seg |> Map.get("offset_ms", 0)
          ts = Worker.Recording.ChunkManifest.wall_clock_for(resolve_ctx, offset_ms, started_at)

          %{
            "kind" => Shared.Events.utterance_appended(),
            "id" => UUIDv7.generate(),
            "session_id" => session_id,
            "discord_id" => to_string(discord_id),
            "timestamp" => DateTime.to_iso8601(ts),
            "text" => text,
            "confidence" => Map.get(seg, "confidence"),
            "status" => "confirmed"
          }
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, %{synced: _, pending: _}} = Intents.publish_batch(payloads)

    count = length(payloads)
    Logger.info("Transcribe: did=#{discord_id} emit #{count} utterances (batched)")
    count
  end

  # ─── ffmpeg / whisper-cli ────────────────────────────────────────

  # Issue #704: der externe Kommando-Runner (Port + Orphan-Kill) lebt jetzt in
  # `Worker.Recording.Cmd` (God-Module-Grenze #544 + direkte Testbarkeit).
  defp run_cmd(bin, args, timeout_ms), do: Worker.Recording.Cmd.run(bin, args, timeout_ms)

  defp to_wav(webm_path, discord_id) do
    wav_path = Path.rootname(webm_path) <> ".wav"

    base_args = ["-y", "-loglevel", "error", "-i", webm_path, "-ac", "1", "-ar", "16000"]

    filter_args =
      case Worker.Settings.get(:whisper_audio_filter, "") do
        f when is_binary(f) and f != "" -> ["-af", f]
        _ -> []
      end

    args = base_args ++ filter_args ++ [wav_path]
    start = System.monotonic_time(:millisecond)

    # Issue #704: Timeout wächst mit der Dateigröße (2h-Track = ~100 MB webm,
    # den der 120s-Default reißt). Setting = Floor/Override, per-MB-Term = die
    # Wachstumsrate für sehr große Tracks. Nur der Voll-Track-to_wav ist
    # dynamisch; kurze VAD-Slices bleiben auf dem Floor.
    size = file_size(webm_path)

    timeout_ms =
      ffmpeg_timeout_for(
        size,
        Worker.Settings.get(:ffmpeg_timeout_ms),
        Worker.Settings.get(:ffmpeg_timeout_per_mb_ms, 5_000)
      )

    Logger.info("Transcribe: did=#{discord_id} ffmpeg timeout=#{timeout_ms}ms für #{size} Bytes")

    case ffmpeg_bin() && run_cmd(ffmpeg_bin(), args, timeout_ms) do
      nil ->
        {:error, :ffmpeg_binary_missing}

      {:ok, _out} ->
        Logger.info(
          "Transcribe: did=#{discord_id} ffmpeg → wav done in #{System.monotonic_time(:millisecond) - start}ms"
        )

        {:ok, wav_path}

      {:error, {:timeout, t}} ->
        {:error, {:ffmpeg_timeout, t}}

      {:error, {:exit, code, out}} ->
        {:error, {:ffmpeg_failed, code, String.slice(out, 0, 400)}}

      {:error, {:exception, msg}} ->
        {:error, {:ffmpeg_exception, msg}}
    end
  end

  # Wenn ein VAD-Modell konfiguriert ist: das WAV per whisper-vad-speech-
  # segments in Sätze segmentieren und jedes Segment einzeln durch
  # whisper-cli jagen. Verhindert Run-Together-Probleme („kurzschwert-
  # begreifenden Goblin") weil jeder VAD-Slice ein eigener Whisper-Lauf
  # mit eigenem Initial-Prompt-Kontext ist. Fällt sauber auf den
  # Single-Pass-Pfad zurück wenn kein VAD konfiguriert.
  def transcribe_wav(wav_path, opts \\ []) do
    did = opts[:discord_id]

    case Worker.Settings.get(:whisper_vad_model) do
      nil ->
        single_pass(wav_path, opts)

      "" ->
        single_pass(wav_path, opts)

      vad_model ->
        if File.exists?(vad_model) do
          case run_vad(wav_path, vad_model) do
            {:ok, []} ->
              Logger.info(
                "Transcribe: did=#{did} VAD found no speech segments, falling back to full pass"
              )

              single_pass(wav_path, opts)

            {:ok, vad_segments} ->
              Logger.info(
                "Transcribe: did=#{did} VAD found #{length(vad_segments)} speech segment(s)"
              )

              transcribe_via_vad(wav_path, vad_segments, opts)

            {:error, reason} ->
              Logger.warning(
                "Transcribe: did=#{did} VAD failed (#{inspect(reason)}), falling back to full pass"
              )

              single_pass(wav_path, opts)
          end
        else
          Logger.warning(
            "Transcribe: did=#{did} VAD model #{vad_model} not found, falling back to full pass"
          )

          single_pass(wav_path, opts)
        end
    end
  end

  defp single_pass(wav_path, opts) do
    with {:ok, json_path} <- run_whisper(wav_path, opts) do
      read_segments(json_path)
    end
  end

  defp run_vad(wav_path, vad_model) do
    args = [
      "-vm",
      vad_model,
      # 400 ms Stille-Padding zwischen Sätzen — etwas aggressiver als Live-Mode
      # (600 ms) um auch bei knappen Pausen sauber zu splitten.
      "-vsd",
      "400",
      "-np",
      "-f",
      wav_path
    ]

    case run_cmd("whisper-vad-speech-segments", args, Worker.Settings.get(:vad_timeout_ms)) do
      {:ok, out} ->
        {:ok, parse_vad_segments(out)}

      {:error, {:timeout, t}} ->
        {:error, {:vad_timeout, t}}

      {:error, {:exit, code, out}} ->
        {:error, {:vad_failed, code, String.slice(out, 0, 200)}}

      {:error, {:exception, msg}} ->
        {:error, {:vad_exception, msg}}
    end
  end

  @doc """
  Parse whisper-vad-speech-segments output into `[{start_ms, end_ms}]`.
  Accepts whisper.cpp's `start = … , end = …` format, the arrow format
  `[ 0.000 --> 1.234 ]` und bare `0.000 1.234`-Paare — variiert je Version.
  Public für Unit-Tests. (Issue #418: aus dem entfernten LiveTranscribe
  hierher gezogen, weil der Batch-VAD-Pfad denselben Parser braucht.)
  """
  def parse_vad_segments(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_vad_line/1)
  end

  # whisper.cpp-hip 1.8.3's `whisper-vad-speech-segments` writes values in
  # 10ms-frame units (centiseconds) → ×10 ergibt Millisekunden.
  @vad_patterns [
    ~r/start\s*=\s*(-?\d+(?:\.\d+)?)\s*,?\s*end\s*=\s*(-?\d+(?:\.\d+)?)/,
    ~r/(-?\d+(?:\.\d+)?)\s*-->\s*(-?\d+(?:\.\d+)?)/,
    ~r/^\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*$/
  ]

  defp parse_vad_line(line) do
    trimmed = String.trim(line)

    Enum.find_value(@vad_patterns, [], fn re ->
      case Regex.run(re, trimmed) do
        [_, s, e] ->
          with {sf, ""} <- Float.parse(s),
               {ef, ""} <- Float.parse(e) do
            [{round(sf * 10), round(ef * 10)}]
          else
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp transcribe_via_vad(wav_path, vad_segments, opts) do
    segments =
      vad_segments
      |> Enum.flat_map(fn {s_ms, e_ms} -> transcribe_slice(wav_path, s_ms, e_ms, opts) end)

    {:ok, segments}
  end

  defp transcribe_slice(wav_path, s_ms, e_ms, opts) do
    slice = wav_path <> ".slice-#{s_ms}-#{e_ms}.wav"

    ffmpeg_args = [
      "-y",
      "-loglevel",
      "error",
      "-ss",
      ms_to_s(s_ms),
      "-to",
      ms_to_s(e_ms),
      "-i",
      wav_path,
      "-ac",
      "1",
      "-ar",
      "16000",
      slice
    ]

    with bin when is_binary(bin) <- ffmpeg_bin(),
         {:ok, _} <- run_cmd(bin, ffmpeg_args, Worker.Settings.get(:ffmpeg_timeout_ms)),
         {:ok, json_path} <- run_whisper(slice, opts),
         {:ok, slice_segments} <- read_segments(json_path) do
      File.rm(slice)
      File.rm(json_path)
      # Slice-interne offsets auf globale Timeline umrechnen (start + end).
      Enum.map(slice_segments, fn seg ->
        seg
        |> Map.update("offset_ms", s_ms, &(&1 + s_ms))
        |> Map.update("end_ms", s_ms, &(&1 + s_ms))
      end)
    else
      err ->
        Logger.warning("Transcribe: slice #{s_ms}-#{e_ms} failed: #{inspect(err)}")

        File.rm(slice)
        []
    end
  end

  defp ms_to_s(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 3)

  defp run_whisper(wav_path, opts) do
    out_prefix = Path.rootname(wav_path)

    base_args = [
      "-m",
      whisper_model(),
      "-l",
      whisper_lang(),
      "--no-speech-thold",
      float_setting(:whisper_no_speech_thold, 0.5),
      "--entropy-thold",
      float_setting(:whisper_entropy_thold, 2.0),
      "--logprob-thold",
      float_setting(:whisper_logprob_thold, -0.7)
    ]

    prompt =
      case {opts[:session_id], opts[:campaign_id]} do
        {sid, cid} when is_binary(sid) and is_binary(cid) ->
          # Issue #304: Single-Source bekommt GAR KEINEN Prompt. Auf den kurzen
          # Diarisierungs-/VAD-Slices dominiert *jeder* Prompt das Audio und
          # blutet ins Transkript — der Rolling-Context (letzte Utterances)
          # ebenso wie statisches Vokabular (z.B. „W4 W8 W8…"). Empirisch auf
          # echtem Raummikro-Audio bestätigt. Der Batch-/Live-Pfad nutzt den
          # vollen Prompt (build/2) weiter — dort sind die Segmente länger.
          if opts[:no_prompt] do
            ""
          else
            Worker.Recording.PromptBuilder.build(sid, cid)
          end

        _ ->
          Worker.Settings.get(:whisper_initial_prompt, "") || ""
      end

    prompt_args =
      if prompt != "", do: ["--prompt", prompt], else: []

    max_len_args =
      case Worker.Settings.get(:whisper_max_len, 0) do
        n when is_integer(n) and n > 0 -> ["--max-len", Integer.to_string(n)]
        _ -> []
      end

    split_args =
      if Worker.Settings.get(:whisper_split_on_word, false), do: ["--split-on-word"], else: []

    args =
      base_args ++
        prompt_args ++ max_len_args ++ split_args ++ ["-ojf", "-of", out_prefix, wav_path]

    did = opts[:discord_id]
    start = System.monotonic_time(:millisecond)

    case whisper_bin() && run_cmd(whisper_bin(), args, Worker.Settings.get(:whisper_timeout_ms)) do
      nil ->
        {:error, :whisper_binary_missing}

      {:ok, _out} ->
        Logger.info(
          "Transcribe: did=#{did} whisper-cli done in #{System.monotonic_time(:millisecond) - start}ms (#{Path.basename(wav_path)})"
        )

        json_path = out_prefix <> ".json"

        cond do
          File.exists?(json_path) -> {:ok, json_path}
          File.exists?(wav_path <> ".json") -> {:ok, wav_path <> ".json"}
          true -> {:error, {:whisper_no_json, out_prefix}}
        end

      {:error, {:timeout, t}} ->
        {:error, {:whisper_timeout, t}}

      {:error, {:exit, code, out}} ->
        {:error, {:whisper_failed, code, String.slice(out, -400, 400)}}

      {:error, {:exception, msg}} ->
        {:error, {:whisper_exception, msg}}
    end
  end

  # Issue #376: liest `-ojf`-JSON. offsets.from/to als Integer-ms (robuster
  # als der frühere String-Parse von "HH:MM:SS,mmm"). Confidence pro Segment
  # wird aus tokens[].p aggregiert.
  defp read_segments(json_path) do
    with {:ok, body} <- File.read(json_path),
         {:ok, data} <- Jason.decode(body) do
      segments =
        data
        |> Map.get("transcription", [])
        |> Enum.map(fn seg ->
          %{
            "text" => Map.get(seg, "text", ""),
            "offset_ms" => seg |> Map.get("offsets", %{}) |> Map.get("from", 0),
            # Issue #298: End-Zeit fürs Sprecher-Overlap-Mapping.
            "end_ms" => seg |> Map.get("offsets", %{}) |> Map.get("to", 0),
            # Issue #376: Per-Token-Confidence-Aggregat.
            "confidence" => aggregate_token_confidence(Map.get(seg, "tokens", []))
          }
        end)

      {:ok, segments}
    else
      err -> {:error, {:whisper_json_unreadable, err}}
    end
  end

  # ─── helpers ─────────────────────────────────────────────────────

  defp session_started_at(session_id) do
    case Worker.Repo.get_session(session_id) do
      %{started_at: %DateTime{} = ts} -> ts
      _ -> DateTime.utc_now()
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  # Issue #704: gescheiterte Spur bewahren statt still zu verlieren. KOPIE (kein
  # Move) nach audio_failed_dir/<session>/ — außerhalb audio_dir, damit die
  # Crash-Recovery sie nicht als Session re-runt (Duplikat-Emit-Falle). Loggt
  # den exakten manuellen Rerun-Befehl (der Liv-Rettungspfad). Funktioniert auch
  # bei audio_done_dir=nil (Delete-Mode). Voll-Auto-Retry = Folge-Issue.
  defp preserve_failed_track(session_id, discord_id, webm_path) do
    case Worker.Settings.get(:audio_failed_dir) do
      dir when is_binary(dir) and dir != "" ->
        dest_dir = Path.join(dir, session_id)
        dest = Path.join(dest_dir, Path.basename(webm_path))

        with :ok <- File.mkdir_p(dest_dir),
             {:ok, _bytes} <- File.copy(webm_path, dest) do
          Logger.error(
            "Transcribe: FEHLGESCHLAGENE Spur bewahrt → #{dest}. Manueller Rerun: " <>
              ~s|Worker.Recording.Transcribe.run("#{session_id}", [{"#{discord_id}", "#{dest}"}])|
          )
        else
          err ->
            Logger.warning(
              "Transcribe: konnte gescheiterte Spur #{webm_path} nicht bewahren: #{inspect(err)}"
            )
        end

      _ ->
        :ok
    end
  end

  @doc """
  Issue #704: ffmpeg-webm→wav-Timeout aus der Quell-Dateigröße ableiten.
  `max(floor_ms, size_mb * per_mb_ms)` — der 120s-Default riss 2h-Tracks
  (~100 MB), still verworfene Spur. Pur + testbar (kein I/O).
  """
  @spec ffmpeg_timeout_for(non_neg_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def ffmpeg_timeout_for(size_bytes, floor_ms, per_mb_ms)
      when is_integer(size_bytes) and size_bytes >= 0 do
    size_mb = size_bytes / 1_048_576
    max(floor_ms, round(size_mb * per_mb_ms))
  end

  # Issue #784: whisper_bin/ffmpeg_bin haben keinen Default mehr (:no_default).
  # blank-aware (die UI submittet "" für ungesetzte Felder) → nil; die Call-Sites
  # guarden auf nil und liefern einen klassifizierten stage1-Fehler
  # (whisper_binary_missing / ffmpeg_binary_missing), statt run_cmd(nil, …) mit
  # ArgumentError abzuwürgen und generisch fehlzuklassifizieren.
  defp whisper_bin, do: blank_to_nil(Worker.Settings.get(:whisper_bin))

  defp whisper_model,
    do: Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()

  defp whisper_lang, do: Worker.Settings.get(:whisper_lang, "auto")

  defp ffmpeg_bin, do: blank_to_nil(Worker.Settings.get(:ffmpeg_bin))

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(other), do: other

  defp float_setting(key, default) do
    val = Worker.Settings.get(key, default)
    :erlang.float_to_binary(val / 1, decimals: 2)
  end
end
