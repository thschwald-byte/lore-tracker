defmodule Mix.Tasks.Lore.SttBench do
  use Mix.Task

  @shortdoc "WER + RTF Benchmark für STT-Pipeline gegen Faust-Fixtures"

  @moduledoc """
  Misst Word-Error-Rate (WER) und Real-Time-Factor (RTF) der Whisper-Transkription
  gegen Ground-Truth-Texte aus der Librivox-Dramatischen-Lesung von Goethe Faust I (CC0).

  Voraussetzungen:
    - whisper-cli im PATH
    - Whisper-Modell unter ~/.cache/whisper/ (oder via Worker.Settings)
    - Fixture-Audio erzeugt: bash apps/worker/test/fixtures/stt/setup.sh

  ## Verwendung

      mix lore.stt_bench                            # Default: gartenszene, aktuelles Modell
      mix lore.stt_bench --session hexenkueche
      mix lore.stt_bench --verbose
      mix lore.stt_bench --multi-speaker            # Rolling-Context aktiviert
      mix lore.stt_bench --no-context               # jeder Turn isoliert (Baseline)
      mix lore.stt_bench --model ~/.cache/whisper/ggml-base.bin
      mix lore.stt_bench --all-models               # iteriert über tiny/base/small/medium/large-v3{-turbo}
      mix lore.stt_bench --all-sessions             # iteriert über gartenszene + hexenkueche
      mix lore.stt_bench --all-models --all-sessions   # volle Matrix für docs/Performance.md

      # Issue #232 — VAD vs. Baseline
      mix lore.stt_bench --no-vad                                            # Baseline ohne VAD
      mix lore.stt_bench --vad ~/.cache/whisper/ggml-silero-v5.1.2.bin       # mit Silero VAD

  ## Multi-Speaker-Test

  --multi-speaker simuliert den Rolling-Context-Mechanismus: Turn N bekommt
  den transkribierten Text von Turn 1..N-1 als Whisper-Prompt.

  --no-context ist die Vergleichsbasis: jeder Turn wird ohne Prompt transkribiert.

  ## RTF (Real-Time-Factor)

  RTF = Verarbeitungs-Zeit / Audio-Dauer. RTF < 1.0 = schneller als Echtzeit
  (live-fähig). RTF > 1.0 = nur Batch-tauglich. Audio-Dauer wird aus dem WAV-
  Header gelesen (data-chunk-size / (sample_rate × bytes_per_sample × channels)).
  """

  @fixtures_base "apps/worker/test/fixtures/stt/faust"

  @model_suite [
    {"tiny", "~/.cache/whisper/ggml-tiny.bin"},
    {"base", "~/.cache/whisper/ggml-base.bin"},
    {"small", "~/.cache/whisper/ggml-small.bin"},
    {"medium", "~/.cache/whisper/ggml-medium.bin"},
    {"large-v3", "~/.cache/whisper/ggml-large-v3.bin"},
    {"large-v3-turbo", "~/.cache/whisper/ggml-large-v3-turbo.bin"}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          session: :string,
          verbose: :boolean,
          multi_speaker: :boolean,
          no_context: :boolean,
          model: :string,
          all_models: :boolean,
          all_sessions: :boolean,
          vad: :string,
          no_vad: :boolean
        ]
      )

    verbose = opts[:verbose] || false

    context_mode =
      cond do
        opts[:multi_speaker] -> :multi_speaker
        opts[:no_context] -> :no_context
        true -> :no_context
      end

    Application.put_env(:worker, :no_browser, true)
    Application.ensure_all_started(:worker)

    apply_vad_setting(opts)

    sessions = decide_sessions(opts)
    models = decide_models(opts)

    matrix =
      for {model_label, model_path} <- models,
          session_name <- sessions do
        run_one(model_label, model_path, session_name, context_mode, verbose)
      end

    Worker.Settings.put(:whisper_initial_prompt, "")

    if opts[:all_models] || opts[:all_sessions] do
      Mix.shell().info("")
      Mix.shell().info(String.duplicate("═", 70))
      Mix.shell().info("Matrix-Zusammenfassung (Markdown — kopierbar nach docs/Performance.md):")
      Mix.shell().info("")
      print_matrix_table(matrix, sessions)
    end
  end

  # ─── VAD-Setting toggeln (Issue #232) ───────────────────────────────

  defp apply_vad_setting(opts) do
    cond do
      opts[:no_vad] ->
        Worker.Settings.put(:whisper_vad_model, nil)
        Mix.shell().info("VAD: aus (--no-vad)")

      vad_path = opts[:vad] ->
        expanded = Path.expand(vad_path)
        unless File.exists?(expanded), do: Mix.raise("VAD-Modell nicht gefunden: #{expanded}")
        Worker.Settings.put(:whisper_vad_model, expanded)
        Mix.shell().info("VAD: #{Path.basename(expanded)}")

      true ->
        current = Worker.Settings.get(:whisper_vad_model)

        if current && current != "" do
          Mix.shell().info("VAD: #{Path.basename(current)} (aus Settings)")
        else
          Mix.shell().info("VAD: aus (Settings)")
        end
    end
  end

  # ─── Sessions + Modelle wählen ─────────────────────────────────────────────

  defp decide_sessions(opts) do
    cond do
      opts[:all_sessions] ->
        @fixtures_base
        |> Path.join("sessions")
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.basename(&1, ".json"))
        |> Enum.sort()

      opts[:session] ->
        [opts[:session]]

      true ->
        ["gartenszene"]
    end
  end

  defp decide_models(opts) do
    cond do
      opts[:all_models] ->
        @model_suite
        |> Enum.map(fn {label, path} -> {label, Path.expand(path)} end)
        |> Enum.filter(fn {label, path} ->
          if File.exists?(path) do
            true
          else
            Mix.shell().info("[skip] #{label} — Modell-Datei fehlt: #{path}")
            false
          end
        end)

      opts[:model] ->
        expanded = Path.expand(opts[:model])
        unless File.exists?(expanded), do: Mix.raise("Modell nicht gefunden: #{expanded}")
        [{Path.basename(expanded, ".bin"), expanded}]

      true ->
        current = Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()
        [{Path.basename(current, ".bin"), current}]
    end
  end

  # ─── Ein Modell × Session messen ───────────────────────────────────────────

  defp run_one(model_label, model_path, session_name, context_mode, verbose) do
    Worker.Settings.put(:whisper_model, model_path)

    session_file = Path.join([@fixtures_base, "sessions", "#{session_name}.json"])
    turns_dir = Path.join([@fixtures_base, "turns"])

    unless File.exists?(session_file) do
      Mix.raise("Session-Datei nicht gefunden: #{session_file}")
    end

    turns = session_file |> File.read!() |> Jason.decode!()
    first_wav = Path.join(turns_dir, hd(turns)["file"])

    unless File.exists?(first_wav) do
      Mix.raise("""
      Fixture-Audio fehlt: #{first_wav}
      Zuerst ausführen: bash apps/worker/test/fixtures/stt/setup.sh
      """)
    end

    label =
      case context_mode do
        :multi_speaker -> "multi-speaker (Rolling-Context)"
        :no_context -> "no-context (Baseline)"
      end

    Mix.shell().info("")
    Mix.shell().info(String.duplicate("─", 70))
    Mix.shell().info("Modell: #{model_label}  | Session: #{session_name}  | Modus: #{label}")
    Mix.shell().info("Pfad: #{model_path}")
    Mix.shell().info(String.duplicate("─", 70))

    {results, _} =
      Enum.map_reduce(turns, "", fn turn, rolling_context ->
        wav = Path.join(turns_dir, turn["file"])
        expected = turn["expected"]

        prompt =
          case context_mode do
            :multi_speaker -> rolling_context
            :no_context -> ""
          end

        Worker.Settings.put(:whisper_initial_prompt, prompt)

        duration_s = wav_duration_s(wav)
        {us, result} = :timer.tc(fn -> Worker.Recording.Transcribe.transcribe_wav(wav) end)

        got =
          case result do
            {:ok, segs} -> segs |> Enum.map_join(" ", & &1["text"]) |> String.trim()
            {:error, reason} -> "[FEHLER: #{inspect(reason)}]"
          end

        wer = compute_wer(expected, got)
        ms = div(us, 1000)
        rtf = if duration_s > 0, do: ms / 1000.0 / duration_s, else: 0.0

        if verbose do
          Mix.shell().info("")

          Mix.shell().info(
            "  [#{turn["speaker"]}] WER=#{format_pct(wer)}  #{ms}ms  RTF=#{format_rtf(rtf)}  (#{format_duration(duration_s)} Audio)"
          )

          Mix.shell().info("  EXP: #{expected}")
          Mix.shell().info("  GOT: #{got}")
        else
          Mix.shell().info(
            "  #{String.pad_trailing(turn["speaker"], 12)} WER=#{format_pct(wer)}  #{ms}ms  RTF=#{format_rtf(rtf)}"
          )
        end

        new_context =
          case context_mode do
            :multi_speaker -> String.trim("#{rolling_context} #{got}")
            :no_context -> ""
          end

        {%{speaker: turn["speaker"], wer: wer, ms: ms, duration_s: duration_s, rtf: rtf},
         new_context}
      end)

    n = length(results)
    avg_wer = results |> Enum.map(& &1.wer) |> Enum.sum() |> Kernel./(n)
    avg_ms = results |> Enum.map(& &1.ms) |> Enum.sum() |> div(n)
    total_audio_s = results |> Enum.map(& &1.duration_s) |> Enum.sum()
    total_ms = results |> Enum.map(& &1.ms) |> Enum.sum()
    avg_rtf = if total_audio_s > 0, do: total_ms / 1000.0 / total_audio_s, else: 0.0

    Mix.shell().info(String.duplicate("─", 70))

    Mix.shell().info(
      "Avg WER: #{format_pct(avg_wer)}   Avg Latenz: #{avg_ms}ms/Turn   Avg RTF: #{format_rtf(avg_rtf)}   (#{format_duration(total_audio_s)} Audio total)"
    )

    %{
      model: model_label,
      session: session_name,
      avg_wer: avg_wer,
      avg_ms: avg_ms,
      avg_rtf: avg_rtf,
      total_audio_s: total_audio_s
    }
  end

  # ─── Matrix-Tabelle (Markdown) ─────────────────────────────────────────────

  defp print_matrix_table(matrix, sessions) do
    models = matrix |> Enum.map(& &1.model) |> Enum.uniq()

    header_cells = ["Modell" | Enum.flat_map(sessions, &["#{&1} WER", "#{&1} RTF"])]
    align_cells = ["---" | List.duplicate("---:", length(sessions) * 2)]

    Mix.shell().info("| " <> Enum.join(header_cells, " | ") <> " |")
    Mix.shell().info("|" <> Enum.join(align_cells, "|") <> "|")

    for model <- models do
      cells =
        for session <- sessions do
          row = Enum.find(matrix, &(&1.model == model and &1.session == session))

          if row do
            [format_pct(row.avg_wer), format_rtf(row.avg_rtf)]
          else
            ["—", "—"]
          end
        end
        |> List.flatten()

      Mix.shell().info("| " <> Enum.join([model | cells], " | ") <> " |")
    end
  end

  # ─── WAV-Header → Audio-Dauer ──────────────────────────────────────────────

  # Liest das WAV-Header-Prefix, parst die fmt-Chunk-Metadaten + scannt nach
  # dem "data"-Chunk. Robust auch gegen optionale LIST/INFO-Chunks (ffmpeg
  # schreibt diese mit Metadaten aus archive.org).
  defp wav_duration_s(wav_path) do
    {:ok, fd} = :file.open(wav_path, [:read, :binary])

    try do
      {:ok, header} = :file.read(fd, 4096)

      <<"RIFF", _file_size::little-32, "WAVE", "fmt ", _fmt_size::little-32,
        _audio_format::little-16, channels::little-16, sample_rate::little-32, _byte_rate::little-32,
        _block_align::little-16, bits_per_sample::little-16, _rest::binary>> = header

      case :binary.match(header, "data") do
        {pos, 4} ->
          <<_::binary-size(^pos + 4), data_size::little-32, _::binary>> = header
          bytes_per_sample = div(bits_per_sample, 8)
          data_size / (sample_rate * bytes_per_sample * channels)

        :nomatch ->
          raise "WAV ohne 'data' chunk in den ersten 4 KB: #{wav_path}"
      end
    after
      :file.close(fd)
    end
  end

  # ─── WER (Wort-Levenshtein) ────────────────────────────────────────────────

  defp compute_wer(reference, hypothesis) do
    ref = tokenize(reference)
    hyp = tokenize(hypothesis)
    if ref == [], do: 0.0, else: levenshtein(ref, hyp) / length(ref)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.split(~r/\s+/, trim: true)
  end

  defp levenshtein(a, b) do
    m = length(a)
    n = length(b)
    a = List.to_tuple(a)
    b = List.to_tuple(b)

    prev = List.to_tuple(Enum.to_list(0..n))

    prev =
      Enum.reduce(1..m, prev, fn i, prev ->
        row = List.to_tuple([i | Enum.map(1..n, fn _ -> 0 end)])

        row =
          Enum.reduce(1..n, row, fn j, row ->
            cost = if elem(a, i - 1) == elem(b, j - 1), do: 0, else: 1
            val = Enum.min([elem(prev, j) + 1, elem(row, j - 1) + 1, elem(prev, j - 1) + cost])
            put_elem(row, j, val)
          end)

        row
      end)

    elem(prev, n)
  end

  defp format_pct(wer), do: "#{Float.round(wer * 100, 1)}%"
  defp format_rtf(rtf), do: Float.round(rtf, 2) |> :erlang.float_to_binary(decimals: 2)

  defp format_duration(s) when s < 60, do: "#{Float.round(s, 1)}s"
  defp format_duration(s), do: "#{Float.round(s / 60, 1)}min"
end
