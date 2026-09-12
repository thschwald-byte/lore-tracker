defmodule Worker.Recording.PipelineWahrheitsbildTest do
  @moduledoc """
  Issues #714 + #716: End-to-End-Test des Wahrheitsbild-Orchestrators
  (`Pipeline.run_wahrheitsbild/4`) mit injizierten Schritt-Deps (kein LLM,
  kein Sidecar — die Pur-Kerne haben eigene Tests).

  Abgedeckt:
  - Happy path: extract → registry → verify → render → SessionSummaryGenerated
    (Worker-First-Apply, Summary + source_refs-Union im Repo).
  - #714: Registry läuft ZWISCHEN Extraktion und Verify; Registry-Fehler
    bricht die Pipeline NICHT (Fakten unverändert, Lauf wird :ok).
  - #716: Schritt-Fehler landen getaggt in /admin/errors mit der richtigen
    Fehlerklasse (sidecar_offline / no_verified_facts / extraction_empty),
    Folge-Schritte laufen nicht mehr.
  - classify_pipeline_error-Klauseln für die neuen Wrapper-Tags (pure).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Schema.Builder

  @session %{id: "s-wb", number: 1}
  @campaign %{id: "c-wb"}
  @testbogen "der Testbogen"

  setup do
    clear_all_tables!()
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)

    Builder.write!(Builder.campaign("c-wb"))
    Builder.write!(Builder.session("s-wb", "c-wb", number: 1))

    # Issue #911/#958: etabliert "der Testbogen" als echten arc-kind-Strang in
    # campaign_threads/1 — die Fixture-Fakten dieser Datei tragen dasselbe
    # thread-Label (fact/2) und werden dadurch per Label-Match als arc-kind
    # erkannt (Repo.filter_arc_kind/2), ohne dass ihre konkrete ID im
    # persistierten Korpus vorkommen muss (Label-Match genügt, s.
    # repo_fact_render_assignments_test.exs "unbekannte Fakten…").
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{
          "session_id" => "s-wb",
          "campaign_id" => "c-wb",
          "facts" => [
            %{
              "id" => "seed-arc",
              "claim" => "Seed.",
              "thread" => @testbogen,
              "verified?" => true,
              "fact_type" => "ereignis"
            }
          ]
        },
        1,
        event_id: "sfe-wb-seed"
      )
    )

    :ok
  end

  defp fact(id, refs) do
    %{
      "id" => id,
      "claim" => "Claim #{id}",
      "entity_id" => "e",
      "character_alias" => "Figur",
      "thread" => @testbogen,
      "source_refs" => refs,
      "grounded?" => true,
      "attributed?" => true,
      "verified?" => true
    }
  end

  defp rendered(md), do: %{md: md}

  # Schritt-Stub, der seinen Aufruf an den Test-Prozess meldet (Reihenfolge-
  # und Nicht-Aufruf-Beweise) und `result` liefert.
  defp step(tag, result) do
    parent = self()

    fn ->
      send(parent, {:step, tag})
      result
    end
  end

  defp last_error do
    Worker.Repo.Snapshots.last_n_pipeline_errors(1) |> List.first()
  end

  # Issue #724 Slice E: Fakt mit in_game_date + Deps-Bündel für den Timeline-Test.
  defp dated_fact(id, date), do: Map.put(fact(id, ["u-#{id}"]), "in_game_date", date)

  defp tl_deps(verified) do
    %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{}}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ -> {:ok, rendered("prosa.")} end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }
  end

  # J5 (#1209, B4): `source_refs` sind die Belege der ZITIERTEN Fakten — f3
  # nennt kein Satz, seine Belege gehören nicht zum Resümee. Vorher war es die
  # Vereinigung aller Fakten.
  test "happy path: publiziert SessionSummaryGenerated mit den Quellen der zitierten Fakten" do
    verified = [fact("f1", ["u-1", "u-2"]), fact("f2", ["u-2", "u-3"]), fact("f3", ["u-9"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{"könig" => "koenig"}}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn facts ->
        send(self(), {:step, :render})
        assert facts == verified

        {:ok,
         %{
           md: "Es begab sich aber zu der Zeit.",
           satzquellen: [
             %{"text" => "Es begab sich.", "fakt_ids" => ["f1"]},
             %{"text" => "Aber zu der Zeit.", "fakt_ids" => ["f2", "f-frueher"]}
           ],
           zaehlwerte: %{"absaetze" => 1},
           modell: "resuemee-modell"
         }}
      end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    summary = Repo.get_session_summary("s-wb")
    assert summary.content_md == "Es begab sich aber zu der Zeit."
    assert Enum.sort(summary.source_refs) == ["u-1", "u-2", "u-3"]
  end

  test "#714: Registry läuft zwischen Extraktion und Verify (Reihenfolge)" do
    verified = [fact("f1", ["u-1"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{}}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ ->
        send(self(), {:step, :render})
        {:ok, rendered("ok.")}
      end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    assert {:messages,
            [
              {:step, :extract},
              {:step, :resolve},
              {:step, :resolve_threads},
              {:step, :verify},
              {:step, :render}
            ]} = Process.info(self(), :messages)
  end

  test "#714: Registry-Fehler bricht die Pipeline NICHT (best-effort, Fakten unverändert)" do
    verified = [fact("f1", ["u-1"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:error, :parse_failed}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ -> {:ok, rendered("trotzdem da.")} end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }

    log =
      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
      end)

    assert log =~ "Entity-Registry-Clustering fehlgeschlagen"
    assert Repo.get_session_summary("s-wb").content_md == "trotzdem da."
  end

  test "#820: Registry-Fehler landet zusätzlich in /admin/errors (Stage 'resolve'), Lauf bleibt :ok" do
    verified = [fact("f1", ["u-1"])]

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:error, :no_entities_key}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ -> {:ok, rendered("trotzdem da.")} end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }

    capture_log(fn ->
      assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    err = last_error()
    assert err.stage == "resolve"
    assert err.error_type == "entity_registry_no_entities_key"
    assert err.session_id == "s-wb"
    assert err.campaign_id == "c-wb"
    # Best-effort: der Lauf ist trotzdem erfolgreich durchgelaufen.
    assert Repo.get_session_summary("s-wb").content_md == "trotzdem da."
  end

  test "#716: Verify-Sidecar offline → getaggter Fehler, Render läuft nicht, /admin/errors-Klasse stimmt" do
    deps = %{
      extract: step(:extract, {:ok, [fact("f1", ["u-1"])]}),
      resolve: step(:resolve, {:ok, %{}}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:error, :sidecar_offline}),
      render: fn _ ->
        send(self(), {:step, :render})
        {:ok, rendered("nie.")}
      end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }

    capture_log(fn ->
      assert {:error, {:verify, :sidecar_offline}} =
               Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    refute_received {:step, :render}
    assert Repo.get_session_summary("s-wb") == nil

    err = last_error()
    assert err.error_type == "sidecar_offline"
    assert err.stage == "verify"
    assert err.session_id == "s-wb"
  end

  # J5 (#1209, B4): das Resümee meldet der Resümee-Jack selbst (samt
  # /admin/errors, siehe `Worker.Jack.Resuemee.PipelineTest`); ein injizierter
  # Schritt meldet nichts. Was hier bleibt, ist die Folge im Lauf: ohne
  # Resümee endet er, wie früher beim Render — kein Kapitel, kein Resümee.
  test "#716/J5: scheitert das Resümee, endet der Lauf — Epos und Resümee bleiben aus" do
    verified = [fact("f1", ["u-1"])]
    parent = self()

    deps = %{
      extract: step(:extract, {:ok, verified}),
      resolve: step(:resolve, {:ok, %{}}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, verified}),
      render: fn _ -> {:error, {:schreiben_ohne_abschluss, :stopp}} end,
      render_epos: fn _ ->
        send(parent, {:step, :render_epos})
        {:ok, rendered("nie.")}
      end
    }

    capture_log(fn ->
      assert {:error, {:render, {:schreiben_ohne_abschluss, :stopp}}} =
               Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    assert Repo.get_session_summary("s-wb") == nil
    refute_received {:step, :render_epos}
  end

  test "#716: leere Extraktion — Registry/Verify laufen nicht" do
    deps = %{
      extract: step(:extract, {:error, {:extraction, :empty}}),
      resolve: step(:resolve, {:ok, %{}}),
      resolve_threads: step(:resolve_threads, {:ok, %{}}),
      verify: step(:verify, {:ok, []}),
      render: fn _ -> {:ok, rendered("nie.")} end,
      render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
    }

    capture_log(fn ->
      assert {:error, {:extraction, :empty}} =
               Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
    end)

    refute_received {:step, :resolve}
    refute_received {:step, :verify}

    # J4 (#1207): den Fehler nach /admin/errors bringt Jack selbst
    # (`:melde_stufe`, pipeline_lauf_test.exs) — `run_wahrheitsbild`
    # umschließt die Extraktion nicht mehr, ein injizierter Schritt meldet also
    # nichts.
    assert last_error() == nil
  end

  describe "Laufband: Jacks Stufen (J4, #1207)" do
    setup do
      Phoenix.PubSub.subscribe(Worker.PubSub, "pipeline_status")
      :ok
    end

    defp stufen_meldungen(acc \\ []) do
      receive do
        {:pipeline_stage, %{"kind" => "pipeline_stage"} = p} ->
          stufen_meldungen([{p["stage"], p["status"]} | acc])

        {:pipeline_stage, _fortschritt} ->
          stufen_meldungen(acc)
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "run_wahrheitsbild reicht Jack den Melder: ein Fehler vor den Phasen ist ein Fehlschlag von extract" do
      # Ohne `deps.extract` läuft der echte Jack; ohne `local_endpoint` endet er
      # vor der ersten Phase. Sichtbar werden muss das trotzdem.
      # `clear_all_tables!/0` lässt worker_state stehen, und andere Tests setzen
      # dort einen Endpunkt (Muster pipeline_einstellungen_test.exs).
      {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

      deps = %{
        run_id: "r-1207",
        resolve: step(:resolve, {:ok, %{}}),
        resolve_threads: step(:resolve_threads, {:ok, %{}}),
        verify: step(:verify, {:ok, []}),
        render: fn _ -> {:ok, rendered("nie.")} end,
        render_epos: fn _ -> {:ok, rendered("kapitel-prosa.")} end
      }

      capture_log(fn ->
        assert {:error, :no_local_endpoint_configured} =
                 Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
      end)

      assert stufen_meldungen() == [{"extract", "started"}, {"extract", "failed"}]
      refute_received {:step, :resolve}

      err = last_error()
      assert err.stage == "extract"
      assert err.error_type == "no_local_endpoint_configured"
    end

    test "der Bestand nach den Registries ist keine Stufe mehr — kein \"verify\" im Band" do
      verified = [fact("f1", ["u-1"])]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
      end)

      ms = stufen_meldungen()
      # Das Resümee meldet seit J5 der Resümee-Jack selbst; hier ist es
      # injiziert. Die Geschwister danach melden sich über `with_status`.
      assert {"timeline", "started"} in ms
      refute Enum.any?(ms, fn {stage, _} -> stage == "verify" end)
    end

    test "stufen_melder: Beginn, Ende und Fehlschlag wie with_status, Fehler in /admin/errors" do
      melde = Pipeline.stufen_melder("c-wb", "s-wb", "r-1")

      melde.("jack_verifikation", :beginn)

      assert_receive {:pipeline_stage,
                      %{
                        "kind" => "pipeline_stage",
                        "stage" => "jack_verifikation",
                        "status" => "started",
                        "session_id" => "s-wb",
                        "run_id" => "r-1"
                      }}

      melde.("jack_verifikation", {:ende, {:error, {:extraction, {:jack, :abgebrochen}}}})

      assert_receive {:pipeline_stage,
                      %{
                        "kind" => "pipeline_stage",
                        "stage" => "jack_verifikation",
                        "status" => "failed"
                      }}

      err = last_error()
      assert err.stage == "jack_verifikation"
      assert err.session_id == "s-wb"

      melde.("jack_gedaechtnis", {:ende, :ok})

      assert_receive {:pipeline_stage,
                      %{
                        "kind" => "pipeline_stage",
                        "stage" => "jack_gedaechtnis",
                        "status" => "ended"
                      }}

      # Zählung und gelesene Blöcke gehen an `Fortschritt`, nicht an die
      # Stufenmeldung — sie dürfen auch ohne laufenden Koordinator nicht werfen.
      assert :ok = melde.("extract", {:zaehlung, 18, nil})
      assert :ok = melde.("extract", {:gelesen, 3, nil})
    end
  end

  describe "Timeline-Publish (#724 Slice E)" do
    test "publiziert datierte Fakten als Chronik; Flashback landet global vor der Gegenwart" do
      verified = [dated_fact("present", "1888"), dated_fact("flash", "1850")]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
      end)

      entries = Repo.list_chronik_entries("c-wb")
      assert length(entries) == 2
      # Beide gegen den Default-Kalender zu echten Tageszählern aufgelöst …
      assert Enum.all?(entries, &is_integer(&1.in_game_day))
      # … und global chronologisch sortiert (1850 vor 1888), egal in welcher
      # Reihenfolge die Fakten kamen.
      assert Enum.map(entries, & &1.in_game_date) == ["1850", "1888"]
      assert Enum.map(entries, & &1.precision) == ["year", "year"]
    end

    test "Re-Run clärt + schreibt neu (keine Akkumulation, #227-Idempotenz)" do
      verified = [dated_fact("a", "1888")]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
      end)

      assert length(Repo.list_chronik_entries("c-wb")) == 1
    end

    test "unparsebares in_game_date → Eintrag mit nil-Tageszähler, Roh-String bewahrt" do
      capture_log(fn ->
        assert :ok =
                 Pipeline.run_wahrheitsbild(
                   @session,
                   @campaign,
                   [],
                   tl_deps([dated_fact("t", "Tag 5")])
                 )
      end)

      [e] = Repo.list_chronik_entries("c-wb")
      assert e.in_game_day == nil
      assert e.in_game_date == "Tag 5"
    end

    test "Flashback mit time_offset landet vor dem Session-Anker (relative Auflösung, #724 Slice D)" do
      # Session-Anker = 1. Tag Jahr 1000 (Default-Kalender).
      cal = Worker.Timeline.Calendar.default()
      anchor_day = Worker.Timeline.Calendar.to_day(cal, {1000, 1, 1})

      Builder.write!(
        Builder.session_anchor("s-wb", "c-wb",
          in_game_day: anchor_day,
          in_game_date_raw: "Jahr 1000"
        )
      )

      # Flashback ohne explizites Datum, aber mit Offset „vor 10 Jahren" — genau
      # die Feld-Kombination, die die Slice-D-Extraktion jetzt liefert.
      flashback =
        fact("fb", ["u-1"])
        |> Map.merge(%{
          "narration_time" => "flashback",
          "time_offset" => %{"value" => -10, "unit" => "year"}
        })

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps([flashback]))
      end)

      [e] = Repo.list_chronik_entries("c-wb")
      assert is_integer(e.in_game_day)
      assert e.in_game_day == Worker.Timeline.Calendar.to_day(cal, {990, 1, 1})
      assert e.in_game_day < anchor_day
    end

    test "undatierte Fakten fließen NICHT in den Zeitstrahl" do
      # fact/2 setzt kein in_game_date → nicht datiert → kein Chronik-Eintrag.
      capture_log(fn ->
        assert :ok =
                 Pipeline.run_wahrheitsbild(
                   @session,
                   @campaign,
                   [],
                   tl_deps([fact("u", ["u-1"])])
                 )
      end)

      assert Repo.list_chronik_entries("c-wb") == []
    end

    # Issue #911/#958: die Kern-Behauptungen dieses Issues — kind-Filter und
    # Echtdatum-Pflicht schließen genau die Fälle aus, die den
    # Chronik-Dump verursacht haben (544/548 bei der Free-Seattle-Analyse).

    test "context-kind Fakt mit validem Datum landet NICHT in der Chronik" do
      Materializer.apply_event(
        event(
          "SessionFactsExtracted",
          %{
            "session_id" => "s-wb",
            "campaign_id" => "c-wb",
            "facts" => [
              %{
                "id" => "seed-context",
                "claim" => "Weltwissen.",
                "thread" => "die Welt",
                "verified?" => true,
                "fact_type" => "ereignis"
              }
            ]
          },
          2,
          event_id: "sfe-wb-context"
        )
      )

      Materializer.apply_event(
        event(
          "ThreadRegistryComputed",
          %{"campaign_id" => "c-wb", "cluster_map" => %{}, "kinds" => %{"die welt" => "context"}},
          3,
          event_id: "trc-wb-context"
        )
      )

      arc_fact = dated_fact("a", "1888")
      context_fact = dated_fact("b", "1889") |> Map.put("thread", "die Welt")

      capture_log(fn ->
        assert :ok =
                 Pipeline.run_wahrheitsbild(
                   @session,
                   @campaign,
                   [],
                   tl_deps([arc_fact, context_fact])
                 )
      end)

      assert Enum.map(Repo.list_chronik_entries("c-wb"), & &1.in_game_date) == ["1888"]
    end

    test "strang-loser Fakt (kein Thread-Label) mit validem Datum landet NICHT in der Chronik" do
      arc_fact = dated_fact("a", "1888")
      strandlos_fact = dated_fact("b", "1889") |> Map.put("thread", "")

      capture_log(fn ->
        assert :ok =
                 Pipeline.run_wahrheitsbild(
                   @session,
                   @campaign,
                   [],
                   tl_deps([arc_fact, strandlos_fact])
                 )
      end)

      assert Enum.map(Repo.list_chronik_entries("c-wb"), & &1.in_game_date) == ["1888"]
    end

    test "arc-kind Fakt ohne echtes Zeit-Signal (reiner Präsens-Fallback) landet NICHT in der Chronik" do
      arc_fact = dated_fact("a", "1888")
      # fact/2 setzt schon "thread" (arc-kind) — hier bewusst KEIN in_game_date/
      # time_anchor/time_offset, nur der Präsens-Fallback.
      present_fact = fact("b", ["u-b"]) |> Map.put("narration_time", "present")

      capture_log(fn ->
        assert :ok =
                 Pipeline.run_wahrheitsbild(
                   @session,
                   @campaign,
                   [],
                   tl_deps([arc_fact, present_fact])
                 )
      end)

      assert Enum.map(Repo.list_chronik_entries("c-wb"), & &1.in_game_date) == ["1888"]
    end
  end

  describe "Epos-Kapitel Ep_n (#752)" do
    test "happy path: Kapitel-Row (entry_id=session, parent=campaign) mit deterministischem Kopf" do
      verified = [dated_fact("a", "1888"), dated_fact("b", "1889")]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
      end)

      assert [chapter] = Repo.list_epos_chapters("c-wb")
      assert chapter.id == "s-wb"
      assert chapter.parent_id == "c-wb"
      assert chapter.session_number == 1
      # Kopf deterministisch aus der Timeline-Range (zwei Jahre → zwei
      # verschiedene Tageszähler), dann die gegatete Prosa.
      #
      # Issue #1092: als DATUM, nicht als Epochen-Tageszähler. Vorher stand
      # hier real „## Kapitel 1 — Tag 689578–689942" — eine Seriennummer, die
      # kein Leser einordnen kann.
      assert chapter.content_md =~ ~r/\A## Kapitel 1 — 1888–1889\n/
      refute chapter.content_md =~ "Tag 6"
      assert chapter.content_md =~ "kapitel-prosa."
      # Die Legacy-Single-Row (entry_id = campaign_id) existiert NICHT als Kapitel.
      assert Repo.get_epos_entry("c-wb") == nil
    end

    test "Session ohne datierte Fakten → nackter Kapitel-Kopf (keine Tag-?-Leichen)" do
      verified = [fact("f1", ["u-1"])]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
      end)

      assert [chapter] = Repo.list_epos_chapters("c-wb")
      assert String.starts_with?(chapter.content_md, "## Kapitel 1\n")
      refute chapter.content_md =~ "Tag ?"
    end

    test "Mixed-State: Legacy-Buch bleibt unberührt neben dem Kapitel" do
      # Legacy-Buch wie von Chain-Stage-3 publisht (entry_id = campaign_id, kein parent).
      capture_log(fn ->
        {:ok, _} =
          Worker.Intents.publish(%{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => "c-wb",
            "campaign_id" => "c-wb",
            "new_md" => "Das alte Buch.",
            "edited_by" => "llm",
            "source" => "llm",
            "source_refs" => []
          })

        assert :ok =
                 Pipeline.run_wahrheitsbild(
                   @session,
                   @campaign,
                   [],
                   tl_deps([fact("f1", ["u-1"])])
                 )
      end)

      # Legacy-Row unverändert, Kapitel separat — und das Kapitel listet die
      # Legacy-Row nicht.
      assert Repo.get_epos_entry("c-wb").content_md == "Das alte Buch."
      assert [%{id: "s-wb"}] = Repo.list_epos_chapters("c-wb")
    end

    test "Ep_n-Fehler reißt weder Lauf noch Resümee/Timeline mit (Entkopplung + /admin/errors)" do
      verified = [dated_fact("a", "Tag 3")]

      deps = %{
        extract: step(:extract, {:ok, verified}),
        resolve: step(:resolve, {:ok, %{}}),
        resolve_threads: step(:resolve_threads, {:ok, %{}}),
        verify: step(:verify, {:ok, verified}),
        render: fn _ -> {:ok, rendered("resümee.")} end,
        render_epos: fn _ -> {:error, :no_verified_facts} end
      }

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
      end)

      # Resümee + Timeline sind da, Kapitel nicht — Fehler klassifiziert persistiert.
      assert Repo.get_session_summary("s-wb").content_md == "resümee."
      assert length(Repo.list_chronik_entries("c-wb")) == 1
      assert Repo.list_epos_chapters("c-wb") == []

      err = last_error()
      assert err.stage == "render_epos"
      assert err.error_type == "no_verified_facts"
    end

    test "Re-Run derselben Session überschreibt das Kapitel (LWW), akkumuliert nicht" do
      verified = [fact("f1", ["u-1"])]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))
      end)

      assert [_nur_eins] = Repo.list_epos_chapters("c-wb")
    end

    # Issue #753: LWW-Guard — ein GM-editiertes Kapitel wird vom Re-Run NICHT
    # überschrieben; der Render-Schritt läuft gar nicht erst (kein LLM-Call).
    test "#753 LWW-Guard: GM-editiertes Kapitel überlebt den Re-Run, render_epos läuft nicht" do
      verified = [fact("f1", ["u-1"])]

      capture_log(fn ->
        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], tl_deps(verified))

        # GM-Edit wie aus der Kapitel-Edit-UI (#753): source "manual" schreibt
        # die History-Row, die der Guard als Marker liest.
        {:ok, _} =
          Worker.Intents.publish(%{
            "kind" => Shared.Events.epos_entry_edited(),
            "entry_id" => "s-wb",
            "campaign_id" => "c-wb",
            "parent_id" => "c-wb",
            "new_md" => "## Kapitel 1\n\nGM-Fassung.",
            "edited_by" => "gm-did",
            "source" => "manual"
          })

        parent = self()

        deps =
          Map.put(tl_deps(verified), :render_epos, fn _ ->
            send(parent, {:step, :render_epos})
            {:ok, rendered("neu-generiert.")}
          end)

        assert :ok = Pipeline.run_wahrheitsbild(@session, @campaign, [], deps)
      end)

      refute_received {:step, :render_epos}
      assert [chapter] = Repo.list_epos_chapters("c-wb")
      assert chapter.content_md =~ "GM-Fassung."
      refute chapter.content_md =~ "neu-generiert."
    end
  end

  describe "classify_pipeline_error/1 — Wahrheitsbild-Tags (pure, #716)" do
    test "Schritt-Wrapper werden gestrippt wie die Chain-Wrapper" do
      assert Pipeline.classify_pipeline_error({:extraction, :timeout}) == "timeout"
      assert Pipeline.classify_pipeline_error({:verify, :no_facts}) == "no_facts"

      assert Pipeline.classify_pipeline_error({:render, :spend_cap_exceeded}) ==
               "spend_cap_exceeded"
    end

    test "Wahrheitsbild-Klassen" do
      assert Pipeline.classify_pipeline_error({:verify, :sidecar_offline}) == "sidecar_offline"

      assert Pipeline.classify_pipeline_error({:render, :no_verified_facts}) ==
               "no_verified_facts"

      assert Pipeline.classify_pipeline_error({:extraction, :empty}) == "extraction_empty"

      assert Pipeline.classify_pipeline_error({:extraction, :all_chunks_failed}) ==
               "all_chunks_failed"
    end

    # #889/#909: der fail-loud Prompt-Größen-Guard der Render-Stages.
    test "render_prompt_too_large (Stage 4 + 5, mit est/cap-Tupel)" do
      assert Pipeline.classify_pipeline_error({:render, {:prompt_too_large, 9000, 8192}}) ==
               "render_prompt_too_large"

      assert Pipeline.classify_pipeline_error({:render_epos, {:prompt_too_large, 9000, 8192}}) ==
               "render_prompt_too_large"
    end

    test "#820: EntityRegistry-Klassen (bare, kein Stage-Wrapper — resolve_entities_best_effort ruft ungewrapped auf)" do
      assert Pipeline.classify_pipeline_error(:parse_failed) == "entity_registry_parse_failed"

      assert Pipeline.classify_pipeline_error(:no_entities_key) ==
               "entity_registry_no_entities_key"
    end

    # #838 Schritt 7: :render_arc_progressions strippt wie die anderen
    # Wahrheitsbild-Schritt-Tags — der arc_id-Bezug bleibt bewusst außerhalb
    # der Taxonomie (im Klartext der Fehlermeldung, s. pipeline_arc_progressions_test.exs).
    test "#838: render_arc_progressions strippt wie die anderen Wahrheitsbild-Tags" do
      assert Pipeline.classify_pipeline_error({:render_arc_progressions, :no_verified_facts}) ==
               "no_verified_facts"

      assert Pipeline.classify_pipeline_error(
               {:render_arc_progressions, {:prompt_too_large, 9000, 8192}}
             ) == "render_prompt_too_large"

      # unklassifizierte Atome fallen auf ihre String-Form (nicht "other").
      assert Pipeline.classify_pipeline_error({:render_arc_progressions, :boom}) == "boom"
    end
  end
end
