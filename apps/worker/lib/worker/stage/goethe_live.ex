defmodule Worker.Stage.GoetheLive do
  @moduledoc """
  Issue #394: Live-vs-Confirmed-Vergleichs-Stage.

  Speist Goethe-Faust-Multitrack-Audio (Fixtures aus `setup.sh`) durch den
  **echten Live-Pfad** (`transcribe_mode: :live`) eines laufenden Workers:

    1. wendet die prod-Whisper-/Transcribe-Config an (+ `keep_live_after_session: true`),
    2. erzeugt Kampagne + 4 Sprecher-Member + Session via `Worker.Intents.publish/1`,
    3. öffnet die Session (`AudioBuffer.open_session` → :live → per-Sprecher `LiveTranscribe`),
    4. speist pro Sprecher das WebM **zeitlich gestückelt + master-clock-getaktet**
       ein (`AudioBuffer.append`), sodass die 1-s-Commit-Ticks von `LiveTranscribe`
       progressive `status: "live"`-Utterances committen,
    5. `finalize` → der Post-Roll `Transcribe.run` schreibt `status: "confirmed"`.

  Weil `keep_live_after_session` true ist, unterdrückt `AudioBuffer.finalize/1`
  das `LiveUtterancesCleared` — live **und** confirmed bleiben beide in der
  Mnesia stehen und sind in der Protokoll-Spalte vergleichbar.

  Läuft im Worker-BEAM; vom Treiber-Task via `:rpc.call/4` ansprechbar.

  Vorlage: `Worker.MultiSourceEval.PipelineDriver` (Batch-Variante). Kein
  Fix für #394 — reine Reproduktions-/Vergleichs-Stage.
  """

  require Logger

  alias Worker.{Intents, Materializer, Recording.AudioBuffer, Repo, Settings}
  alias Worker.MultiSourceEval.AudioBuilder

  # prod-Whisper-/Transcribe-Config (worker_prod-Snapshot, Stand 2026-06-01).
  # Die Modell-/VAD-Pfade sind maschinen-lokal (= Toms Cache) und per opts
  # überschreibbar. Stage 2-4 (LLM) bleiben bewusst bei den Worker-Defaults —
  # sie laufen async nach `UtterancesTranscribed` und sind für den
  # Live-vs-Confirmed-Utterance-Vergleich (Stage 1) irrelevant.
  @prod_settings %{
    transcribe_mode: :live,
    keep_live_after_session: true,
    whisper_model: "/home/tom/.cache/whisper/ggml-large-v3-turbo.bin",
    whisper_vad_model: "/home/tom/.cache/whisper/ggml-silero-v5.1.2.bin",
    whisper_lang: "de",
    whisper_initial_prompt:
      "Pen-und-Paper-Rollenspiel. Würfel: W4, W6, W8, W10, W12, W20, W100. " <>
        "Begriffe: Initiative, Trefferpunkte, Lebenspunkte, Rüstungsklasse, " <>
        "Rettungswurf, Zauberspruch, Spielleiter, Kurzschwert, Langschwert, " <>
        "Streitaxt, Kettenhemd, Schild, Goblin, Ork, Troll, Drache, Elf, Zwerg, " <>
        "Halbling, Magier, Krieger, Schurke, Kleriker.",
    whisper_audio_filter: "highpass=f=100,loudnorm=I=-16:TP=-1.5:LRA=11",
    whisper_max_len: 120,
    whisper_no_speech_thold: 0.5,
    whisper_entropy_thold: 2.0,
    whisper_logprob_thold: -0.7,
    diarization_num_speakers: nil
  }

  # ~1.5 s Opus @64 kbps. Browser-MediaRecorder-ähnliche Chunk-Größe.
  @chunk_bytes 12_000
  # Wall-Clock-Takt pro Round-Robin-Runde (matcht den 1-s-Commit-Tick von
  # LiveTranscribe → progressive Live-Commits statt eines Drain-Bursts).
  @tick_ms 1_000
  @default_timeout_ms 10 * 60_000

  @doc """
  Fährt eine Goethe-Live-Session.

    * `session`  — geparste `gartenszene.json`-Map (speakers, name, turns …).
    * `variant`  — `"noisy_moderate"` | `"noisy_heavy"` (oder clean/realistic).

  Optionen: `:campaign_id` (Pflicht), `:campaign_name`, `:session_id`,
  `:timeout_ms`, `:fixtures_root`, `:whisper_model`, `:whisper_vad_model`.

  Returnt `{:ok, %{session_id, campaign_id, variant, utterances}}` oder
  `{:error, reason}`.
  """
  @spec run(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(session, variant, opts \\ []) when is_map(session) and is_binary(variant) do
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    campaign_name = Keyword.get(opts, :campaign_name, campaign_id)
    session_id = Keyword.get(opts, :session_id, UUIDv7.generate())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    fixtures_root = Keyword.get(opts, :fixtures_root, default_fixtures_root())

    apply_prod_settings(opts)

    :ok = Phoenix.PubSub.subscribe(Worker.PubSub, Materializer.topic())

    try do
      with {:ok, tracks} <- AudioBuilder.build_for_session(session, variant, fixtures_root),
           :ok <- setup_campaign(campaign_id, campaign_name, session_id, session),
           :ok <- AudioBuffer.open_session(session_id, campaign_id, :default),
           :ok <- feed_live(session_id, tracks),
           :ok <- finalize(session_id),
           :ok <- await_transcribed(session_id, timeout_ms) do
        {:ok,
         %{
           session_id: session_id,
           campaign_id: campaign_id,
           variant: variant,
           utterances: Repo.list_utterances(session_id)
         }}
      end
    after
      Phoenix.PubSub.unsubscribe(Worker.PubSub, Materializer.topic())
    end
  end

  @doc "Default `faust/`-Fixtures-Root (apps/worker/test/fixtures/stt/faust)."
  def default_fixtures_root do
    Path.expand("../../../test/fixtures/stt/faust", __DIR__)
  end

  @doc "Die angewandte prod-Config (für Doku/Report)."
  def prod_settings, do: @prod_settings

  # ─── Internals ──────────────────────────────────────────────────────

  defp apply_prod_settings(opts) do
    overrides =
      %{}
      |> maybe_put(:whisper_model, Keyword.get(opts, :whisper_model))
      |> maybe_put(:whisper_vad_model, Keyword.get(opts, :whisper_vad_model))

    settings = Map.merge(@prod_settings, overrides)
    :ok = Settings.put_many(settings)

    Logger.info(
      "GoetheLive: prod-Config angewandt (whisper=#{settings.whisper_model}, vad=#{settings.whisper_vad_model}, keep_live=true)"
    )

    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp setup_campaign(campaign_id, campaign_name, session_id, session) do
    speakers = Map.fetch!(session, "speakers")
    [{owner_name, owner_did} | _] = Enum.to_list(speakers)

    publish!(%{
      "kind" => Shared.Events.campaign_created(),
      "id" => campaign_id,
      "name" => campaign_name,
      "owner_discord_id" => owner_did,
      "owner_display_name" => owner_name
    })

    Enum.each(speakers, fn {speaker_name, discord_id} ->
      publish!(%{
        "kind" => Shared.Events.admin_member_added(),
        "campaign_id" => campaign_id,
        "discord_id" => discord_id,
        "display_name" => speaker_name
      })
    end)

    publish!(%{
      "kind" => Shared.Events.session_scheduled(),
      "id" => session_id,
      "campaign_id" => campaign_id,
      "number" => 1,
      "name" => Map.fetch!(session, "name"),
      "scheduled_for" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    publish!(%{
      "kind" => Shared.Events.session_started(),
      "id" => session_id,
      "campaign_id" => campaign_id
    })

    :ok
  end

  defp publish!(payload) do
    case Intents.publish(payload) do
      {:ok, _seq_or_pending} -> :ok
      err -> raise "Intents.publish failed: #{inspect(err)}"
    end
  end

  # Zeitlich gestückeltes, master-clock-getaktetes Einspeisen: jede Sprecher-
  # Spur wird in @chunk_bytes-Stücke zerlegt; pro Runde bekommt jeder Sprecher
  # ein Stück, danach @tick_ms Pause. So sieht der wachsende WebM-Stream wie
  # echtes Live-Streaming aus und die 1-s-Commit-Ticks von LiveTranscribe
  # feuern progressiv.
  defp feed_live(session_id, tracks) do
    chunked =
      Enum.map(tracks, fn %{discord_id: did, audio_b64: b64} ->
        {did, b64 |> Base.decode64!() |> chunk_binary(@chunk_bytes)}
      end)

    max_rounds = chunked |> Enum.map(fn {_did, cs} -> length(cs) end) |> Enum.max(fn -> 0 end)

    Logger.info(
      "GoetheLive: feeding #{length(tracks)} Spuren à bis zu #{max_rounds} Chunks (≈#{max_rounds * @tick_ms / 1000}s)"
    )

    Enum.each(0..max(max_rounds - 1, 0), fn round ->
      Enum.each(chunked, fn {did, chunks} ->
        case Enum.at(chunks, round) do
          nil -> :ok
          chunk -> AudioBuffer.append(session_id, did, Base.encode64(chunk))
        end
      end)

      Process.sleep(@tick_ms)
    end)

    :ok
  end

  defp chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk_binary(bin, size) do
    <<head::binary-size(size), rest::binary>> = bin
    [head | chunk_binary(rest, size)]
  end

  defp finalize(session_id) do
    AudioBuffer.finalize(session_id)
    :ok
  end

  defp await_transcribed(session_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(session_id, deadline)
  end

  defp do_await(session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:applied,
         %{"payload" => %{"kind" => "UtterancesTranscribed", "session_id" => ^session_id}}} ->
          :ok

        _other ->
          do_await(session_id, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end
end
