defmodule Worker.Recording.PipelineTimelineRepublishTest do
  @moduledoc """
  Issue #724 Slice F: `Pipeline.republish_timeline_for_session/1` — der
  deterministische (kein LLM) Zeitstrahl-Republish nach einer GM-Korrektur in
  der Review-Queue, plus der Author-Worker-Trigger (`handle_info` auf
  `SessionFactDateSet`).

  Abgedeckt:
  - Datierter, verifizierter Fakt landet im Zeitstrahl.
  - Doppel-Lauf ist idempotent (#698-Watermark, keine Duplikate).
  - Fehlende Extraktion → `{:error, :no_facts}`, bestehende Chronik bleibt
    unangetastet (kein Irrläufer-Wipe).
  - Dismisster, aber datierter Fakt taucht NICHT im Zeitstrahl auf (Design D
    — `dismissed` schließt auch aus dem Republish-Build aus, nicht nur aus
    der Review-Anzeige).
  - Election-Gate (Muster `pipeline_election_test.exs`): nur der Author-
    Worker triggert; kein Skip bei `dismissed` (Republish läuft trotzdem —
    nachgewiesen über den `pipeline_status`-Broadcast von `with_status`, der
    unabhängig vom Chronik-Ergebnis feuert).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-724-republish"
  @sid "sess-724-republish"
  @ext "ext-01"

  setup do
    clear_all_tables!()
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)

    Builder.write!(Builder.campaign(@cid))
    Builder.write!(Builder.session(@sid, @cid, number: 1))
    :ok
  end

  defp fact(id, opts \\ []) do
    %{
      "id" => id,
      "claim" => "Claim #{id}",
      "entity_id" => "e",
      "character_alias" => "Figur",
      "source_refs" => ["u-#{id}"],
      "verified?" => Keyword.get(opts, :verified?, true),
      "in_game_date" => Keyword.get(opts, :in_game_date, "1888")
    }
  end

  defp put_facts(facts, extraction_event_id \\ @ext) do
    # Issue #783 Phase 2 (Design E): verify_backend/verify_model trailing
    # (Provenance, hier irrelevant → nil).
    Builder.write!(
      {S.session_facts(), @sid, @cid, Jason.encode!(facts), DateTime.utc_now(),
       extraction_event_id, nil, nil, nil}
    )
  end

  defp put_override(fact_id, dismissed, extraction_event_id \\ @ext) do
    Builder.write!(
      {S.session_fact_overrides(), "#{@sid}:#{fact_id}", @sid, @cid, fact_id, extraction_event_id,
       "", dismissed, "ov-01"}
    )
  end

  describe "republish_timeline_for_session/1 (deterministisch, kein LLM)" do
    test "datierter, verifizierter Fakt landet im Zeitstrahl" do
      put_facts([fact("f1")])

      capture_log(fn ->
        assert :ok = Pipeline.republish_timeline_for_session(@sid)
      end)

      assert [entry] = Repo.list_chronik_entries(@cid)
      assert entry.in_game_date == "1888"
      assert is_integer(entry.in_game_day)
    end

    test "Doppel-Lauf ist idempotent (kein Duplikat, #698-Watermark)" do
      put_facts([fact("f1")])

      capture_log(fn ->
        assert :ok = Pipeline.republish_timeline_for_session(@sid)
        assert :ok = Pipeline.republish_timeline_for_session(@sid)
      end)

      assert length(Repo.list_chronik_entries(@cid)) == 1
    end

    test "fehlende Extraktion → {:error, :no_facts}, bestehende Chronik bleibt unangetastet" do
      put_facts([fact("f1")])

      capture_log(fn ->
        assert :ok = Pipeline.republish_timeline_for_session(@sid)
      end)

      assert length(Repo.list_chronik_entries(@cid)) == 1

      # Irrläufer-Trigger auf eine Session ohne (mehr) Extraktion — z.B. Race
      # mit einem parallelen Cascade-Delete. Darf die bestehende Chronik NICHT
      # wipen (kein Clear ohne Facts-Row).
      :mnesia.dirty_delete(S.session_facts(), @sid)

      assert {:error, :no_facts} = Pipeline.republish_timeline_for_session(@sid)
      assert length(Repo.list_chronik_entries(@cid)) == 1
    end

    test "dismisster, aber datierter Fakt taucht NICHT im Zeitstrahl auf (Design D)" do
      put_facts([fact("f1"), fact("f2", in_game_date: "1889")])
      put_override("f1", true)

      capture_log(fn ->
        assert :ok = Pipeline.republish_timeline_for_session(@sid)
      end)

      assert [entry] = Repo.list_chronik_entries(@cid)
      assert entry.in_game_date == "1889"
    end

    test "unverifizierter Fakt fließt nicht ein (regulärer Verify-Filter bleibt gültig)" do
      put_facts([fact("f1", verified?: false)])

      capture_log(fn ->
        assert :ok = Pipeline.republish_timeline_for_session(@sid)
      end)

      assert Repo.list_chronik_entries(@cid) == []
    end
  end

  # #866 (Slice F): die SessionFactDateSet-Kante lebt jetzt im generischen
  # Dirty-Mechanismus (@dependency_graph) — der Trigger-Empfänger ist
  # Worker.Recording.Pipeline.Dirty, das Verhalten ist identisch geblieben.
  describe "handle_info SessionFactDateSet — Election-Gate + Immer-Republish (Design D)" do
    setup do
      # Issue #571: Task.Supervisor.start_child braucht den Supervisor.
      ensure_started(Worker.TaskSupervisor, fn ->
        Task.Supervisor.start_link(name: Worker.TaskSupervisor)
      end)

      pid =
        case Worker.Recording.Pipeline.Dirty.start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      prev_level = Logger.level()
      Logger.configure(level: :info)

      on_exit(fn ->
        Logger.configure(level: prev_level)
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
      Repo.put_state(:worker_id, "w-self")

      %{pid: pid}
    end

    defp date_set_event(author, extra \\ %{}) do
      payload =
        Map.merge(
          %{
            "kind" => "SessionFactDateSet",
            "session_id" => @sid,
            "campaign_id" => @cid,
            "fact_id" => "f1",
            "extraction_event_id" => @ext,
            "in_game_date_raw" => "1888-03-20"
          },
          extra
        )

      {:applied, %{"author_worker_id" => author, "payload" => payload}}
    end

    # Pollt kurz auf eine Bedingung — der Republish läuft in einem gespawnten
    # Task (fire-and-forget), kein Sync-Signal an den Test-Prozess nötig für
    # den Chronik-Content-Check.
    defp wait_until(fun, tries \\ 20) do
      cond do
        fun.() ->
          true

        tries <= 0 ->
          false

        true ->
          Process.sleep(10)
          wait_until(fun, tries - 1)
      end
    end

    test "Producer (elected) triggert den Republish — Chronik-Eintrag erscheint", %{pid: pid} do
      # Simuliert nur den `:applied`-Broadcast, den der Materializer NACH dem
      # echten Fold sendet — der Fold selbst (Override-Merge) ist in
      # `materializer_fact_date_set_test.exs`/`repo_review_facts_test.exs`
      # getestet. Hier zählt nur: der Trigger liest den AKTUELLEN
      # session_facts-Stand und republisht ihn — daher bereits datiert.
      put_facts([fact("f1")])

      send(pid, date_set_event("w-self"))
      _ = :sys.get_state(pid)

      assert wait_until(fn -> Repo.list_chronik_entries(@cid) != [] end)
      assert [entry] = Repo.list_chronik_entries(@cid)
      assert entry.in_game_date == "1888"
    end

    test "Empfänger (nicht elected) triggert NICHTS", %{pid: pid} do
      put_facts([fact("f1")])

      send(pid, date_set_event("w-other"))
      _ = :sys.get_state(pid)

      refute_receive {:pipeline_stage, %{"stage" => "timeline"}}, 100
      assert Repo.list_chronik_entries(@cid) == []
    end

    test "kein Skip bei dismissed — with_status(timeline) läuft trotzdem (Design D)", %{pid: pid} do
      put_facts([fact("f1")])

      send(pid, date_set_event("w-self", %{"dismissed" => true, "in_game_date_raw" => ""}))
      _ = :sys.get_state(pid)

      assert_receive {:pipeline_stage, %{"stage" => "timeline", "status" => "started"}}, 500
    end
  end
end
