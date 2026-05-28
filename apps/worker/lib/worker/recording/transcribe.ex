defmodule Worker.Recording.Transcribe do
  @moduledoc """
  Stage 1: convert per-speaker recording files to text via `whisper-cli`.

  Input: list of `{discord_id, webm_path}` from `AudioBuffer.finalize/1`.
  For each file: convert webm/opus → 16k mono WAV via `ffmpeg`, run
  whisper-cli with `-oj` to get a JSON transcript, parse segments, and
  emit one `UtteranceAppended` event per non-empty segment with a
  timestamp computed from session start + segment offset.

  After all files have been processed, emit `SessionEnded` so the
  pipeline (stages 2-4) sees a complete transcript.

  Env-driven config:
  - `:whisper_bin`   (default `whisper-cli`)
  - `:whisper_model` (default `~/.cache/whisper/ggml-base.bin`)
  - `:whisper_lang`  (default `auto`)
  - `:ffmpeg_bin`    (default `ffmpeg`)
  """

  require Logger

  alias Worker.Intents

  def run(session_id, files) do
    campaign_id = resolve_campaign_id(session_id)
    notify_stage1(campaign_id, "started", nil)

    try do
      started_at = session_started_at(session_id)

      count =
        files
        |> Enum.map(fn {discord_id, path} ->
          transcribe_one(session_id, discord_id, path, started_at)
        end)
        |> Enum.sum()

      Logger.info("Transcribe: session=#{session_id} → #{count} utterances")

      {:ok, _} =
        Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

      notify_stage1(campaign_id, "ended", nil)
      :ok
    rescue
      e ->
        notify_stage1(campaign_id, "failed", Exception.message(e))
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Issue #19: Single-Source-Transkription. Eine kombinierte WebM-Datei wird

    1. nach 16 kHz Mono WAV konvertiert,
    2. durch den pyannote-Sidecar diarisiert (Sprecher-Turns),
    3. pro Turn per `whisper-cli` transkribiert,
    4. als `UtteranceAppended` mit Pseudo-Sprecher-Label
       (`speaker:<session_id>:<n>`) statt discord_id emittiert.

  Anschließend `SessionEnded`, damit die Pipeline (Stage 2-4) anläuft. Der GM
  ordnet die Pseudo-Sprecher später via `SpeakerAssigned` echten Mitgliedern zu.
  """
  def run_single_source(session_id, webm_path) do
    campaign_id = resolve_campaign_id(session_id)
    notify_stage1(campaign_id, "started", nil)

    try do
      started_at = session_started_at(session_id)
      # Issue #304: gar kein Whisper-Prompt für Single-Source — kurze Slices,
      # jeder Prompt blutet (Self-Vergiftung / Vokabular-Bleed).
      opts = [
        session_id: session_id,
        campaign_id: campaign_id,
        discord_id: "single_source",
        no_prompt: true
      ]

      count =
        with {:ok, wav_path} <- to_wav(webm_path, "single_source"),
             {:ok, diar_segments} <- diarize(wav_path, campaign_id),
             {:ok, whisper_segments} <- transcribe_wav(wav_path, opts) do
          # Issue #298: Whisper EINMAL über die volle Spur (statt pro
          # Diarisierungs-Turn neu) → bessere Erkennung, weniger Boundary-
          # Artefakte, drastisch weniger whisper-cli-Aufrufe. Jedes Whisper-
          # Segment wird dem Sprecher-Turn mit größtem Zeit-Overlap zugeordnet.
          whisper_segments
          |> filter_hallucinations()
          |> assign_speakers(diar_segments, session_id)
          |> emit_by_speaker(session_id, started_at)
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

      Logger.info("Transcribe: single_source session=#{session_id} → #{count} utterances")

      {:ok, _} =
        Intents.publish(%{"kind" => Shared.Events.session_ended(), "id" => session_id})

      notify_stage1(campaign_id, "ended", nil)
      :ok
    rescue
      e ->
        notify_stage1(campaign_id, "failed", Exception.message(e))
        reraise e, __STACKTRACE__
    end
  end

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
  defp emit_by_speaker(assigned, session_id, started_at) do
    assigned
    |> Enum.group_by(fn {ref, _} -> ref end, fn {_, seg} -> seg end)
    |> Enum.reduce(0, fn {ref, segs}, acc ->
      acc + emit_utterances(session_id, ref, segs, started_at)
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
  end

  # ─── per-file ────────────────────────────────────────────────────

  defp transcribe_one(session_id, discord_id, webm_path, started_at) do
    size = file_size(webm_path)

    Logger.info("Transcribe: did=#{discord_id} file=#{Path.basename(webm_path)} size=#{size}")

    if size < 256 do
      Logger.info(
        "Transcribe: skipping #{discord_id} (size=#{size} bytes — likely no real audio)"
      )

      0
    else
      campaign_id =
        case Worker.Repo.get_session(session_id) do
          %{campaign_id: cid} -> cid
          _ -> nil
        end

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

        emit_utterances(session_id, discord_id, filtered, started_at)
      else
        {:error, reason} ->
          Logger.warning(
            "Transcribe: failed for did=#{discord_id} path=#{webm_path}: #{inspect(reason)}"
          )

          0
      end
    end
  end

  defp emit_utterances(session_id, discord_id, segments, started_at) do
    deduped = dedupe_consecutive(segments)
    dropped = length(segments) - length(deduped)

    if dropped > 0 do
      Logger.info(
        "Transcribe: did=#{discord_id} dropped #{dropped} duplicate segment(s) (whisper repetition)"
      )
    end

    count =
      Enum.reduce(deduped, 0, fn seg, acc ->
        text = seg |> Map.get("text", "") |> String.trim()

        if text == "" do
          acc
        else
          offset_ms = seg |> Map.get("offset_ms", 0)
          ts = DateTime.add(started_at, offset_ms, :millisecond)

          {:ok, _} =
            Intents.publish(%{
              "kind" => Shared.Events.utterance_appended(),
              "id" => UUIDv7.generate(),
              "session_id" => session_id,
              "discord_id" => to_string(discord_id),
              "timestamp" => DateTime.to_iso8601(ts),
              "text" => text,
              "confidence" => nil,
              "status" => "confirmed"
            })

          acc + 1
        end
      end)

    Logger.info("Transcribe: did=#{discord_id} emit #{count} utterances")
    count
  end

  # Whisper neigt zu Wiederholungen auf stillen/rauschigen Passagen (klassische
  # Halluzination). Schmeißt aufeinanderfolgende Segmente raus, deren
  # normalisierter Text identisch ist. Konservativ — keine Levenshtein-Fuzzy,
  # damit echte Wiederholungen wie „Ja. Ja." (zwei Sätze) erhalten bleiben,
  # während eine wiederholte Identität in Folge gedroppt wird.
  # Public weil per Test reflexiv aufgerufen.
  def dedupe_consecutive(segments) do
    {acc, _last_norm} =
      Enum.reduce(segments, {[], nil}, fn seg, {kept, last_norm} ->
        norm = seg |> Map.get("text", "") |> normalize_for_dedupe()

        cond do
          norm == "" -> {kept, last_norm}
          norm == last_norm -> {kept, last_norm}
          true -> {[seg | kept], norm}
        end
      end)

    Enum.reverse(acc)
  end

  defp normalize_for_dedupe(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Bekannte Whisper-Halluzinations-Strings die auf Stille, Hintergrundmusik
  # oder sehr leisen Passagen entstehen. Public für Tests.
  @hallucination_patterns [
    ~r/^\[BLANK_AUDIO\]$/i,
    ~r/^\[Stille\]$/i,
    ~r/^\[ *Stille *\]$/i,
    ~r/^\[Musik\]$/i,
    ~r/^\[ *Musik *\]$/i,
    ~r/^\(Musik\)$/i,
    ~r/^Danke fürs Zuschauen\.?$/i,
    ~r/^Vielen Dank\.?$/i,
    ~r/^Vielen Dank fürs? Zuschauen\.?$/i,
    ~r/^Tschüss\.?$/i,
    ~r/^Auf Wiedersehen\.?$/i,
    ~r/^Bis zum nächsten Mal\.?$/i,
    ~r/^Bis bald\.?$/i,
    ~r/^Untertitel(?:ung)? (?:von|des|im Auftrag) .+$/i,
    ~r/^Abonniert? (?:jetzt|den Kanal)\.?$/i,
    ~r/^\[.*?Applaus.*?\]$/i,
    ~r/^\[.*?Gelächter.*?\]$/i,
    ~r/^www\.\S+$/i,
    # YouTube/streaming outros
    ~r/^Thanks? for watching\.?$/i,
    ~r/^Subscribe to .+$/i,
    ~r/^Like and subscribe\.?$/i,
    ~r/^(?:Please )?like,? (?:and )?subscribe\.?$/i,
    # Music/sound indicators
    ~r/^♪.+♪$/u,
    ~r/^\[Music\]$/i,
    ~r/^\[Applause\]$/i,
    ~r/^\[Laughter\]$/i,
    ~r/^\(.+(?:Musik|Lachen|Applaus|Laughter|Applause|music).+\)$/i,
    # German formality outros (häufig bei Stille + deutsch)
    ~r/^Vielen Dank für (?:Ihre?|Ihre? )?Aufmerksamkeit\.?$/i,
    ~r/^Danke schön\.?$/i,
    ~r/^Herzlichen Dank\.?$/i,
    # Signaturzeile-Artefakt
    ~r/^Gez\.\s+\S+/,
    # Transcript-Boilerplate
    ~r/^Untertitel (?:von|der|des) /i,
    ~r/^Untertitelung (?:von|der|des) /i,
    ~r/^Übersetzt von /i,
    # Chunk-boundary artifacts (häufig bei Stille + whisper.cpp 1s-chunks)
    ~r/^\.\.\.$/,
    ~r/^\.{4,}$/,
    # Issue #234: Onomatopoeia-Emphasis-Marker `*...*` (z.B. `*Squeaky*`,
    # `*räuspert sich*`). Whisper produziert das selten in legitimen
    # Outputs — wenn doch, ist's fast immer aus dem Initial-Prompt
    # reprojiziert (Self-Vergiftung).
    ~r/^\*[^*]+\*\.?$/u
  ]

  def filter_hallucinations(segments) do
    Enum.reject(segments, fn seg ->
      text = seg |> Map.get("text", "") |> String.trim()
      hallucination?(text)
    end)
  end

  # Public so PromptBuilder kann symmetrisch denselben Filter beim
  # Prompt-Build anwenden (Issue #234: Self-Vergiftung via Rolling-Context).
  @spec hallucination?(String.t()) :: boolean
  def hallucination?(text) when is_binary(text) do
    trimmed = String.trim(text)
    Enum.any?(@hallucination_patterns, &Regex.match?(&1, trimmed))
  end

  def hallucination?(_), do: false

  # ─── ffmpeg / whisper-cli ────────────────────────────────────────

  defp to_wav(webm_path, discord_id \\ nil) do
    wav_path = Path.rootname(webm_path) <> ".wav"

    base_args = ["-y", "-loglevel", "error", "-i", webm_path, "-ac", "1", "-ar", "16000"]

    filter_args =
      case Worker.Settings.get(:whisper_audio_filter, "") do
        f when is_binary(f) and f != "" -> ["-af", f]
        _ -> []
      end

    args = base_args ++ filter_args ++ [wav_path]
    start = System.monotonic_time(:millisecond)

    case System.cmd(ffmpeg_bin(), args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info(
          "Transcribe: did=#{discord_id} ffmpeg → wav done in #{System.monotonic_time(:millisecond) - start}ms"
        )

        {:ok, wav_path}

      {out, code} ->
        {:error, {:ffmpeg_failed, code, String.slice(out, 0, 400)}}
    end
  rescue
    e -> {:error, {:ffmpeg_exception, Exception.message(e)}}
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

    case System.cmd("whisper-vad-speech-segments", args, stderr_to_stdout: true) do
      {out, 0} ->
        # Wiederverwendung des Parsers aus LiveTranscribe (public).
        {:ok, Worker.Recording.LiveTranscribe.parse_vad_segments(out)}

      {out, code} ->
        {:error, {:vad_failed, code, String.slice(out, 0, 200)}}
    end
  rescue
    e -> {:error, {:vad_exception, Exception.message(e)}}
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

    with {_, 0} <- System.cmd(ffmpeg_bin(), ffmpeg_args, stderr_to_stdout: true),
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

  defp run_whisper(wav_path, opts \\ []) do
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
        prompt_args ++ max_len_args ++ split_args ++ ["-oj", "-of", out_prefix, wav_path]

    did = opts[:discord_id]
    start = System.monotonic_time(:millisecond)

    case System.cmd(whisper_bin(), args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info(
          "Transcribe: did=#{did} whisper-cli done in #{System.monotonic_time(:millisecond) - start}ms (#{Path.basename(wav_path)})"
        )

        json_path = out_prefix <> ".json"

        cond do
          File.exists?(json_path) -> {:ok, json_path}
          File.exists?(wav_path <> ".json") -> {:ok, wav_path <> ".json"}
          true -> {:error, {:whisper_no_json, out_prefix}}
        end

      {out, code} ->
        {:error, {:whisper_failed, code, String.slice(out, -400, 400) || out}}
    end
  rescue
    e -> {:error, {:whisper_exception, Exception.message(e)}}
  end

  defp read_segments(json_path) do
    with {:ok, body} <- File.read(json_path),
         {:ok, data} <- Jason.decode(body) do
      segments =
        data
        |> Map.get("transcription", [])
        |> Enum.map(fn seg ->
          %{
            "text" => Map.get(seg, "text", ""),
            "offset_ms" =>
              seg
              |> get_in(["timestamps", "from"])
              |> parse_ts_to_ms(),
            # Issue #298: End-Zeit fürs Sprecher-Overlap-Mapping.
            "end_ms" =>
              seg
              |> get_in(["timestamps", "to"])
              |> parse_ts_to_ms()
          }
        end)

      {:ok, segments}
    else
      err -> {:error, {:whisper_json_unreadable, err}}
    end
  end

  # ─── helpers ─────────────────────────────────────────────────────

  # Whisper "HH:MM:SS,mmm" → integer milliseconds
  defp parse_ts_to_ms(nil), do: 0
  defp parse_ts_to_ms(""), do: 0

  defp parse_ts_to_ms(s) when is_binary(s) do
    case String.split(s, ",") do
      [hms, ms] ->
        case String.split(hms, ":") do
          [h, m, sec] ->
            with {h, ""} <- Integer.parse(h),
                 {m, ""} <- Integer.parse(m),
                 {sec, ""} <- Integer.parse(sec),
                 {ms, ""} <- Integer.parse(ms) do
              ((h * 60 + m) * 60 + sec) * 1000 + ms
            else
              _ -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  end

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

  defp whisper_bin, do: Worker.Settings.get(:whisper_bin, "whisper-cli")

  defp whisper_model,
    do: Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()

  defp whisper_lang, do: Worker.Settings.get(:whisper_lang, "auto")

  defp ffmpeg_bin, do: Worker.Settings.get(:ffmpeg_bin, "ffmpeg")

  defp float_setting(key, default) do
    val = Worker.Settings.get(key, default)
    :erlang.float_to_binary(val / 1, decimals: 2)
  end
end
