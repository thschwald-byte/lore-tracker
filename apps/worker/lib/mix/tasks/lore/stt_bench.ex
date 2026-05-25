defmodule Mix.Tasks.Lore.SttBench do
  use Mix.Task

  @shortdoc "WER-Benchmark für STT-Pipeline gegen Faust-Fixtures"

  @moduledoc """
  Misst Word-Error-Rate (WER) der Whisper-Transkription gegen Ground-Truth-Texte
  aus der Librivox-Dramatischen-Lesung von Goethe Faust I (CC0).

  Voraussetzungen:
    - whisper-cli im PATH
    - Whisper-Modell unter ~/.cache/whisper/ (oder via Worker.Settings)
    - Fixture-Audio erzeugt: bash apps/worker/test/fixtures/stt/setup.sh

  ## Verwendung

      mix lore.stt_bench                            # Default: gartenszene
      mix lore.stt_bench --session hexenkueche
      mix lore.stt_bench --verbose
      mix lore.stt_bench --multi-speaker            # Rolling-Context aktiviert
      mix lore.stt_bench --no-context               # jeder Turn isoliert (Baseline)
      mix lore.stt_bench --model ~/.cache/whisper/ggml-base.bin

  ## Multi-Speaker-Test

  --multi-speaker simuliert den Rolling-Context-Mechanismus: Turn N bekommt
  den transkribierten Text von Turn 1..N-1 als Whisper-Prompt. Das testet ob
  Eigennamen (Mephistopheles, Gretchen, Marthe) in späteren Turns besser
  erkannt werden, sobald sie im Kontext aufgetaucht sind.

  --no-context ist die Vergleichsbasis: jeder Turn wird ohne Prompt transkribiert,
  wie heute im Produktivbetrieb ohne Issue B.
  """

  @fixtures_base "apps/worker/test/fixtures/stt/faust"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          session: :string,
          verbose: :boolean,
          multi_speaker: :boolean,
          no_context: :boolean,
          model: :string
        ]
      )

    session_name = opts[:session] || "gartenszene"
    verbose = opts[:verbose] || false

    context_mode =
      cond do
        opts[:multi_speaker] -> :multi_speaker
        opts[:no_context] -> :no_context
        true -> :no_context
      end

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

    Application.put_env(:worker, :no_browser, true)
    Application.ensure_all_started(:worker)

    if model_path = opts[:model] do
      expanded = Path.expand(model_path)
      unless File.exists?(expanded), do: Mix.raise("Modell nicht gefunden: #{expanded}")
      Worker.Settings.put(:whisper_model, expanded)
    end

    model_display =
      Worker.Settings.get(:whisper_model) || Worker.Settings.whisper_model_fallback()

    label =
      case context_mode do
        :multi_speaker -> "multi-speaker (Rolling-Context)"
        :no_context -> "no-context (Baseline)"
      end

    Mix.shell().info("STT Bench — Session: #{session_name} | Modus: #{label}")
    Mix.shell().info("Modell: #{model_display}")
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

        if prompt != "" do
          Worker.Settings.put(:whisper_initial_prompt, prompt)
        else
          Worker.Settings.put(:whisper_initial_prompt, "")
        end

        {us, result} = :timer.tc(fn -> Worker.Recording.Transcribe.transcribe_wav(wav) end)

        got =
          case result do
            {:ok, segs} -> segs |> Enum.map_join(" ", & &1["text"]) |> String.trim()
            {:error, reason} -> "[FEHLER: #{inspect(reason)}]"
          end

        wer = compute_wer(expected, got)
        ms = div(us, 1000)

        if verbose do
          Mix.shell().info("")
          Mix.shell().info("  [#{turn["speaker"]}] WER=#{format_pct(wer)} #{ms}ms")
          Mix.shell().info("  EXP: #{expected}")
          Mix.shell().info("  GOT: #{got}")
        else
          Mix.shell().info("  #{String.pad_trailing(turn["speaker"], 12)} WER=#{format_pct(wer)}  #{ms}ms")
        end

        new_context =
          case context_mode do
            :multi_speaker -> String.trim("#{rolling_context} #{got}")
            :no_context -> ""
          end

        {%{speaker: turn["speaker"], wer: wer, ms: ms, expected: expected, got: got}, new_context}
      end)

    Worker.Settings.put(:whisper_initial_prompt, "")

    avg_wer = results |> Enum.map(& &1.wer) |> Enum.sum() |> Kernel./(length(results))
    avg_ms = results |> Enum.map(& &1.ms) |> Enum.sum() |> div(length(results))

    Mix.shell().info(String.duplicate("─", 70))
    Mix.shell().info("Avg WER: #{format_pct(avg_wer)}   Avg Latenz: #{avg_ms}ms/Turn")
  end

  # ─── WER (Wort-Levenshtein) ───────────────────────────────────────────────

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
end
