defmodule Mix.Tasks.Lore.Stage.Goethe do
  @shortdoc "Issue #394: Goethe-Live-vs-Confirmed-Vergleichs-Stage treiben + Report"
  @moduledoc """
  Treibt die Goethe-Faust-Gartenszene durch den **Live-Pfad** eines laufenden
  PR-Test-Workers (zwei Degradationsstufen → zwei Kampagnen) und schreibt einen
  Live-vs-Confirmed-WER-Report. Reproduktion/Vergleich für Issue #394.

  Voraussetzungen:

    1. Fixtures gebaut: `bash apps/worker/test/fixtures/stt/setup.sh`
       (baut u.a. `multitrack/gartenszene/{noisy_moderate,noisy_heavy}/`).
    2. Ein laufender Stack: `mix lore.pr_test <branch>` (ohne --seed) — Hub+Worker.

  Der Task startet sich als verstecktes Distribution-Node, findet den
  Worker-Node via epmd und ruft `Worker.Stage.GoetheLive.run/3` per RPC. Der
  Worker liest die (gitignorierten) Audio-Fixtures aus DIESEM Clone (absoluter
  `fixtures_root`-Pfad wird mitgegeben — das PR-Test-Worktree hat sie nicht).

  Erzeugt zwei Kampagnen:

    * `goethe1` — Variante `noisy_moderate`
    * `goethe2` — Variante `noisy_heavy`

  Danach: Browser auf den Hub-Port → beide Kampagnen zeigen `live`- + `confirmed`-
  Utterances nebeneinander. Report unter `/tmp/goethe-stage-report.txt`.

  ## Optionen

    * `--node <sname>`   — Worker-Node-Sname (Default: via epmd erkannt, matcht `worker`)
    * `--variant <v>`    — nur eine Variante fahren (`noisy_moderate`|`noisy_heavy`|clean|realistic|overlap)
    * `--timeout <min>`  — Whisper/Post-Roll-Timeout pro Session in Minuten (Default 12)
  """

  use Mix.Task

  alias Worker.MultiSourceEval.Wer

  @session_file "apps/worker/test/fixtures/stt/faust/sessions/gartenszene.json"
  @fixtures_root "apps/worker/test/fixtures/stt/faust"
  @report_path "/tmp/goethe-stage-report.txt"

  @runs [
    {"goethe1", "Goethe 1 — moderat verrauscht", "noisy_moderate"},
    {"goethe2", "Goethe 2 — heftig verrauscht", "noisy_heavy"}
  ]

  @impl true
  def run(argv) do
    if Mix.env() == :prod do
      Mix.raise("lore.stage.goethe ist nicht für MIX_ENV=prod gedacht.")
    end

    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [node: :string, variant: :string, timeout: :integer, report_only: :boolean]
      )

    timeout_ms = (opts[:timeout] || 12) * 60_000
    session = load_session()

    runs =
      case opts[:variant] do
        nil -> @runs
        v -> [{"goethe-#{v}", "Goethe — #{v}", v}]
      end

    node = resolve_worker_node(opts[:node])
    connect_distribution!(node)

    results =
      if opts[:report_only] do
        report_only_results(node, runs)
      else
        fixtures_root = Path.expand(@fixtures_root)
        ensure_fixtures!(session, fixtures_root, opts[:variant])
        drive_runs(node, session, runs, timeout_ms, fixtures_root)
      end

    report = build_report(session, results)
    File.write!(@report_path, report)
    Mix.shell().info("\n" <> report)
    Mix.shell().info("\nReport geschrieben: #{@report_path}")
  end

  # Treibt jede Variante durch GoetheLive.run (Feed + Transcribe).
  defp drive_runs(node, session, runs, timeout_ms, fixtures_root) do
    Enum.map(runs, fn {cid, cname, variant} ->
      Mix.shell().info("\n=== Treibe #{cid} (#{variant}) auf #{node} ===")

      case :rpc.call(
             node,
             Worker.Stage.GoetheLive,
             :run,
             [
               session,
               variant,
               [
                 campaign_id: cid,
                 campaign_name: cname,
                 timeout_ms: timeout_ms,
                 fixtures_root: fixtures_root
               ]
             ],
             timeout_ms + 60_000
           ) do
        {:ok, result} ->
          Mix.shell().info("  fertig: #{length(result.utterances)} Utterances")
          {cid, cname, variant, result}

        {:badrpc, reason} ->
          Mix.raise("RPC an #{node} fehlgeschlagen: #{inspect(reason)}")

        {:error, reason} ->
          Mix.raise("GoetheLive.run(#{variant}) fehlgeschlagen: #{inspect(reason)}")
      end
    end)
  end

  # --report-only: nur den Report aus bereits eingespielten Kampagnen
  # regenerieren (jüngste Session pro Kampagne), ohne erneut Audio zu feeden.
  defp report_only_results(node, runs) do
    Enum.map(runs, fn {cid, cname, variant} ->
      sessions = :rpc.call(node, Worker.Repo, :list_sessions, [cid])

      case sessions do
        [_ | _] = ss ->
          sid = ss |> List.last() |> Map.fetch!(:id)
          utts = :rpc.call(node, Worker.Repo, :list_utterances, [sid])
          {cid, cname, variant, %{session_id: sid, utterances: utts}}

        _ ->
          Mix.raise(
            "Keine Session für Kampagne #{cid} gefunden (erst ohne --report-only fahren)."
          )
      end
    end)
  end

  # ─── Fixtures / Session ─────────────────────────────────────────────

  defp load_session do
    path = Path.expand(@session_file)

    case File.read(path) do
      {:ok, raw} -> Jason.decode!(raw)
      {:error, reason} -> Mix.raise("Session-JSON nicht lesbar (#{inspect(reason)}): #{path}")
    end
  end

  defp ensure_fixtures!(session, fixtures_root, variant) do
    name = Map.fetch!(session, "name")
    variants = if variant, do: [variant], else: ["noisy_moderate", "noisy_heavy"]

    missing =
      for v <- variants,
          {spk, _did} <- Map.fetch!(session, "speakers"),
          wav = Path.join([fixtures_root, "multitrack", name, v, "#{spk}.wav"]),
          not File.exists?(wav),
          do: wav

    unless missing == [] do
      Mix.raise(
        "Audio-Fixtures fehlen (#{length(missing)} Dateien, z.B. #{hd(missing)}).\n" <>
          "Erst bauen: bash apps/worker/test/fixtures/stt/setup.sh"
      )
    end
  end

  # ─── Distribution / Node-Discovery ──────────────────────────────────

  defp resolve_worker_node(nil) do
    {:ok, host} = :inet.gethostname()

    case :net_adm.names() do
      {:ok, names} ->
        # WICHTIG: NIEMALS den prod-Daemon (`worker_prod`) treffen — die Stage
        # erzeugt Kampagnen + speist Audio ein. Nur PR-Test-Worker (Naming
        # `lore-issue-<N>-port-<PORT>-worker-N`) sind erlaubt: matcht "worker",
        # enthält "port-", und NICHT "prod".
        candidates =
          names
          |> Enum.map(fn {n, _port} -> to_string(n) end)
          |> Enum.filter(fn n ->
            String.contains?(n, "worker") and String.contains?(n, "port-") and
              not String.contains?(n, "prod")
          end)

        case candidates do
          [sname | _] ->
            :"#{sname}@#{host}"

          [] ->
            Mix.raise(
              "Keinen PR-Test-Worker-Node via epmd gefunden (Naming: …-port-<PORT>-worker-N).\n" <>
                "Läuft ein Stack? `mix lore.pr_test <branch>` (ohne --seed).\n" <>
                "Gefundene Nodes: #{inspect(names)}. Sonst --node <sname> explizit angeben.\n" <>
                "(worker_prod wird bewusst NICHT automatisch gewählt — kein Prod-Schreibzugriff.)"
            )
        end

      {:error, reason} ->
        Mix.raise("epmd nicht erreichbar (#{inspect(reason)}). Läuft ein Stack?")
    end
  end

  defp resolve_worker_node(sname) do
    {:ok, host} = :inet.gethostname()
    node = if String.contains?(sname, "@"), do: String.to_atom(sname), else: :"#{sname}@#{host}"

    # Sicherheitsnetz: auch bei explizitem --node den Prod-Daemon verweigern.
    if String.contains?(to_string(node), "prod") do
      Mix.raise(
        "Refuse: #{node} sieht nach Prod-Daemon aus. Die Stage darf nicht gegen prod laufen."
      )
    end

    node
  end

  defp connect_distribution!(node) do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:lore_goethe_driver, :shortnames])
    end

    cookie_path = Path.join(System.user_home!(), ".erlang.cookie")

    if File.exists?(cookie_path) do
      cookie = cookie_path |> File.read!() |> String.trim() |> String.to_atom()
      Node.set_cookie(cookie)
    end

    case Node.connect(node) do
      true -> :ok
      _ -> Mix.raise("Connect zu #{node} fehlgeschlagen (Cookie? Node läuft?).")
    end
  end

  # ─── Report ─────────────────────────────────────────────────────────

  defp build_report(session, results) do
    speakers = Map.fetch!(session, "speakers")
    # name → did und did → name
    name_to_did = Map.new(speakers)
    did_to_name = Map.new(speakers, fn {n, d} -> {d, n} end)
    turns = Map.fetch!(session, "turns")

    header =
      [
        "================================================================",
        "  Goethe-Live-vs-Confirmed-Report (Issue #394)",
        "  Szene: #{Map.fetch!(session, "name")} — #{Map.get(session, "source", "")}",
        "================================================================"
      ]

    sections =
      Enum.map(results, fn {cid, cname, variant, result} ->
        section_for_run(cid, cname, variant, result, turns, name_to_did, did_to_name)
      end)

    Enum.join(header ++ ["" | sections], "\n")
  end

  defp section_for_run(cid, cname, variant, result, turns, name_to_did, did_to_name) do
    utts = result.utterances
    {live, confirmed} = Enum.split_with(utts, &(status_of(&1) == "live"))

    per_live = per_speaker_alignment(turns, live, name_to_did)
    per_conf = per_speaker_alignment(turns, confirmed, name_to_did)

    live_wer = Wer.global_wer(per_live)
    conf_wer = Wer.global_wer(per_conf)

    speaker_lines =
      per_conf
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn did ->
        name = Map.get(did_to_name, did, did)
        lw = wer_of(per_live, did)
        cw = wer_of(per_conf, did)

        [
          "  Sprecher #{name} (#{did}):",
          "    live      WER=#{pct(lw)}  | #{speaker_text(live, did)}",
          "    confirmed WER=#{pct(cw)}  | #{speaker_text(confirmed, did)}",
          "    erwartet:        #{expected_for(turns, did, name_to_did)}"
        ]
      end)
      |> List.flatten()

    [
      "----------------------------------------------------------------",
      "  #{cid}  (#{cname}, variant=#{variant})",
      "    Utterances: #{length(utts)}  (live=#{length(live)}, confirmed=#{length(confirmed)})",
      "    Aggregat-WER:  live=#{pct(live_wer)}  confirmed=#{pct(conf_wer)}  Δ=#{pct(live_wer - conf_wer)}",
      ""
    ]
    |> Kernel.++(speaker_lines)
    |> Enum.join("\n")
  end

  # Map did → align_speaker-Ergebnis (nur Sprecher mit erwarteten Turns).
  defp per_speaker_alignment(turns, utts, name_to_did) do
    turns_by_did =
      turns
      |> Enum.group_by(fn turn -> Map.get(name_to_did, turn["speaker"]) end)

    utts_by_did = Enum.group_by(utts, &did_of/1)

    turns_by_did
    |> Enum.reject(fn {did, _} -> is_nil(did) end)
    |> Map.new(fn {did, spk_turns} ->
      spk_utts = utts_by_did |> Map.get(did, []) |> Enum.sort_by(&ts_of/1)
      {did, Wer.align_speaker(spk_turns, spk_utts)}
    end)
  end

  defp wer_of(per_speaker, did) do
    case Map.get(per_speaker, did) do
      %{edit_count: e, ref_words: rw} when length(rw) > 0 -> e / length(rw)
      _ -> 0.0
    end
  end

  defp speaker_text(utts, did) do
    utts
    |> Enum.filter(&(did_of(&1) == did))
    |> Enum.sort_by(&ts_of/1)
    |> Enum.map(&text_of/1)
    |> Enum.join(" ⏐ ")
    |> truncate(160)
  end

  defp expected_for(turns, did, name_to_did) do
    turns
    |> Enum.filter(fn turn -> Map.get(name_to_did, turn["speaker"]) == did end)
    |> Enum.map(& &1["expected"])
    |> Enum.join(" ⏐ ")
    |> truncate(160)
  end

  # ─── Utterance-Feld-Zugriff ─────────────────────────────────────────
  # Worker.Repo.list_utterances liefert IMMER Atom-Key-Maps (:status, :text,
  # :discord_id, :timestamp). Direkt zugreifen — KEIN String.to_existing_atom
  # (das schlug im Mix-Task-Node fehl → alles fälschlich als "confirmed").

  # :status kommt als ATOM (:live/:confirmed) aus dem Materializer — to_string
  # normalisiert (matcht auch falls je ein String kommt).
  defp status_of(u), do: to_string(Map.get(u, :status) || Map.get(u, "status") || "confirmed")
  defp did_of(u), do: Map.get(u, :discord_id) || Map.get(u, "discord_id")
  defp ts_of(u), do: Map.get(u, :timestamp) || Map.get(u, "timestamp") || ""
  defp text_of(u), do: Map.get(u, :text) || Map.get(u, "text") || ""

  defp pct(f) when is_number(f), do: "#{Float.round(f * 100, 1)}%"
  defp pct(_), do: "n/a"

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: String.slice(s, 0, n) <> "…"
end
