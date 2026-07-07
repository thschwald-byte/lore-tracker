defmodule Mix.Tasks.Lore.BenchLlmStage2 do
  use Mix.Task

  @shortdoc "Stage-2 (Session-Summary) LLM Performance-Baseline pro Modell × Prompt-Größe"

  @moduledoc """
  Misst Wall-Clock + Outcome + Output-Größe von Stage 2 (Session-Resümee) pro
  Modell auf 3 Prompt-Größen (short/medium/long — selbe Texte wie der UI-
  Probelauf in #74).

  **Warum direkt statt Probelauf-Sweep?** Issue #91 ist auf #201 (Stage-
  Isolation mit Goldstandard-Pre-Seed) blockiert, *wenn* man Stages 3+4 fair
  messen will (deren Input ist das Output von Stage 2, also nicht reproduzier-
  bar zwischen Modellen). Für Stage 2 alleine ist der Input deterministisch
  (synthetische Utterance-Liste) — also kann man jetzt messen, ohne #201.

  Im Unterschied zum Probelauf-Sweep:
  - geht direkt durch `Worker.LLM.complete(:summary, prompt, opts)`,
    überspringt Stage 3+4 (spart pro Run ~5-30 min)
  - kein Mnesia-Seed, kein Pipeline-Roundtrip, kein Hub-Event-Roundtrip
  - reine Mess-Tabelle: model × prompt_size × wall-clock + outcome

  ## Verwendung

      mix lore.bench_llm_stage2                                # Default-Modelle, alle pulled
      mix lore.bench_llm_stage2 --models qwen2.5:0.5b,qwen2.5:7b
      mix lore.bench_llm_stage2 --samples 3                    # 3 Wiederholungen pro Zelle
      mix lore.bench_llm_stage2 --skip-long                    # nur short + medium

  ## Voraussetzungen

  - Ollama läuft (default `http://localhost:11434`)
  - Modelle gepullt: `ollama pull qwen2.5:7b` etc.
  - Settings konfiguriert: `:backend_stage2 == :local`, `:http_timeout_ms`
    großzügig genug (default 20 min reicht für 30B-Modelle)

  Refuses :prod.
  """

  alias Worker.LLM
  alias Worker.Settings

  @default_models [
    "qwen2.5:0.5b",
    "qwen2.5:7b",
    "mistral-nemo:12b",
    "qwen3:30b-a3b"
  ]

  # Selbe synthetische Texte wie Worker.Probelauf — damit Werte vergleichbar bleiben.
  @short_utterances [
    "Wir betreten die verlassene Schenke. Der Wirt sieht uns misstrauisch an.",
    "Ich frage ihn nach dem verschwundenen Karawanenboten.",
    "Er nuschelt etwas von Banditen im Schwarzen Wald.",
    "Mein Halbork zückt die Streitaxt und legt eine Goldmünze auf den Tresen.",
    "Der Wirt wird redseliger. Er nennt einen Namen: Gardal der Krummbein.",
    "Wir bedanken uns und ziehen nordwärts.",
    "Auf dem Weg sehe ich Hufabdrücke — vier Reiter, zwei Tage alt.",
    "Die Elfin schleicht voraus, kundschaftet die nächste Lichtung aus.",
    "Sie kommt zurück: drei Banditen am Lagerfeuer, schlafend.",
    "Wir schleichen uns an. Stille, dann ein scharfer Pfiff — die Elfin gibt das Zeichen."
  ]

  @impl Mix.Task
  def run(args) do
    if Mix.env() == :prod do
      Mix.raise("Refuse :prod — bench-task ist dev/test-only")
    end

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          models: :string,
          samples: :integer,
          skip_long: :boolean
        ]
      )

    Application.put_env(:worker, :no_browser, true)
    Application.ensure_all_started(:worker)

    samples = opts[:samples] || 2
    skip_long = opts[:skip_long] || false

    requested =
      case opts[:models] do
        nil -> @default_models
        s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    available =
      case Worker.LLM.Local.list_models() do
        {:ok, list} -> list
        {:error, reason} -> Mix.raise("Ollama unreachable: #{inspect(reason)}")
      end

    models =
      Enum.filter(requested, fn m ->
        if m in available do
          true
        else
          Mix.shell().info("[skip] #{m} — nicht in Ollama gepullt (`ollama pull #{m}`)")
          false
        end
      end)

    if models == [] do
      Mix.raise("Keines der angefragten Modelle ist gepullt. Verfügbar: #{Enum.join(available, ", ")}")
    end

    sessions =
      [
        {"short", @short_utterances},
        {"medium", Enum.flat_map(1..3, fn ep -> Enum.map(@short_utterances, &"[Episode #{ep}] #{&1}") end)}
      ] ++
        if skip_long do
          []
        else
          [{"long", Enum.flat_map(1..10, fn ep -> Enum.map(@short_utterances, &"[Tag #{ep}] #{&1}") end)}]
        end

    Mix.shell().info("LLM Stage-2 Bench — Modelle: #{Enum.join(models, ", ")}  |  Samples: #{samples}")
    Mix.shell().info(String.duplicate("═", 75))

    # Snapshot um die User-Settings am Ende restoren zu können.
    # #451 Track C: gewinnender Key für :local ist der pro-Backend-Key.
    model_key = Settings.model_key(2, :local)
    original_model = Settings.model_for(2, :local)
    original_backend = Settings.get(:backend_stage2, :local)
    Settings.put(:backend_stage2, :local)

    matrix =
      try do
        for model <- models, {sess_label, utterances} <- sessions do
          measure_cell(model, sess_label, utterances, samples)
        end
      after
        if original_model, do: Settings.put(model_key, original_model)
        Settings.put(:backend_stage2, original_backend)
      end

    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 75))
    Mix.shell().info("Matrix-Zusammenfassung (Markdown — kopierbar nach docs/Performance.md):")
    Mix.shell().info("")
    print_matrix(matrix, sessions, models)
  end

  # ─── Mess-Kern ────────────────────────────────────────────────────────────

  defp measure_cell(model, sess_label, utterances, samples) do
    Settings.put(Settings.model_key(2, :local), model)
    prompt = build_summary_prompt(utterances)

    Mix.shell().info("")
    Mix.shell().info("· #{model}  |  #{sess_label} (#{length(utterances)} utts, ~#{div(byte_size(prompt), 100)}00 chars)")

    # Warm-up Call: erste Call lädt das Modell in Ollama-RAM (cold-start kann
    # 2-15s extra kosten je nach Modellgröße). Steady-State ist die Metrik
    # die wir messen wollen.
    _ = LLM.complete(:summary, prompt, num_ctx: 8192)

    runs =
      for n <- 1..samples do
        {us, result} = :timer.tc(fn -> LLM.complete(:summary, prompt, num_ctx: 8192) end)
        ms = div(us, 1000)

        {outcome, out_size} =
          case result do
            {:ok, summary} when is_binary(summary) ->
              trimmed = String.trim(summary)

              if String.length(trimmed) < 20 do
                {:empty_output, byte_size(trimmed)}
              else
                {:ok, byte_size(trimmed)}
              end

            {:error, :timeout} -> {:timeout, 0}
            {:error, {:no_model_configured, _}} -> {:no_model, 0}
            {:error, reason} -> {{:error, reason}, 0}
          end

        Mix.shell().info("  sample #{n}/#{samples}: #{ms}ms  outcome=#{inspect(outcome)}  output=#{out_size}B")
        %{ms: ms, outcome: outcome, output_size: out_size}
      end

    times = Enum.map(runs, & &1.ms)
    median_ms = median(times)
    avg_output = if Enum.empty?(runs), do: 0, else: div(Enum.sum(Enum.map(runs, & &1.output_size)), length(runs))

    success_rate =
      runs
      |> Enum.count(&(&1.outcome == :ok))
      |> Kernel./(length(runs))

    %{
      model: model,
      session: sess_label,
      utterance_count: length(utterances),
      median_ms: median_ms,
      success_rate: success_rate,
      avg_output: avg_output,
      runs: runs
    }
  end

  # ─── Prompt-Builder (1:1 wie Worker.Recording.Pipeline.build_summary_prompt) ───

  defp build_summary_prompt(utterances) do
    transcript =
      utterances
      |> Enum.with_index()
      |> Enum.map(fn {text, i} -> "spieler-#{rem(i, 4) + 1}: #{text}" end)
      |> Enum.join("\n")

    """
    Verdichte das folgende Transkript zu einem Resümee auf Deutsch
    (3-6 Sätze). Überspringe Out-of-Game-Smalltalk (Pizza, Pausen,
    Regelfragen). Antworte NUR mit dem Resümee, keine Vorrede.

    Transkript:
    #{transcript}

    FAKTENTREUE (oberste Regel, überstimmt alle Stil-Vorgaben):
    - Verwende NUR Namen, Orte und Ereignisse die explizit im Transkript oben stehen.
    - Wenn ein Detail nicht im Transkript steht, lass es weg — fülle keine Lücken aus.
    - Wenn das Material nicht für die angefragte Länge reicht, schreibe weniger.
    - Keine inneren Monologe, keine erfundenen Nebenfiguren, keine ausgeschmückten Szenen.
    """
  end

  # ─── Output ───────────────────────────────────────────────────────────────

  defp print_matrix(matrix, sessions, models) do
    sess_labels = Enum.map(sessions, &elem(&1, 0))

    header = ["Modell" | Enum.flat_map(sess_labels, &["#{&1} median", "#{&1} success"])]
    align = ["---" | List.duplicate("---:", length(sess_labels) * 2)]

    Mix.shell().info("| " <> Enum.join(header, " | ") <> " |")
    Mix.shell().info("|" <> Enum.join(align, "|") <> "|")

    for model <- models do
      cells =
        for sess <- sess_labels do
          row = Enum.find(matrix, &(&1.model == model and &1.session == sess))

          if row do
            [format_ms(row.median_ms), format_pct(row.success_rate)]
          else
            ["—", "—"]
          end
        end
        |> List.flatten()

      Mix.shell().info("| " <> Enum.join([model | cells], " | ") <> " |")
    end
  end

  defp median([]), do: 0

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)

    if rem(n, 2) == 1 do
      Enum.at(sorted, div(n, 2))
    else
      (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) |> div(2)
    end
  end

  defp format_ms(ms) when ms < 1000, do: "#{ms}ms"
  defp format_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_ms(ms), do: "#{Float.round(ms / 60_000, 1)}min"

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
