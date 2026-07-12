defmodule Worker.Repo.Artifacts do
  @moduledoc """
  Issue #719 (Fortsetzung des #581-Splits): die Reads der GENERIERTEN
  Pipeline-Artefakte aus `Worker.Repo` — Resümees, Fakten, Faithfulness,
  Epos (+History), Chronik (+Kalender/Anker, #724) und die Probelauf-Runs.
  Call-Sites bleiben `Worker.Repo.x()` (Façade-defdelegate).
  """

  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo,
    except: [
      get_epos_entry: 1,
      list_epos_history: 1,
      list_epos_chapters: 1,
      get_session_summary: 1,
      get_session_facts: 1,
      list_campaign_facts: 1,
      list_session_summaries: 1,
      get_faithfulness_score: 1,
      list_faithfulness_scores: 1,
      list_chronik_entries: 1,
      get_campaign_calendar: 1,
      get_session_anchor_day: 1,
      get_session_anchor: 1,
      derive_chronik_sort_tuple: 1,
      last_probelauf_run: 0,
      all_probelauf_runs: 0,
      last_probelauf_sweep: 0,
      last_n_probelauf_sweeps: 0,
      last_n_probelauf_sweeps: 1
    ]

  # ─── epos ───────────────────────────────────────────────────────

  @doc "Current Epos entry for a campaign (or nil)."
  def get_epos_entry(entry_id) when is_binary(entry_id) do
    case transaction(fn -> :mnesia.read(S.epos_entries(), entry_id) end) do
      # Issue #114: 7-Tupel mit source_refs trailing.
      [{_, id, cid, parent, content, updated, refs}] ->
        %{
          id: id,
          campaign_id: cid,
          parent_id: parent,
          content_md: content,
          updated_at: updated,
          source_refs: refs || []
        }

      [] ->
        nil
    end
  end

  @doc """
  Issue #752: die per-Session-Epos-Kapitel einer Campaign (Rows mit
  `parent_id == campaign_id`, die Legacy-Single-Row hat `entry_id ==
  campaign_id` + parent nil und ist NICHT dabei). Sortiert nach
  `session.number` (entry_id = session_id); Kapitel zu gelöschten Sessions
  sortieren ans Ende.
  """
  def list_epos_chapters(campaign_id) when is_binary(campaign_id) do
    order =
      campaign_id |> list_sessions() |> Map.new(fn s -> {s.id, s.number} end)

    transaction(fn ->
      :mnesia.index_read(S.epos_entries(), campaign_id, :campaign_id)
    end)
    |> Enum.filter(fn {_, entry_id, _cid, parent, _md, _upd, _refs} ->
      parent == campaign_id and entry_id != campaign_id
    end)
    |> Enum.map(fn {_, id, cid, parent, content, updated, refs} ->
      %{
        id: id,
        campaign_id: cid,
        parent_id: parent,
        content_md: content,
        updated_at: updated,
        source_refs: refs || [],
        session_number: Map.get(order, id)
      }
    end)
    |> Enum.sort_by(fn c -> c.session_number || 1_000_000 end)
  end

  @doc "History rows for an Epos entry, newest first."
  def list_epos_history(entry_id) when is_binary(entry_id) do
    transaction(fn ->
      :mnesia.index_read(S.epos_history(), entry_id, :entry_id)
    end)
    |> Enum.map(fn {_, id, eid, content, edited_at, edited_by, source, seq} ->
      %{
        id: id,
        entry_id: eid,
        content_md: content,
        edited_at: edited_at,
        edited_by: edited_by,
        source: source,
        seq: seq
      }
    end)
    |> Enum.sort_by(& &1.seq, :desc)
  end

  # ─── summaries / facts / faithfulness ───────────────────────────

  def get_session_summary(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_summaries(), session_id) end) do
      # Issue #114: source_refs trailing; Issue #715: flagged_claims trailing.
      [{_, sid, cid, content, generated_at, source, refs, flagged}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          content_md: content,
          generated_at: generated_at,
          source: source,
          source_refs: refs || [],
          flagged_claims: flagged || []
        }

      [] ->
        nil
    end
  end

  # Issue #651 (Wahrheitsbild, Phase A): die extrahierten Fakten EINER Session.
  # facts_json wird zur Read-Zeit dekodiert (Liste von Fakt-Maps, String-Keys
  # wie gespeichert). nil wenn (noch) keine Extraktion lief.
  def get_session_facts(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_facts(), session_id) end) do
      [{_, sid, cid, facts_json, extracted_at, event_id}] ->
        overrides = fact_overrides_for_session(sid)

        facts =
          facts_json
          |> decode_facts()
          |> Enum.map(&merge_override(&1, Map.get(overrides, &1["id"]), event_id))

        %{
          session_id: sid,
          campaign_id: cid,
          facts: facts,
          extracted_at: extracted_at
        }

      [] ->
        nil
    end
  end

  # Issue #651: alle Fakten einer Campaign, flach + chronologisch nach
  # session.number (wie list_chronik_entries #650). Jeder Fakt bekommt sein
  # `"session_id"` zur Provenienz mit (für Campaign-Epos + Phase-B-Verify).
  # Issue #724 Slice F: GM-Overrides (Review-Queue-Korrekturen) werden hier
  # eingemischt — der einzige Lese-Pfad, den `campaign_review_facts/1` UND
  # die Render-/Verify-Konsumenten teilen.
  def list_campaign_facts(campaign_id) when is_binary(campaign_id) do
    order =
      campaign_id |> list_sessions() |> Map.new(fn s -> {s.id, s.number} end)

    transaction(fn ->
      :mnesia.index_read(S.session_facts(), campaign_id, :campaign_id)
    end)
    |> Enum.sort_by(fn {_, sid, _cid, _json, _ts, _event_id} ->
      Map.get(order, sid, 1_000_000)
    end)
    |> Enum.flat_map(fn {_, sid, _cid, facts_json, _ts, event_id} ->
      overrides = fact_overrides_for_session(sid)

      facts_json
      |> decode_facts()
      |> Enum.map(fn f ->
        f
        |> Map.put("session_id", sid)
        |> merge_override(Map.get(overrides, f["id"]), event_id)
      end)
    end)
  end

  defp decode_facts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_facts(_), do: []

  # Issue #724 Slice F: GM-Overrides einer Session, keyed by fact_id — Map.new
  # über den index_read, damit list_campaign_facts/get_session_facts nicht pro
  # Fakt einzeln lesen (eine Mnesia-Runde pro Session reicht).
  defp fact_overrides_for_session(session_id) do
    transaction(fn ->
      :mnesia.index_read(S.session_fact_overrides(), session_id, :session_id)
    end)
    |> Map.new(fn {_, _key, _sid, _cid, fact_id, extraction_event_id, raw, dismissed, _event_id} ->
      {fact_id, %{raw: raw, dismissed: dismissed, extraction_event_id: extraction_event_id}}
    end)
  end

  # Issue #724 Slice F: wendet einen GM-Override auf einen Fakt an.
  #
  # KRITISCH (Review-Fund): Fakt-IDs sind rein positional (`"f" <> index`,
  # `Parsing.normalize_fact/4`) — NICHT run-eindeutig. Ohne Generation-Check
  # würde ein Override nach einem Regenerate (neue Extraktion, gleiche
  # Positions-IDs) auf einen VÖLLIG ANDEREN neuen Fakt an derselben Position
  # durchschlagen (Cross-Contamination). `current_extraction_event_id` ist das
  # `event_id` der AKTUELL gespeicherten `session_facts`-Row — ein Override
  # gilt nur, wenn seine `extraction_event_id` genau dazu passt. Reiner
  # Vergleich gegen konvergenten State → bleibt order-insensitiv, kein neuer
  # #698-Bug (die Fold-seitige LWW-Logik bleibt davon unberührt).
  #
  # `dismissed: true` gewinnt immer (schließt den Fakt aus der Review-Queue
  # UND — via `review_dismissed` — aus jedem künftigen Zeitstrahl-Republish
  # aus, nicht nur aus der Anzeige). Ein gesetztes Datum wird NICHT nur als
  # `in_game_date` durchgereicht: `Resolver.resolve_one/4` nimmt den Absolut-
  # Branch nur bei `time_anchor == "absolute"` (resolver.ex) — Review-Fakten
  # haben oft `time_anchor == "unknown"` (Graph degradiert mehrdeutige
  # event:-Refs dorthin), ein bloßes in_game_date würde also ignoriert. Der
  # GM ist autoritativ → `time_anchor`/`time_absolute` werden forciert.
  # `review_override_date` ist eine reine Provenienz-Markierung für die
  # Parse-Härtung unten (unterscheidet „GM hat das gesetzt" von einem
  # LLM-nativen Absolut-Fakt).
  defp merge_override(f, nil, _current_extraction_event_id), do: f

  defp merge_override(f, %{extraction_event_id: eid}, current)
       when eid != current do
    f
  end

  defp merge_override(f, %{dismissed: true}, _current), do: Map.put(f, "review_dismissed", true)

  defp merge_override(f, %{raw: raw}, _current) when is_binary(raw) and raw != "" do
    f
    |> Map.put("in_game_date", raw)
    |> Map.put("time_absolute", raw)
    |> Map.put("time_anchor", "absolute")
    |> Map.put("review_override_date", raw)
  end

  # Undo (leerer String, not dismissed) — kein Override mehr, Fakt unverändert.
  defp merge_override(f, _cleared, _current), do: f

  # Issue #746: Review-Queue — verifizierte Fakten, die der Zeitstrahl NICHT
  # platzieren kann (Flashback/Zukunft/unbekannte Erzählzeit ohne Datum UND
  # ohne Offset). Das #686-Sicherheitsventil: statt still aus dem Zeitstrahl zu
  # fallen, werden sie dem SL sichtbar gemacht. Nur der :wahrheitsbild-Pfad
  # setzt `narration_time`/`time_offset` — bei :chain ist die Liste leer.
  #
  # Issue #724 Slice F: `dismissed` schließt aus; ein GM-Override-Datum, das
  # NICHT auflöst (`Calendar.parse` scheitert), hält den Fakt bewusst in der
  # Queue (statt ihn falsch aus der Sicht zu nehmen — sonst verschwindet ein
  # GM-Tippfehler aus der Queue, landet aber nie im Zeitstrahl: das #686-Loch,
  # das die Queue eigentlich stopfen soll). `date_parse_error` markiert diesen
  # Fall für die UI (flag-not-drop, kein stummer Fehlschlag nach dem Speichern).
  def campaign_review_facts(campaign_id) when is_binary(campaign_id) do
    cal = get_campaign_calendar(campaign_id)

    campaign_id
    |> list_campaign_facts()
    |> Enum.filter(&review_fact?(&1, cal))
    |> Enum.map(&maybe_flag_parse_error(&1, cal))
  end

  defp review_fact?(f, cal) when is_map(f) do
    Map.get(f, "verified?") == true and
      Map.get(f, "review_dismissed") != true and
      (undated_fact?(f) or unparsable_override?(f, cal))
  end

  defp review_fact?(_f, _cal), do: false

  defp undated_fact?(f) do
    Map.get(f, "narration_time") in ["flashback", "future", "unknown"] and
      blank_fact_field?(f["in_game_date"]) and is_nil(f["time_offset"])
  end

  defp unparsable_override?(f, cal) do
    case f["review_override_date"] do
      raw when is_binary(raw) -> Worker.Timeline.Calendar.parse(cal, raw) == :error
      _ -> false
    end
  end

  defp maybe_flag_parse_error(f, cal) do
    if unparsable_override?(f, cal), do: Map.put(f, "date_parse_error", true), else: f
  end

  defp blank_fact_field?(v), do: is_nil(v) or (is_binary(v) and String.trim(v) == "")

  def list_session_summaries(campaign_id) when is_binary(campaign_id) do
    # Sortierung nach Session-Nummer (Issue #24): die Spalte soll
    # chronologisch nach Session-Verlauf lesen — Session 1 oben, neueste
    # Session unten — NICHT nach generated_at (wann die LLM-Pipeline den
    # Resümee-Text erzeugt hat). Fallback auf große Zahl wenn die Session
    # selbst inzwischen gelöscht wurde, damit Orphan-Resümees ans Ende
    # sortieren statt zu crashen.
    sessions_by_id =
      campaign_id |> list_sessions() |> Enum.into(%{}, &{&1.id, &1})

    transaction(fn ->
      :mnesia.index_read(S.session_summaries(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, sid, cid, content, generated_at, source, refs, flagged} ->
      %{
        session_id: sid,
        campaign_id: cid,
        content_md: content,
        generated_at: generated_at,
        source: source,
        source_refs: refs || [],
        flagged_claims: flagged || []
      }
    end)
    |> Enum.sort_by(fn s ->
      case sessions_by_id[s.session_id] do
        %{number: n} -> n
        _ -> 999_999
      end
    end)
  end

  # Issue #11 Phase 2: Faithfulness-Score pro Session.
  # claims_json wird hier eager dekodiert — die UI braucht Claim-Texte für
  # das Click-to-Expand-Detail.
  def get_faithfulness_score(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_faithfulness_scores(), session_id) end) do
      [{_, sid, cid, score, claims_json, scored_at, _event_id}] ->
        %{
          session_id: sid,
          campaign_id: cid,
          score: score,
          claims: decode_claims(claims_json),
          scored_at: scored_at
        }

      [] ->
        nil
    end
  end

  def list_faithfulness_scores(campaign_id) when is_binary(campaign_id) do
    transaction(fn ->
      :mnesia.index_read(S.session_faithfulness_scores(), campaign_id, :campaign_id)
    end)
    |> Enum.map(fn {_, sid, cid, score, claims_json, scored_at, _event_id} ->
      %{
        session_id: sid,
        campaign_id: cid,
        score: score,
        claims: decode_claims(claims_json),
        scored_at: scored_at
      }
    end)
  end

  defp decode_claims(nil), do: []
  defp decode_claims(""), do: []

  defp decode_claims(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_claims(_), do: []

  # ─── chronik (+ Kalender/Anker, Issue #724) ─────────────────────

  def list_chronik_entries(campaign_id) when is_binary(campaign_id) do
    # Issue #650: primär nach Session-Reihenfolge (session.number), erst sekundär
    # nach in_game_date. Vorher rein nach in_game_date → über Sessions hinweg
    # verdreht (LLM-Datumsformate sind nicht global vergleichbar; "Tag 1" aus S2
    # sortierte vor "Tag 3" aus S1). Einträge ohne bekannte Session (Orphans /
    # nil) wandern ans Ende.
    session_order = chronik_session_order(campaign_id)

    # Issue #698 (I7): Clear-Watermark pro Session (session_id => clear_key).
    # Ein Eintrag ist live gdw. sein event_id > clear_key seiner Session —
    # order-insensitiv gegen Re-Run-Zombies. Ohne Mark → alle Rows live (heutiges
    # Verhalten); Pre-Migration-Rows (event_id nil) werden von jedem Mark
    # unterdrückt.
    clear_keys =
      transaction(fn ->
        :mnesia.index_read(S.chronik_clear_marks(), campaign_id, :campaign_id)
      end)
      |> Map.new(fn {_, sid, _cid, key} -> {sid, key} end)

    transaction(fn ->
      :mnesia.index_read(S.chronik_entries(), campaign_id, :campaign_id)
    end)
    # Issue #698: Watermark-Filter auf dem Roh-Tupel (session_id = elem 6,
    # generation = elem 11) VOR dem Mappen.
    |> Enum.filter(fn row ->
      chronik_entry_live?(elem(row, 11), Map.get(clear_keys, elem(row, 6)))
    end)
    # Issue #114: source_refs trailing.
    # Issue #385: markdown_body — verbatim User-Markdown fürs Hub-Display.
    # Issue #724: in_game_day (kanonischer Tageszähler) + precision trailing.
    # nil bei nicht-migrierten / :chain-Einträgen.
    # Issue #698: generation trailing (Filter oben; hier ignoriert).
    |> Enum.map(fn {_, id, cid, in_game_date, label, summary, sid, refs, md_body, day, precision,
                    _generation} ->
      %{
        id: id,
        campaign_id: cid,
        in_game_date: in_game_date,
        label: label,
        summary: summary,
        session_id: sid,
        source_refs: refs || [],
        markdown_body: md_body,
        in_game_day: day,
        precision: precision
      }
    end)
    # Issue #724: Sort-Cutover. Familie 0 (echter Tageszähler, global vergleichbar)
    # NUR bei integer in_game_day — der :wahrheitsbild-Zeitstrahl. Sonst Familie 1
    # = das bestehende #650-Verhalten (Session-Reihenfolge, dann Freitext-Datum).
    # Solange keine Row einen in_game_day hat (alle :chain), ist das exakt der
    # Status quo → null Regression.
    |> Enum.sort_by(fn e ->
      case e.in_game_day do
        d when is_integer(d) ->
          {0, d, ""}

        _ ->
          {1, Map.get(session_order, e.session_id, 1_000_000),
           derive_chronik_sort_tuple(e.in_game_date)}
      end
    end)
  end

  # Issue #698 (I7): Row live gdw. generation >= clear_key. `>=` (nicht `>`),
  # weil Pipeline-Entries dieselbe Generation wie der Clear ihres eigenen Runs
  # tragen — sie müssen ihren eigenen Clear überleben, nur frühere Runs
  # (kleinere Generation) werden unterdrückt. Kein Mark (nil) → live (keine
  # Clearung). generation nil (Pre-Migration) bei vorhandenem Mark → unterdrückt.
  defp chronik_entry_live?(_generation, nil), do: true
  defp chronik_entry_live?(nil, _clear_key), do: false
  defp chronik_entry_live?(generation, clear_key), do: generation >= clear_key

  # Issue #650: session_id → session.number, für die primäre Chronik-Sortierung.
  defp chronik_session_order(campaign_id) do
    campaign_id
    |> list_sessions()
    |> Map.new(fn s -> {s.id, s.number} end)
  end

  # Issue #724: der per-Campaign-Kalender (eigene Tabelle @campaign_calendars).
  # Fehlende Row ODER kaputtes JSON → Calendar.default/0 (Boundary-Defense, nie
  # crashen). calendar_json wird als Jason-String gespeichert (Slice C schreibt).
  @doc "Kalender-Definition der Campaign; `Worker.Timeline.Calendar.default/0` bei Miss."
  @spec get_campaign_calendar(String.t()) :: Worker.Timeline.Calendar.t()
  def get_campaign_calendar(campaign_id) when is_binary(campaign_id) do
    row =
      transaction(fn -> :mnesia.read(S.campaign_calendars(), campaign_id) end)

    case row do
      [{_tbl, _cid, calendar_json, _updated_at}] when is_binary(calendar_json) ->
        case Jason.decode(calendar_json) do
          {:ok, map} -> Worker.Timeline.Calendar.from_json(map)
          _ -> Worker.Timeline.Calendar.default()
        end

      _ ->
        Worker.Timeline.Calendar.default()
    end
  end

  # Issue #724: kanonischer In-Game-Tageszähler der Session (eigene Tabelle
  # @session_anchors) — Anker für relative Fakt-Offsets im Resolver. nil, wenn
  # der GM (noch) kein Datum gesetzt hat.
  @doc "In-Game-Tageszähler der Session als Resolver-Anker; nil wenn nicht gesetzt."
  @spec get_session_anchor_day(String.t()) :: integer() | nil
  def get_session_anchor_day(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_anchors(), session_id) end) do
      [{_tbl, _sid, _cid, in_game_day, _raw}] -> in_game_day
      _ -> nil
    end
  end

  @doc """
  Issue #724 Slice F: voller Session-Anker (Tageszähler + GM-Roh-String) für die
  Snapshot-Anzeige. `nil` wenn nicht gesetzt.
  """
  @spec get_session_anchor(String.t()) ::
          %{in_game_day: integer() | nil, in_game_date_raw: String.t()} | nil
  def get_session_anchor(session_id) when is_binary(session_id) do
    case transaction(fn -> :mnesia.read(S.session_anchors(), session_id) end) do
      [{_tbl, _sid, _cid, in_game_day, raw}] ->
        %{in_game_day: in_game_day, in_game_date_raw: raw}

      _ ->
        nil
    end
  end

  # Issue #135: Sort-Reihenfolge wird zur Lesezeit aus dem `in_game_date`-
  # String abgeleitet — kein persistiertes derived value mehr. Tuple-Layout:
  # `{family, primary, original}`. Familien-Priorität:
  #
  #   0 — Session/Tag/Day/Akt + Zahl (häufigste Form in der Praxis)
  #   1 — Jahres-Datum (z.B. "552 CY", "552 CY - Spring")
  #   2 — Narrativer Marker ("Aufbruch", "Erste Begegnung")
  #   9 — nil / leerer String (sortiert ans Ende)
  #
  # Innerhalb einer Familie sortiert die `primary`-Zahl numerisch; der
  # `original`-String bricht Ties stabil. Wenn neue LLM-Modelle weitere
  # Datumsformate emittieren, kommt eine zusätzliche Klausel dazu.
  @doc false
  def derive_chronik_sort_tuple(nil), do: {9, 0, ""}
  def derive_chronik_sort_tuple(""), do: {9, 0, ""}

  def derive_chronik_sort_tuple(date) when is_binary(date) do
    cond do
      n = leading_unit_number(date) ->
        {0, n, date}

      year_n = year_with_optional_season(date) ->
        {1, year_n, date}

      true ->
        {2, 0, date}
    end
  end

  # Matches "Session 13", "Tag 38", "Day 14", "Akt 2", "Scene 5" — case-
  # insensitive, optional whitespace, leading number captured.
  defp leading_unit_number(date) do
    case Regex.run(~r/^\s*(?:session|tag|day|akt|szene|scene)\s+(\d+)/i, date) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # Matches "552 CY", "552 CY - Spring", "550 CY (Winter)" etc. Returns
  # year * 10 + season_bump so two events in the same year sort by season.
  defp year_with_optional_season(date) do
    case Regex.run(~r/(\d+)\s*CY/, date) do
      [_, y] ->
        season =
          cond do
            date =~ ~r/Spring/i -> 1
            date =~ ~r/Summer/i -> 2
            date =~ ~r/Autumn|Fall/i -> 3
            date =~ ~r/Winter/i -> 4
            true -> 0
          end

        String.to_integer(y) * 10 + season

      _ ->
        nil
    end
  end

  # ─── probelauf runs / sweeps (Issue #74 / #88) ──────────────────

  @doc """
  Letzter beendeter Single-Probelauf (Issue #74) — also ein Run der **nicht**
  Teil eines Sweeps war. Als Map oder nil. Sortiert nach finished_at
  (sekundärer Sort gegen run_id für Determinismus).
  """
  def last_probelauf_run do
    all_probelauf_runs()
    |> Enum.filter(fn r -> r.finished_at && is_nil(r.sweep_id) end)
    |> Enum.sort_by(fn r -> {DateTime.to_unix(r.finished_at, :microsecond), r.run_id} end, :desc)
    |> List.first()
  end

  @doc """
  Alle Probelauf-Runs (Phase 1 + Phase 2). Jede Row als Map mit nun
  optionalen `sweep_id` + `sweep_variant` Feldern (Issue #88).
  """
  def all_probelauf_runs do
    transaction(fn ->
      :mnesia.match_object({S.probelauf_runs(), :_, :_, :_, :_, :_, :_, :_, :_})
    end)
    |> Enum.map(fn {_, run_id, started_at, finished_at, started_by, sessions, settings, sweep_id,
                    sweep_variant} ->
      %{
        run_id: run_id,
        started_at: started_at,
        finished_at: finished_at,
        started_by: started_by,
        sessions: sessions,
        settings_snapshot: settings,
        sweep_id: sweep_id,
        sweep_variant: sweep_variant
      }
    end)
  end

  @doc """
  Letzter beendeter Sweep (Issue #88, Phase 2a) als Map mit aggregierter
  Variants-Liste, oder nil. Aggregation pro (stage, model): Median-Dauer
  über alle Sessions, Success-Rate über alle Stages aller Sessions.
  """
  def last_probelauf_sweep do
    case last_n_probelauf_sweeps(1) do
      [] -> nil
      [latest | _] -> latest
    end
  end

  @doc """
  Die letzten `n` beendeten Sweeps (default 3), sortiert nach
  finished_at desc (neuester zuerst). Issue #88 (Phase 2b): die LV
  zeigt mehrere Sweeps gleichzeitig nach einem Multi-Stage-Sweep, je
  ein Sweep pro durchgesweepte Stage. Jeder Eintrag enthält bereits
  die zugehörigen `:runs`.
  """
  @spec last_n_probelauf_sweeps(pos_integer()) :: [map()]
  def last_n_probelauf_sweeps(n \\ 3) when is_integer(n) and n > 0 do
    sweeps =
      transaction(fn ->
        :mnesia.match_object({S.probelauf_sweeps(), :_, :_, :_, :_, :_, :_, :_, :_})
      end)
      |> Enum.map(fn {_, sweep_id, started_at, finished_at, started_by, stage, models,
                      default_model, variants} ->
        %{
          sweep_id: sweep_id,
          started_at: started_at,
          finished_at: finished_at,
          started_by: started_by,
          stage: stage,
          models: models,
          default_model: default_model,
          variants: variants
        }
      end)
      |> Enum.filter(& &1.finished_at)
      |> Enum.sort_by(
        fn s -> {DateTime.to_unix(s.finished_at, :microsecond), s.sweep_id} end,
        :desc
      )
      |> Enum.take(n)

    case sweeps do
      [] ->
        []

      list ->
        all_runs = all_probelauf_runs()

        Enum.map(list, fn sweep ->
          runs_for_sweep =
            Enum.filter(all_runs, fn r -> r.sweep_id == sweep.sweep_id && r.finished_at end)

          Map.put(sweep, :runs, runs_for_sweep)
        end)
    end
  end
end
