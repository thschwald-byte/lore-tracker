defmodule Mix.Tasks.Lore.Audit do
  @shortdoc "Linted Pre-PR-Gate: scant das Umbrella nach den 5 Anti-Pattern-Klassen (Issue #535)"

  @moduledoc """
  Linter gegen die fünf Anti-Pattern-Klassen, die in der Code-Review vom
  2026-06-04 als wiederkehrende Bug-Quellen identifiziert wurden:

  1. **Silent-Failure via unsupervised `Task.start/1`** — Crash im Task
     wird nicht propagiert; Caller wartet ggf. auf ein Signal das nie
     kommt. Pattern: jede `Task.start(`-Call außerhalb der Allowlist.
  2. **Sync `Reader.read/2` im LV-mount / on_mount** — blockiert UI bis
     15 s wenn der Worker langsam antwortet. Pattern: jeder
     `Reader.read`-Call in `apps/hub/lib/hub_web/live/**.ex` oder
     `sidebar_context.ex` außerhalb der Allowlist.
  3. **Hardcoded Event-Kind-Strings** — Drift-Risiko: Producer-Rename
     killt Subscriber still. Pattern: kind-Literale (z.B. `kind => Foo`-
     Form) außer in `Shared.Events` (Definition) und `Worker.Materializer`
     (Switch).
  4. **Timer-Leaks** — `Process.send_after(self(), …)` ohne
     `Process.cancel_timer` im selben File. LV-Restart hinterlässt
     Zombie-Timer.
  5. **Ignorierter `Worker.Intents.publish/1`-Return** — bei
     Hub-Disconnect wird zu `{:ok, :pending}` ohne Replay-Pfad. Pattern:
     `Worker.Intents.publish(` als top-level statement (kein `=` davor,
     kein `case`-Wrap, kein `|>`).

  ## Allowlist-Mechanik

  Statt jedem Vorkommen einzeln eine Allowlist-Zeile schreiben, fährt
  diese Task **diff gegen einen Baseline-Snapshot**:

      mix lore.audit --baseline    # befüllt .lore-audit-baseline.json
                                   # mit allen aktuellen Findings.
      mix lore.audit               # diff: schreit nur über NEUE Findings.

  Die Baseline ist git-committed (siehe Repo-Root). Bestehender Drift
  blockiert nicht — nur neue Vorkommen failen. Wer einen Eintrag in der
  Baseline FIXT, muss `--baseline` neu rufen, damit das Vorkommen aus
  der Baseline rausfällt (sonst bleibt's als "allowed" markiert).

  ## Warn-Mode (Default, Issue #557 Cut 1)

  Seit #557 ist der Default **warn-only**: neue Findings werden geloggt,
  aber Exit-Code bleibt 0 — CI grün, Output sichtbar. Grund: Sadowski et
  al. (CACM 2018) zeigen, dass blocking gates effektiv 0% false-positives
  brauchen, sonst werden sie ignoriert. Zwei reale Fehlalarme (#549/#550
  start_async-Wrapper, @moduledoc-Beispiele) haben die Hard-Block-These
  empirisch widerlegt.

  Hard-Block reaktivieren:

      mix lore.audit --strict       # exit ≠ 0 bei neuen Findings
      LORE_AUDIT_STRICT=1 mix lore.audit   # via Env-Var

  Cut 4 wird das Baseline-File durch `--since master` (diff-scoped)
  ablösen — bis dahin ist warn-mode der pragmatische Mittelweg.

  ## CI-Integration

  Im `.woodpecker.yml` läuft `mix lore.audit` (warn-only) nach `mix
  compile`. Findings werden geloggt, brechen die Pipeline aber nicht
  ab. Lokal kann `--strict` zur Pre-Push-Validierung gerufen werden.
  """

  use Mix.Task

  @baseline_file ".lore-audit-baseline.json"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [baseline: :boolean, strict: :boolean],
        aliases: [b: :baseline, s: :strict]
      )

    # --strict-Flag ODER ENV LORE_AUDIT_STRICT=1 reaktiviert Hard-Block.
    # Default = warn-only (Issue #557 Cut 1).
    strict? = opts[:strict] || System.get_env("LORE_AUDIT_STRICT") == "1"
    opts = Keyword.put(opts, :strict, strict?)

    findings = collect_all_findings()

    if opts[:baseline] do
      write_baseline(findings)
    else
      diff_against_baseline(findings, opts)
    end
  end

  # ─── Findings-Sammler ────────────────────────────────────────────

  @doc false
  def collect_all_findings do
    Enum.flat_map(
      [
        {:unsupervised_task_start, &check_unsupervised_task_start/0},
        {:sync_reader_in_mount, &check_sync_reader_in_mount/0},
        {:hardcoded_event_kind, &check_hardcoded_event_kind/0},
        {:timer_without_cleanup, &check_timer_without_cleanup/0},
        {:ignored_intents_publish, &check_ignored_intents_publish/0}
      ],
      fn {check, fun} ->
        Enum.map(fun.(), fn hit -> Map.put(hit, :check, check) end)
      end
    )
  end

  # 1. unsupervised Task.start — alle `Task.start(` außerhalb von
  # Mix-Tasks-Dirs.
  defp check_unsupervised_task_start do
    "apps/{hub,worker,shared}/lib/**/*.ex"
    |> grep_files(~r/^\s*Task\.start\(/)
    |> Enum.reject(fn %{file: f} -> f =~ "/mix/tasks/" end)
  end

  # 2. sync Reader.read in LV-mount / on_mount / sidebar_context.
  #
  # Issue #549/#550: ein `Reader.read` INNERHALB von `start_async`/
  # `handle_async`/`Task.async`/`assign_async` ist genau der GEWÜNSCHTE
  # Async-Pattern (läuft off-process, blockiert die GUI nicht). Solche
  # Zeilen werden ausgenommen.
  #
  # Issue #557 Cut 1: der ursprüngliche Filter prüfte nur das Match-Snippet
  # selbst → fing nur Inline-Wrapper ab. Multi-line-Wrapper
  #
  #     start_async(socket, :load, fn ->
  #       Reader.read(scope)        # <- match line, snippet kennt kein start_async
  #     end)
  #
  # wurde vom Snippet-Filter NICHT erkannt und flaggte den korrekten Fix.
  # Pre-Filter scant jetzt ~30 Zeilen rückwärts: findet er ein Wrapper-Token
  # bevor eine `def`/`defp`-Function-Boundary kommt → wir sind im Wrapper.
  @async_wrapper ~r/\b(start_async|handle_async|assign_async|Task\.(async|start|Supervisor))\b/
  @func_boundary ~r/^\s*defp?\s+\w+/
  @async_lookback_lines 30

  defp check_sync_reader_in_mount do
    files =
      ("apps/hub/lib/hub_web/{live,sidebar_context.ex,sidebar_context}/**/*.ex"
       |> Path.wildcard()
       |> Kernel.++(Path.wildcard("apps/hub/lib/hub_web/sidebar_context.ex")))
      |> Enum.uniq()
      |> Enum.filter(&File.exists?/1)

    Enum.flat_map(files, &scan_reader_hits/1)
  end

  defp scan_reader_hits(file) do
    lines =
      file
      |> File.read!()
      |> String.split("\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      cond do
        not Regex.match?(~r/Reader\.read\(/, line) -> []
        Regex.match?(@async_wrapper, line) -> []
        in_async_wrapper_context?(lines, idx) -> []
        true -> [%{file: file, line: idx, snippet: String.trim(line)}]
      end
    end)
  end

  defp in_async_wrapper_context?(lines, current_idx) do
    start_idx = max(current_idx - @async_lookback_lines, 1)

    Enum.reduce_while((current_idx - 1)..start_idx//-1, false, fn idx, _acc ->
      line = Enum.at(lines, idx - 1, "")

      cond do
        Regex.match?(@func_boundary, line) -> {:halt, false}
        Regex.match?(@async_wrapper, line) -> {:halt, true}
        true -> {:cont, false}
      end
    end)
  end

  # 3. hardcoded Event-Kind-Strings außer in Shared.Events + Materializer.
  #
  # Issue #557 Cut 1: zusätzlich `@moduledoc`-/`@doc`-Range-Pre-Filter, weil
  # Doku-Beispiele (z.B. `"kind" => "Foo"` in einem moduledoc-Code-Block)
  # sonst als Drift-Source geflaggt wurden (vgl. #549 events_ssot_guard).
  defp check_hardcoded_event_kind do
    pattern = ~r/"kind"\s*=>\s*"[A-Z][A-Za-z]+"/

    files =
      "apps/{hub,worker,shared}/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&File.exists?/1)
      |> Enum.reject(fn f ->
        String.contains?(f, "shared/lib/shared/events.ex") or
          String.contains?(f, "worker/lib/worker/materializer.ex")
      end)

    Enum.flat_map(files, fn file ->
      content = File.read!(file)
      doc_ranges = compute_doc_string_ranges(content)

      content
      |> scan_lines(pattern)
      |> Enum.reject(fn {line, snippet} ->
        line_in_any_range?(line, doc_ranges) or String.starts_with?(snippet, "#")
      end)
      |> Enum.map(fn {line, snippet} -> %{file: file, line: line, snippet: snippet} end)
    end)
  end

  @doc_open ~r/@(moduledoc|doc)\s+(?:"""|~S""")/
  @doc_close ~r/^\s*"""/

  # Liefert eine Liste von {start_line, end_line}-Ranges, in denen
  # @moduledoc/@doc-Triple-Quote-Strings stehen. Single-line @moduledoc
  # ("@moduledoc \"foo\"") wird ignoriert — die Regel matcht ohnehin nicht
  # auf einzeilige Strings.
  defp compute_doc_string_ranges(content) do
    lines = content |> String.split("\n") |> Enum.with_index(1)

    {ranges, _} =
      Enum.reduce(lines, {[], nil}, fn {line, idx}, {ranges, open_at} ->
        cond do
          is_nil(open_at) and Regex.match?(@doc_open, line) ->
            {ranges, idx}

          not is_nil(open_at) and Regex.match?(@doc_close, line) ->
            {[{open_at, idx} | ranges], nil}

          true ->
            {ranges, open_at}
        end
      end)

    ranges
  end

  defp line_in_any_range?(line, ranges) do
    Enum.any?(ranges, fn {start_l, end_l} -> line >= start_l and line <= end_l end)
  end

  # 4. Timer ohne Cleanup — Pattern: File enthält `Process.send_after`,
  # aber KEIN `Process.cancel_timer` im selben File.
  defp check_timer_without_cleanup do
    files =
      "apps/{hub,worker}/lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&File.exists?/1)

    Enum.flat_map(files, fn file ->
      content = File.read!(file)
      send_after_hits = scan_lines(content, ~r/Process\.send_after\(self\(\)/)

      has_cancel? = content =~ ~r/Process\.cancel_timer/

      if send_after_hits != [] and not has_cancel? do
        Enum.map(send_after_hits, fn {line, snippet} ->
          %{file: file, line: line, snippet: snippet}
        end)
      else
        []
      end
    end)
  end

  # 5. Ignored Worker.Intents.publish-Return — match auf Zeilen die mit
  # `Worker.Intents.publish(` BEGINNEN (modulo whitespace), ohne LHS.
  defp check_ignored_intents_publish do
    "apps/{hub,worker}/lib/**/*.ex"
    |> grep_files(~r/^\s*Worker\.Intents\.publish\(/)
  end

  # ─── Grep + Scan-Helper ───────────────────────────────────────────

  defp grep_files(pattern, regex) do
    pattern
    |> Path.wildcard()
    |> Enum.filter(&File.exists?/1)
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      scan_lines(content, regex)
      |> Enum.map(fn {line, snippet} ->
        %{file: file, line: line, snippet: snippet}
      end)
    end)
  end

  defp scan_lines(content, regex) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, idx} ->
      if Regex.match?(regex, line), do: [{idx, String.trim(line)}], else: []
    end)
  end

  # ─── Baseline / Diff ──────────────────────────────────────────────

  defp write_baseline(findings) do
    keys = Enum.map(findings, &finding_key/1)
    sorted = keys |> Enum.uniq() |> Enum.sort()

    payload = %{
      "version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "count" => length(sorted),
      "findings" => sorted
    }

    File.write!(@baseline_file, Jason.encode!(payload, pretty: true) <> "\n")

    Mix.shell().info(
      "✓ lore.audit baseline geschrieben (#{length(sorted)} Findings) → #{@baseline_file}"
    )
  end

  @doc false
  def diff_against_baseline(findings, opts \\ []) do
    baseline = load_baseline()
    current_keys = MapSet.new(findings, &finding_key/1)

    new_findings =
      Enum.reject(findings, fn f -> finding_key(f) in baseline end)

    fixed_count =
      Enum.count(baseline, fn k -> k not in current_keys end)

    cond do
      new_findings != [] ->
        report_failures(new_findings, fixed_count)

        if opts[:strict] do
          Mix.raise("lore.audit: #{length(new_findings)} new violation(s)")
        else
          Mix.shell().info(
            "ℹ warn-mode: #{length(new_findings)} new violation(s) logged — use `--strict` or `LORE_AUDIT_STRICT=1` to fail CI. See #557 for rationale."
          )
        end

      fixed_count > 0 ->
        Mix.shell().info(
          "✓ lore.audit clean (#{fixed_count} previously-allowlisted hit(s) gone — run `mix lore.audit --baseline` to trim)"
        )

      true ->
        Mix.shell().info("✓ lore.audit clean")
    end
  end

  defp load_baseline do
    case File.read(@baseline_file) do
      {:ok, body} ->
        body
        |> Jason.decode!()
        |> Map.get("findings", [])
        |> MapSet.new()

      {:error, :enoent} ->
        Mix.shell().info(
          "⚠ kein #{@baseline_file} gefunden — Baseline-Mode mit `mix lore.audit --baseline` initialisieren."
        )

        MapSet.new()
    end
  end

  @doc false
  def finding_key(%{check: check, file: file, snippet: snippet}) do
    # file + check + snippet — line-Nummer wird bewusst ausgelassen
    # (refactor-resilient: ein Hit der von line 100 nach line 105 wandert
    # gilt weiter als selber Eintrag).
    "#{check} :: #{file} :: #{snippet}"
  end

  defp report_failures(new_findings, fixed_count) do
    Mix.shell().error("✗ lore.audit: #{length(new_findings)} new violation(s):\n")

    new_findings
    |> Enum.group_by(& &1.check)
    |> Enum.each(fn {check, hits} ->
      Mix.shell().error("  [#{check}]  (#{length(hits)} hit(s))")

      Enum.each(hits, fn h ->
        Mix.shell().error("    #{h.file}:#{h.line}  ·  #{truncate(h.snippet, 90)}")
      end)

      Mix.shell().error("")
    end)

    Mix.shell().error(
      "Wenn das Verhalten korrekt ist und der Hit erlaubt sein soll: " <>
        "`mix lore.audit --baseline` rebaselined die Allowlist."
    )

    if fixed_count > 0 do
      Mix.shell().info("(Nebenbei: #{fixed_count} previously-allowlisted hit(s) sind weg — gut.)")
    end
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
end
