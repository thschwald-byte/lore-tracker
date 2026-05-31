defmodule Mix.Tasks.Lore.Eval.Multisource do
  @moduledoc """
  End-to-End-Multi-Source-Pipeline-Eval (Issue #377). Misst Stage-1-Output
  (Whisper-Transkription über AudioBuffer→Transcribe) gegen die im Session-
  JSON hinterlegten Erwartungen.

  Voraussetzungen:
    * `bash apps/worker/test/fixtures/stt/setup.sh` einmalig
    * `whisper-cli`, `ffmpeg` im PATH
    * Whisper-Modell unter `~/.cache/whisper/` (oder via `--model`)

  ## Modi

      mix lore.eval.multisource                                        # default: gartenszene / clean / aktuelles Modell, Gate gegen baselines.json
      mix lore.eval.multisource --session gartenszene --variant realistic --verbose
      mix lore.eval.multisource --model ~/.cache/whisper/ggml-large-v3-turbo.bin
      mix lore.eval.multisource --max-rel-degradation 0.20             # exit 1 wenn global_wer > 1.20 × baseline
      mix lore.eval.multisource --output-baseline test/fixtures/stt/baselines.json   # Baseline schreiben

  Gate-Logik: aktueller `global_wer` darf gegenüber dem in `baselines.json`
  hinterlegten Wert höchstens um `--max-rel-degradation` (default 0.20) relativ
  steigen. Bei Verstoß → exit 1.

  ## Deterministische Config

  Vor jedem Run werden gepinnt:
    * `whisper_lang = "de"`
    * `whisper_initial_prompt = ""`
    * `whisper_max_len = 0`
  Sowohl beim `--output-baseline`-Schreibmodus als auch beim Gate-Lauf, damit
  beide gegen dieselbe Determinismus-Konfiguration laufen. Nach dem Run
  werden die alten Werte restored.
  """

  use Mix.Task

  alias Worker.MultiSourceEval.{Metrics, PipelineDriver, Wer}

  @shortdoc "Multi-Source-Pipeline-Eval gegen Goldstandard + Gate auf baselines.json"

  @fixtures_root "apps/worker/test/fixtures/stt/faust"
  @baselines_path "apps/worker/test/fixtures/stt/baselines.json"
  @default_max_rel_degradation 0.20

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          session: :string,
          variant: :string,
          model: :string,
          verbose: :boolean,
          max_rel_degradation: :float,
          output_baseline: :string
        ]
      )

    if Mix.env() == :prod do
      Mix.raise("mix lore.eval.multisource ist dev/test-only — kein MIX_ENV=prod.")
    end

    session_name = Keyword.get(opts, :session, "gartenszene")
    variant = Keyword.get(opts, :variant, "clean")
    verbose? = Keyword.get(opts, :verbose, false)
    max_rel = Keyword.get(opts, :max_rel_degradation, @default_max_rel_degradation)

    bootstrap_worker!()

    {backup, model_label} = apply_deterministic_settings!(opts[:model])

    try do
      session = load_session(session_name)
      Mix.shell().info("=== Multi-Source-Eval: #{session_name} / #{variant} / #{model_label} ===")

      {:ok, result} = run_eval(session, variant)
      report = build_report(session, variant, model_label, result)

      print_report(report, verbose?)

      case opts[:output_baseline] do
        nil -> compare_against_baseline!(report, max_rel)
        path -> write_baseline!(report, path)
      end
    after
      restore_settings!(backup)
    end
  end

  # ─── Bootstrap ───────────────────────────────────────────────────────

  defp bootstrap_worker! do
    :ok = Shared.Mnesia.ensure_started!()
    :ok = Worker.Schema.Mnesia.bootstrap!()

    # paired? must return true so Worker.Application starts AudioBuffer, GpuQueue,
    # Materializer, etc. We fake the hub_token; the HubClient WS will retry
    # forever and fail — that's fine, Intents.publish has a local-apply fallback.
    if Worker.Repo.get_state(:hub_token) == nil do
      Worker.Repo.put_state(:hub_token, "eval-fake-token-#{System.unique_integer([:positive])}")
    end

    if Worker.Repo.get_state(:worker_id) == nil do
      Worker.Repo.put_state(:worker_id, "eval-worker-#{System.unique_integer([:positive])}")
    end

    if Worker.Repo.get_state(:hub_base_url) == nil do
      # HubClient.ws_base/1 crashed bei nil; URL muss http://… oder https://… sein.
      # Wir verbinden absichtlich nicht — Slipstream reconnect-Loop ist OK.
      Worker.Repo.put_state(:hub_base_url, "http://127.0.0.1:1")
    end

    Application.put_env(:worker, :no_browser, true)
    {:ok, _} = Application.ensure_all_started(:worker)
    :ok
  end

  defp apply_deterministic_settings!(model_override) do
    keys = [:whisper_lang, :whisper_initial_prompt, :whisper_max_len, :whisper_model]

    backup =
      Map.new(keys, fn k -> {k, Worker.Settings.get(k)} end)

    Worker.Settings.put(:whisper_lang, "de")
    Worker.Settings.put(:whisper_initial_prompt, "")
    Worker.Settings.put(:whisper_max_len, 0)

    model_label =
      case model_override do
        nil ->
          path = Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()
          model_label_from_path(path)

        override ->
          expanded = Path.expand(override)

          if not File.exists?(expanded),
            do: Mix.raise("Whisper-Modell nicht gefunden: #{expanded}")

          Worker.Settings.put(:whisper_model, expanded)
          model_label_from_path(expanded)
      end

    {backup, model_label}
  end

  defp restore_settings!(backup) do
    Enum.each(backup, fn {k, v} -> Worker.Settings.put(k, v) end)
  end

  defp model_label_from_path(nil), do: "unknown"

  defp model_label_from_path(path) do
    path |> Path.basename() |> String.replace_trailing(".bin", "")
  end

  # ─── Eval-Loop ──────────────────────────────────────────────────────

  defp load_session(name) do
    Path.join([@fixtures_root, "sessions", "#{name}.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  defp run_eval(session, variant) do
    PipelineDriver.run(session, variant,
      fixtures_root: @fixtures_root,
      timeout_ms: 15 * 60_000
    )
  end

  defp build_report(session, variant, model_label, result) do
    speakers = Map.fetch!(session, "speakers")

    per_speaker =
      Map.new(speakers, fn {name, did} ->
        ref_turns = Enum.filter(Map.fetch!(session, "turns"), &(&1["speaker"] == name))
        utts = Enum.filter(result.utterances, &(&1.discord_id == did))
        {name, Wer.align_speaker(ref_turns, utts)}
      end)

    global = Wer.global_wer(per_speaker)
    buckets = Wer.bucket_wer(per_speaker)

    %{
      session: Map.fetch!(session, "name"),
      variant: variant,
      model: model_label,
      global_wer: global,
      bucket_wer: buckets,
      per_speaker_counts:
        Map.new(per_speaker, fn {name, a} ->
          {name,
           %{
             ref_words: length(a.ref_words),
             hyp_words: length(a.hyp_words),
             edits: a.edit_count
           }}
        end),
      ne_consistency:
        Metrics.named_entity_consistency(Map.fetch!(session, "vocab"), result.utterances),
      utterance_count: length(result.utterances),
      raw_utterances: result.utterances
    }
  end

  # ─── Reporting ───────────────────────────────────────────────────────

  defp print_report(report, verbose?) do
    Mix.shell().info("")
    Mix.shell().info("global_wer = #{Float.round(report.global_wer, 4)}")
    Mix.shell().info("utterances = #{report.utterance_count}")
    Mix.shell().info("")

    Mix.shell().info("bucket_wer:")

    Enum.each(report.bucket_wer, fn {bucket, %{wer: w, edits: e, ref_words: r}} ->
      Mix.shell().info("  #{bucket}: #{Float.round(w, 4)} (#{e}/#{r})")
    end)

    Mix.shell().info("")
    Mix.shell().info("per_speaker:")

    Enum.each(report.per_speaker_counts, fn {name, c} ->
      Mix.shell().info("  #{name}: ref=#{c.ref_words} hyp=#{c.hyp_words} edits=#{c.edits}")
    end)

    Mix.shell().info("")
    Mix.shell().info("named_entity_consistency:")

    Enum.each(report.ne_consistency, fn {name, %{fuzzy_variants: vs, consistent?: c}} ->
      Mix.shell().info("  \"#{name}\" consistent?=#{c} variants=#{inspect(vs)}")
    end)

    if verbose? do
      Mix.shell().info("")
      Mix.shell().info("raw_utterances:")

      Enum.each(report.raw_utterances, fn u ->
        Mix.shell().info("  [#{u.discord_id}] #{u.text}")
      end)
    end
  end

  # ─── Baseline-Gate ──────────────────────────────────────────────────

  defp compare_against_baseline!(report, max_rel) do
    baselines = read_baselines()

    base_wer =
      baselines
      |> get_in([report.model, report.session, report.variant, "global_wer"])

    cond do
      is_nil(base_wer) ->
        Mix.shell().info("")

        Mix.shell().info(
          "⚠ Keine Baseline für #{report.model}/#{report.session}/#{report.variant}."
        )

        Mix.shell().info("  Schreibe mit --output-baseline #{@baselines_path}.")

      report.global_wer > base_wer * (1.0 + max_rel) ->
        Mix.shell().info("")

        Mix.raise(
          "WER-Regression: aktuell=#{Float.round(report.global_wer, 4)} > " <>
            "Baseline=#{Float.round(base_wer, 4)} × (1 + #{max_rel})"
        )

      true ->
        Mix.shell().info("")

        Mix.shell().info(
          "✓ WER innerhalb Toleranz (Δ rel = " <>
            "#{Float.round((report.global_wer - base_wer) / max(base_wer, 1.0e-9), 4)})"
        )
    end
  end

  defp write_baseline!(report, path) do
    existing = read_baselines_from(path)

    bucket_wer_simple =
      Map.new(report.bucket_wer, fn {b, %{wer: w}} -> {b, Float.round(w, 4)} end)

    updated =
      existing
      |> put_in_safe([report.model, report.session, report.variant], %{
        "global_wer" => Float.round(report.global_wer, 4),
        "bucket_wer" => bucket_wer_simple,
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
    Mix.shell().info("Baseline geschrieben: #{path}")
  end

  defp read_baselines, do: read_baselines_from(@baselines_path)

  defp read_baselines_from(path) do
    case File.read(path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, :enoent} -> %{}
    end
  end

  defp put_in_safe(map, [k], v), do: Map.put(map, k, v)

  defp put_in_safe(map, [k | rest], v) do
    sub = Map.get(map, k, %{})
    Map.put(map, k, put_in_safe(sub, rest, v))
  end
end
