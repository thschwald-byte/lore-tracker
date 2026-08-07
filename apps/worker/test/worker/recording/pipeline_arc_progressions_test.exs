defmodule Worker.Recording.PipelineArcProgressionsTest do
  @moduledoc """
  Issue #838: Pipeline-Verdrahtung von `publish_wahrheitsbild_arc_progressions/3`
  innerhalb `run_wahrheitsbild/4` — automatischer Trigger pro berührtem Bogen
  (Design A), Ein-Call-pro-(Session×Bogen) mit pro-Bogen-Fehlerisolierung
  (Design B+J), strukturelle Replay-Sicherheit über den zusammengesetzten
  `{arc_id, session_id}`-Key (Design E). `render_arc_progression` ist
  injizierbar (deps-Muster, identisch zu `render`/`render_epos`, s.
  `pipeline_wahrheitsbild_test.exs`) — kein LLM, kein Sidecar nötig.

  Bögen + Fakten werden wie in `repo_touched_arcs_test.exs` direkt über
  `ArcCreated`/`SessionFactsExtracted`-Events materialisiert (nicht über die
  `extract`-Dep), weil `touched_arcs_for_session/2` den echten Mnesia-
  Lese-Pfad (`campaign_threads/1`) benutzt, nicht den Pipeline-Rückgabewert.
  `resolve_threads` wird auf ein No-op gestubbt, damit kein echtes
  LLM-Clustering läuft — die Bogen-Zuordnung kommt ausschließlich aus den
  direkt gesetzten `ArcCreated`-Seed-Labels.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "c-arcprog-838"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)

    build_campaign(campaign_id: @cid, sessions: [1, 1], apply: true)
    :ok
  end

  defp session(n), do: %{id: "#{@cid}-s#{n}", number: n}
  defp campaign, do: %{id: @cid}

  defp fact(id, thread, claim), do: %{"id" => id, "claim" => claim, "thread" => thread, "verified?" => true, "fact_type" => "ereignis"}

  defp seed_facts!(session_n, facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{session_n}", "campaign_id" => @cid, "facts" => facts},
        seq,
        event_id: "sfe-ap-#{session_n}-#{seq}"
      )
    )
  end

  defp arc!(arc_id, seeds, seq) do
    Materializer.apply_event(
      event(
        "ArcCreated",
        %{
          "arc_id" => arc_id,
          "campaign_id" => @cid,
          "leitfrage_draft" => "F #{arc_id}?",
          "seed_raw_labels" => seeds
        },
        seq,
        event_id: "ac-ap-#{seq}"
      )
    )
  end

  defp rendered(md), do: %{md: md, traceable: [String.trim(md)], flagged: [], clean?: true}

  defp claim_join(facts), do: facts |> Enum.map(& &1["claim"]) |> Enum.join(" ")

  defp last_error, do: Worker.Repo.Snapshots.last_n_pipeline_errors(1) |> List.first()

  defp noop_deps(overrides) do
    Map.merge(
      %{
        extract: fn -> {:ok, []} end,
        resolve: fn -> {:ok, %{}} end,
        resolve_threads: fn -> {:ok, %{}} end,
        verify: fn -> {:ok, []} end,
        render: fn _ -> {:ok, rendered("resümee.")} end,
        render_epos: fn _ -> {:ok, rendered("kapitel.")} end
      },
      overrides
    )
  end

  test "(a) ein Bogen berührt -> ein Eintrag mit den Session-Delta-Fakten im Prompt-Input" do
    seed_facts!(1, [fact("f1", "der Auftrag", "Der Auftrag beginnt.")], 100)
    arc!("arc-auftrag", ["der auftrag"], 101)

    deps =
      noop_deps(%{
        render_arc_progression: fn canonical, prior_entry, new_facts, _gate_facts ->
          assert is_binary(canonical)
          assert prior_entry == nil
          assert Enum.map(new_facts, & &1["claim"]) == ["Der Auftrag beginnt."]
          {:ok, rendered("Der Auftrag beginnt, wie berichtet.")}
        end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps)
    end)

    assert [%{session_number: 1, content_md: content}] =
             Repo.list_arc_progression_entries(@cid, "arc-auftrag")

    assert content == "Der Auftrag beginnt, wie berichtet."
  end

  test "(b) mehrere Bögen in einer Session -> mehrere isolierte Einträge" do
    seed_facts!(
      1,
      [
        fact("f1", "der Auftrag", "Der Auftrag beginnt."),
        fact("f2", "die Feindschaft", "Die Feindschaft wächst.")
      ],
      100
    )

    arc!("arc-auftrag", ["der auftrag"], 101)
    arc!("arc-feindschaft", ["die feindschaft"], 102)

    deps =
      noop_deps(%{
        render_arc_progression: fn _canonical, _prior, new_facts, _gate ->
          {:ok, rendered(claim_join(new_facts))}
        end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps)
    end)

    assert [%{content_md: "Der Auftrag beginnt."}] =
             Repo.list_arc_progression_entries(@cid, "arc-auftrag")

    assert [%{content_md: "Die Feindschaft wächst."}] =
             Repo.list_arc_progression_entries(@cid, "arc-feindschaft")
  end

  test "(c) ein Bogen-Call schlägt fehl -> andere Bögen + Rest der Pipeline laufen trotzdem durch (Design J, wichtigster Test)" do
    seed_facts!(
      1,
      [
        fact("f1", "der Auftrag", "Der Auftrag beginnt."),
        fact("f2", "die Feindschaft", "Die Feindschaft wächst.")
      ],
      100
    )

    arc!("arc-auftrag", ["der auftrag"], 101)
    arc!("arc-feindschaft", ["die feindschaft"], 102)

    deps =
      noop_deps(%{
        render: fn _ -> {:ok, rendered("resümee trotzdem da.")} end,
        render_arc_progression: fn _canonical, _prior, new_facts, _gate ->
          if Enum.any?(new_facts, &(&1["claim"] =~ "Auftrag")) do
            {:error, :boom}
          else
            {:ok, rendered("erfolgreich.")}
          end
        end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps)
    end)

    # Rest der Pipeline (Resümee) trotz des fehlgeschlagenen Bogens durchgelaufen.
    assert Repo.get_session_summary("#{@cid}-s1").content_md == "resümee trotzdem da."

    # Der fehlgeschlagene Bogen hat KEINEN Eintrag …
    assert Repo.list_arc_progression_entries(@cid, "arc-auftrag") == []
    # … der andere Bogen trotzdem seinen Eintrag bekommen hat — kein Cross-Bogen-Abbruch.
    assert [%{content_md: "erfolgreich."}] =
             Repo.list_arc_progression_entries(@cid, "arc-feindschaft")

    err = last_error()
    assert err.stage == "render_arc_progressions"
    # Schritt 7 (#838-Plan, Fehlerklassifikation) fügt eine eigene
    # `classify_pipeline_error({:render_arc_progressions, _})`-Klausel hinzu —
    # bis dahin greift hier bewusst der generische Atom-Fallback ("other").
    assert err.error_type == "other"
    assert err.session_id == "#{@cid}-s1"
    assert err.campaign_id == @cid
  end

  test "(d) kein Bogen berührt -> Schritt läuft leer durch, kein Fehler, kein Aufruf" do
    deps =
      noop_deps(%{
        render_arc_progression: fn _, _, _, _ -> flunk("darf ohne berührten Bogen nicht gerufen werden") end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps)
    end)

    assert Repo.get_session_summary("#{@cid}-s1").content_md == "resümee."
  end

  test "(e) Regenerate einer älteren Session -> nur deren eigener Eintrag ändert sich, spätere Einträge desselben Bogens bleiben unverändert (Design E)" do
    seed_facts!(1, [fact("f1", "der Auftrag", "Der Auftrag beginnt.")], 100)
    seed_facts!(2, [fact("f2", "der Auftrag", "Der Auftrag eskaliert.")], 101)
    arc!("arc-auftrag", ["der auftrag"], 102)

    deps_s1 =
      noop_deps(%{
        render_arc_progression: fn _canonical, prior_entry, new_facts, _gate ->
          assert prior_entry == nil
          {:ok, rendered("S1: " <> claim_join(new_facts))}
        end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps_s1)
    end)

    deps_s2 =
      noop_deps(%{
        render_arc_progression: fn _canonical, prior_entry, new_facts, _gate ->
          assert prior_entry.session_number == 1
          {:ok, rendered("S2: " <> claim_join(new_facts))}
        end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(2), campaign(), [], deps_s2)
    end)

    # Session 1 wird erneut regeneriert (z.B. nach einer Korrektur ihrer
    # Fakten) — der Vorgänger-Lookup für Session 1 bleibt `nil` (keine Session
    # < 1), unabhängig davon, dass ein Session-2-Eintrag inzwischen existiert.
    deps_s1_regen =
      noop_deps(%{
        render_arc_progression: fn _canonical, prior_entry, new_facts, _gate ->
          assert prior_entry == nil
          {:ok, rendered("S1-REGEN: " <> claim_join(new_facts))}
        end
      })

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps_s1_regen)
    end)

    entries = Repo.list_arc_progression_entries(@cid, "arc-auftrag")

    assert [%{session_number: 1, content_md: s1_md}, %{session_number: 2, content_md: s2_md}] =
             entries

    assert s1_md == "S1-REGEN: Der Auftrag beginnt."
    assert s2_md == "S2: Der Auftrag eskaliert."
    refute s2_md =~ "REGEN"
  end

  test "(f) mehrfacher Lauf über dieselben Sessions (Replay) -> ein Eintrag pro Session, keine Duplikate/Überschreibungen fremder Sessions" do
    seed_facts!(1, [fact("f1", "der Auftrag", "Der Auftrag beginnt.")], 100)
    seed_facts!(2, [fact("f2", "der Auftrag", "Der Auftrag eskaliert.")], 101)
    arc!("arc-auftrag", ["der auftrag"], 102)

    deps =
      noop_deps(%{
        render_arc_progression: fn _canonical, _prior, new_facts, _gate ->
          {:ok, rendered(claim_join(new_facts))}
        end
      })

    capture_log(fn ->
      # Simulierter CampaignReplay: sequentiell S1, S2 — und dann (wie ein
      # erneuter "Pipeline für alle Sessions neu starten"-Lauf) NOCHMAL S1, S2.
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps)
      assert :ok = Pipeline.run_wahrheitsbild(session(2), campaign(), [], deps)
      assert :ok = Pipeline.run_wahrheitsbild(session(1), campaign(), [], deps)
      assert :ok = Pipeline.run_wahrheitsbild(session(2), campaign(), [], deps)
    end)

    entries = Repo.list_arc_progression_entries(@cid, "arc-auftrag")
    assert Enum.map(entries, & &1.session_number) == [1, 2]
    assert Enum.map(entries, & &1.content_md) == ["Der Auftrag beginnt.", "Der Auftrag eskaliert."]
  end
end
