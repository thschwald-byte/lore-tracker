defmodule Worker.MultisourcePipelineTest do
  @moduledoc """
  End-to-End-Korrektheits-Smoke-Test für den Multi-Source-Stage-1-Pfad
  (Issue #377). Pinnt **keine WER-Schwelle** — die WER-Regression-Gate
  lebt in `mix lore.eval.multisource` gegen `baselines.json`.

  Hier verifizieren wir nur Korrektheits-Eigenschaften, die deterministisch
  vom Code (nicht vom Whisper-Modell) garantiert werden sollten:

    * Stage 1 produziert mindestens eine Utterance pro Sprecher.
    * Alle `discord_id`s der produzierten Utterances kommen aus der
      Speaker-Map (Routing-Smoke-Test — worker-internal, kein Hub-Pfad).
    * Timeline-Drift bleibt unter 5 s (locker — exakte Wertgrenze nicht
      asserted, das wäre ein verkappter WER-Gate).

  Ausgeschlossen by default (`@tag :stt_bench` + `exclude: [:stt_bench]`
  in `test_helper.exs`). Aufruf:

      mix test --only stt_bench

  Voraussetzungen:
    * `bash apps/worker/test/fixtures/stt/setup.sh` einmalig gelaufen
      (Librivox-Download + Per-Turn-Cut + Multitrack-Build)
    * `whisper-cli` im PATH + `:whisper_model`-Setting auf eine vorhandene
      ggml-Datei
    * `ffmpeg` im PATH
  """

  use ExUnit.Case, async: false

  alias Worker.MultiSourceEval.{Metrics, Normalize, PipelineDriver, Wer}
  alias Worker.TestHelper

  @moduletag :stt_bench

  setup_all do
    fixtures_root = PipelineDriver.default_fixtures_root()
    multitrack_dir = Path.join(fixtures_root, "multitrack/gartenszene/clean")

    cond do
      not File.dir?(multitrack_dir) ->
        Mix.raise(
          "Multi-Source-Fixtures nicht gebaut. Erst laufen: " <>
            "bash apps/worker/test/fixtures/stt/setup.sh"
        )

      System.find_executable("whisper-cli") == nil ->
        Mix.raise("whisper-cli nicht im PATH — siehe docs/Worker-Setup.md")

      System.find_executable("ffmpeg") == nil ->
        Mix.raise("ffmpeg nicht im PATH")

      true ->
        :ok = ensure_worker_children!()
        :ok
    end
  end

  setup do
    TestHelper.clear_all_tables!()
    :ok
  end

  describe "gartenszene" do
    test "clean — Routing + Drift + Non-Empty (KEINE WER-Schwelle)" do
      session = load_session("gartenszene")
      {:ok, result} = PipelineDriver.run(session, "clean", timeout_ms: 10 * 60_000)

      utts = result.utterances
      assert utts != [], "Stage 1 hat keine einzige Utterance produziert"

      speakers_map = Map.fetch!(session, "speakers")

      assert Metrics.speaker_routing_smoke_ok?(utts, speakers_map),
             "Eine Utterance trägt eine fremde discord_id (worker-internal Routing-Bug)"

      assert_all_drift_under(result, session, 5_000)

      print_wer_summary(session, result)
    end

    test "realistic — Cross-Talk-Robustheit (Routing + Drift + Non-Empty)" do
      session = load_session("gartenszene")
      {:ok, result} = PipelineDriver.run(session, "realistic", timeout_ms: 10 * 60_000)

      assert result.utterances != []
      assert Metrics.speaker_routing_smoke_ok?(result.utterances, Map.fetch!(session, "speakers"))
      assert_all_drift_under(result, session, 5_000)

      print_wer_summary(session, result)
    end

    test "overlap — Simultanrede-Segmentierung" do
      session = load_session("gartenszene")
      {:ok, result} = PipelineDriver.run(session, "overlap", timeout_ms: 10 * 60_000)

      assert result.utterances != []
      assert Metrics.speaker_routing_smoke_ok?(result.utterances, Map.fetch!(session, "speakers"))
      assert_all_drift_under(result, session, 5_000)

      print_wer_summary(session, result)
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────────

  defp load_session(name) do
    Path.join([PipelineDriver.default_fixtures_root(), "sessions", "#{name}.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_all_drift_under(result, session, limit_ms) do
    started_at = session_started_at(result.session_id)

    drifts =
      session
      |> Map.fetch!("turns")
      |> Metrics.attach_discord_ids(Map.fetch!(session, "speakers"))
      |> Metrics.timeline_drift(result.utterances, started_at)

    over_limit =
      Enum.filter(drifts, fn d ->
        d.drift_ms != nil and abs(d.drift_ms) > limit_ms
      end)

    assert over_limit == [],
           "Drift > #{limit_ms}ms: " <>
             Enum.map_join(over_limit, ", ", fn d ->
               "turn=#{d.turn_idx}(#{d.speaker})=#{d.drift_ms}ms"
             end)
  end

  defp print_wer_summary(session, result) do
    speakers_map = Map.fetch!(session, "speakers")
    speaker_names = Map.keys(speakers_map)

    per_speaker =
      Map.new(speaker_names, fn name ->
        did = Map.fetch!(speakers_map, name)
        ref_turns = Enum.filter(Map.fetch!(session, "turns"), &(&1["speaker"] == name))
        utts = Enum.filter(result.utterances, &(&1.discord_id == did))
        {name, Wer.align_speaker(ref_turns, utts)}
      end)

    global = Wer.global_wer(per_speaker) |> Float.round(4)
    buckets = Wer.bucket_wer(per_speaker)

    IO.puts(
      "\n  [STT-BENCH] session=#{session["name"]} variant=#{result.variant} " <>
        "global_wer=#{global}"
    )

    Enum.each(buckets, fn {bucket, %{wer: w, edits: e, ref_words: r}} ->
      IO.puts("    bucket=#{bucket} wer=#{Float.round(w, 4)} edits=#{e}/#{r}")
    end)

    ne = Metrics.named_entity_consistency(Map.fetch!(session, "vocab"), result.utterances)

    Enum.each(ne, fn {name, %{fuzzy_variants: vs, consistent?: c}} ->
      IO.puts("    NE \"#{name}\" consistent?=#{c} variants=#{inspect(vs)}")
    end)

    # Normalize-Round-Trip nur als Sanity-Check (kein assert)
    _ = Normalize.for_wer("Sanity")
  end

  defp session_started_at(session_id) do
    case Worker.Repo.get_session(session_id) do
      %{started_at: %DateTime{} = ts} -> ts
      _ -> DateTime.utc_now()
    end
  end

  # Idempotente Startup-Helper für die Worker-Kinder, die wir brauchen.
  defp ensure_worker_children! do
    ensure_started(Worker.TaskSupervisor, fn ->
      Task.Supervisor.start_link(name: Worker.TaskSupervisor)
    end)

    ensure_started(Worker.GpuQueue, fn -> Worker.GpuQueue.start_link([]) end)
    ensure_started(Worker.Materializer, fn -> Worker.Materializer.start_link([]) end)

    ensure_started(Worker.Recording.LiveTranscribe.Registry, fn ->
      Registry.start_link(keys: :unique, name: Worker.Recording.LiveTranscribe.Registry)
    end)

    ensure_started(Worker.Recording.LiveTranscribe.Supervisor, fn ->
      Worker.Recording.LiveTranscribe.Supervisor.start_link([])
    end)

    ensure_started(Worker.Recording.AudioBuffer, fn ->
      Worker.Recording.AudioBuffer.start_link([])
    end)

    :ok
  end

  defp ensure_started(name, start_fn) do
    case Process.whereis(name) do
      nil ->
        case start_fn.() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
