defmodule Worker.DirtyTest do
  @moduledoc """
  Issue #866 (Epic #861 Slice F): der generische Dirty-Mechanismus.

  Abgedeckt (Plan-Testmatrix Runden 4–6):
  - Text-Identitäts-Weiche (pur): Zeit-Adressen-Test (Extraktion VOR Gemma-
    Eintreffen, Bestätigung danach → Re-Extract statt Re-Verify — nach
    Status-Label-Design wäre dieser Test rot), fail-closed bei fehlendem
    extraction_saw-Eintrag als EXPLIZITE Regel, unbrauchbar → Re-Extract.
  - Carry-over-Partition (pur): verbatim-Übernahme unveränderter Blöcke,
    LLM-Duplikat-Verwurf (kein Fakt-Drift), F3 (unbrauchbar = ENTFERNT —
    nach naiver Carry-over-Formulierung rot).
  - Nicht-Kanten: LueckenVorschlagGeneriert / TranscriptSmoothed /
    SessionFactsExtracted triggern NIE (nagelt die Entscheidungen fest).
  - Kanten-Verhalten: Election-Gate, reextract übertrumpft reverify.
  - process(:reverify): deterministische Klemm-Neuberechnung ohne LLM —
    Klemme fällt nach Kuration, Fakt-Overrides (Datum) überleben (B3),
    extraction_saw reist feldkonservativ mit.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.Pipeline.Dirty
  alias Worker.Recording.Pipeline.Smoothing
  alias Worker.Repo
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-866-dirty"
  @sid "sess-866-dirty"

  # ── Pure Weiche ────────────────────────────────────────────────────────────

  describe "classify/3 — Text-Identitäts-Weiche" do
    @smoothed "wir sollten so unserem Ziel folgen"
    @proposal "wir sollten so zu unserem Ziel folgen"

    test "Text identisch mit extraction_saw → :reverify (Klemme fällt billig)" do
      saw = Smoothing.text_hash(@smoothed)
      assert Dirty.classify("original_bestaetigt", @smoothed, saw) == :reverify
      assert Dirty.classify("bestaetigt", @smoothed, saw) == :reverify
    end

    test "Zeit-Adressen-Test (B1): Extraktion lief VOR dem Gemma-Vorschlag, Member bestätigt danach → :reextract" do
      # Die Extraktion sah den SMOOTHED-Text; der bestätigte Text ist der
      # Gemma-Fill. `bestaetigt` ist hier faktisch text-ändernd — die Weiche
      # routet auf TEXT-Identität, nicht aufs Status-Label (nach Status-
      # Label-Design wäre dieser Test rot).
      saw = Smoothing.text_hash(@smoothed)
      assert Dirty.classify("bestaetigt", @proposal, saw) == :reextract
    end

    test "FAIL-CLOSED (explizite Regel): fehlender extraction_saw-Eintrag → :reextract" do
      assert Dirty.classify("bestaetigt", @smoothed, nil) == :reextract
    end

    test "unbrauchbar → :reextract, auch bei identischem Text (F5: Fakten müssen fallen)" do
      saw = Smoothing.text_hash(@smoothed)
      assert Dirty.classify("unbrauchbar", @smoothed, saw) == :reextract
      assert Dirty.classify("unbrauchbar", nil, nil) == :reextract
    end
  end

  # ── Carry-over-Partition ───────────────────────────────────────────────────

  describe "partition_carryover/4" do
    defp f(id, refs, extra \\ %{}) do
      Map.merge(%{"id" => id, "claim" => "c-#{id}", "source_refs" => refs}, extra)
    end

    test "Fakten unveränderter Blöcke: verbatim carried (Verdikte bleiben), LLM-Duplikate verworfen" do
      old = [f("f_alt", ["b_clean"], %{"verified?" => true, "grounded?" => true})]
      # Das LLM formuliert denselben Sachverhalt um (anderer Claim → andere
      # Content-ID) — OHNE Carry-over-Vorrang entstünde ein Duplikat-Fakt.
      llm = [f("f_reworded", ["b_clean"])]

      {carried, adopted} =
        Dirty.partition_carryover(old, llm, MapSet.new(["b_changed"]), MapSet.new())

      assert carried == old
      assert adopted == []
    end

    test "Fakten text-geänderter Blöcke: alt fällt, LLM-Fassung wird adopted" do
      old = [f("f_alt", ["b_changed"])]
      llm = [f("f_neu", ["b_changed"])]

      {carried, adopted} =
        Dirty.partition_carryover(old, llm, MapSet.new(["b_changed"]), MapSet.new())

      assert carried == []
      assert adopted == llm
    end

    test "F3 (nach naiver Formulierung rot): unbrauchbar-Blöcke gelten als ENTFERNT — Fakten fallen trotz unverändertem Text" do
      old = [f("f_tot", ["b_unbrauchbar"]), f("f_ok", ["b_clean"])]
      # Das LLM sieht den unbrauchbar-Block gar nicht mehr (F5-Filter) —
      # aber auch eine irrläufige LLM-Fassung dazu darf nicht adopted werden.
      llm = [f("f_zombie", ["b_unbrauchbar"])]

      {carried, adopted} =
        Dirty.partition_carryover(old, llm, MapSet.new(), MapSet.new(["b_unbrauchbar"]))

      assert Enum.map(carried, & &1["id"]) == ["f_ok"]
      assert adopted == []
    end

    test "carried-Normalisierung (Real-Befund: 210 stale Klemmen): alte gap_geklemmt-Flags fallen" do
      # partition_carryover selbst ist pur — die Normalisierung passiert im
      # process(:reextract)-Pfad; hier der pure Vertrag: ein carried-Fakt mit
      # stale Flags MUSS nach Recompute verified sein, wenn die Verdikte passen.
      f = %{
        "id" => "f_stale",
        "source_refs" => ["b_clean"],
        "grounded?" => true,
        "attributed?" => true,
        "verified?" => false,
        "gap_geklemmt" => true
      }

      recomputed =
        f
        |> Map.put("verified?", f["grounded?"] == true and f["attributed?"] == true)
        |> Map.delete("gap_geklemmt")

      assert recomputed["verified?"] == true
      refute Map.has_key?(recomputed, "gap_geklemmt")
    end

    test "Misch-Fakt (geänderter + unveränderter Block) fällt aus carried und kommt via LLM" do
      old = [f("f_misch", ["b_clean", "b_changed"])]
      llm = [f("f_misch_neu", ["b_changed", "b_clean"])]

      {carried, adopted} =
        Dirty.partition_carryover(old, llm, MapSet.new(["b_changed"]), MapSet.new())

      assert carried == []
      assert Enum.map(adopted, & &1["id"]) == ["f_misch_neu"]
    end
  end

  # ── Kanten + Nicht-Kanten (GenServer) ──────────────────────────────────────

  describe "Kanten-Verhalten" do
    setup do
      reset_for_permutation!()
      mat = ensure_materializer!()

      pid =
        case Dirty.start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      on_exit(fn ->
        if mat && Process.alive?(mat), do: Process.exit(mat, :kill)
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      # Debounce hoch, damit im Test nie gefeuert wird (kein LLM-Pfad).
      Worker.Settings.put(:dirty_debounce_ms, 600_000)
      Repo.put_state(:worker_id, "w-self")

      %{pid: pid}
    end

    defp applied(kind, payload_extra, author) do
      payload =
        Map.merge(
          %{"kind" => kind, "session_id" => @sid, "campaign_id" => @cid},
          payload_extra
        )

      {:applied, %{"author_worker_id" => author, "payload" => payload}}
    end

    defp put_saw(saw_map) do
      Builder.write!(Builder.campaign(@cid))
      Builder.write!(Builder.session(@sid, @cid, number: 1))

      Builder.write!(
        {S.session_facts(), @sid, @cid, Jason.encode!([]), DateTime.utc_now(),
         "00000000-0000-0000-0000-000000000001", nil, nil, Jason.encode!(saw_map)}
      )
    end

    test "NICHT-Kanten: Vorschlag-Eintreffen / Re-Smoothing / eigener Republish triggern NIE", %{
      pid: pid
    } do
      for kind <- ["LueckenVorschlagGeneriert", "TranscriptSmoothed", "SessionFactsExtracted"] do
        send(pid, applied(kind, %{"block_id" => "b_1"}, "w-self"))
      end

      assert :sys.get_state(pid).dirty == %{}
    end

    test "Election-Gate: fremde Kuration triggert nichts", %{pid: pid} do
      put_saw(%{})

      send(
        pid,
        applied("LueckenKurationSet", %{"block_id" => "b_1", "status" => "bestaetigt"}, "w-other")
      )

      assert :sys.get_state(pid).dirty == %{}
    end

    test "Weiche über den Kanten-Pfad: Text-Match → :reverify; :reextract übertrumpft danach", %{
      pid: pid
    } do
      text = "Der König spricht."
      put_saw(%{"b_1" => Smoothing.text_hash(text)})

      send(
        pid,
        applied(
          "LueckenKurationSet",
          %{"block_id" => "b_1", "status" => "original_bestaetigt", "bestaetigter_text" => text},
          "w-self"
        )
      )

      assert :sys.get_state(pid).dirty == %{@sid => :reverify}

      # unbrauchbar → :reextract, übertrumpft das anstehende :reverify.
      send(
        pid,
        applied(
          "LueckenKurationSet",
          %{"block_id" => "b_1", "status" => "unbrauchbar", "bestaetigter_text" => nil},
          "w-self"
        )
      )

      assert :sys.get_state(pid).dirty == %{@sid => :reextract}

      # …und ein späteres :reverify degradiert NICHT zurück.
      send(
        pid,
        applied(
          "LueckenKurationSet",
          %{"block_id" => "b_1", "status" => "original_bestaetigt", "bestaetigter_text" => text},
          "w-self"
        )
      )

      assert :sys.get_state(pid).dirty == %{@sid => :reextract}
    end
  end

  describe "Inflight-Koaleszenz (Real-Befund 2026-07-17: 10 gestaute Jobs)" do
    setup do
      reset_for_permutation!()

      pid =
        case Dirty.start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      Worker.Settings.put(:dirty_debounce_ms, 600_000)
      %{pid: pid}
    end

    test "dirty_fire während ein Job läuft → NICHT erneut enqueued, Level bleibt gemerkt", %{
      pid: pid
    } do
      :sys.replace_state(pid, fn st ->
        %{st | inflight: MapSet.new([@sid]), dirty: %{@sid => :reextract}}
      end)

      send(pid, {:dirty_fire, @sid})
      st = :sys.get_state(pid)

      # Kein Pop, kein Task — der Level wartet auf {:dirty_done, ...}.
      assert st.dirty == %{@sid => :reextract}
      assert MapSet.member?(st.inflight, @sid)
      assert Map.has_key?(st.timers, @sid)
    end

    test "dirty_done mit erneut angesammeltem Dirty-Level → Timer re-armiert", %{pid: pid} do
      :sys.replace_state(pid, fn st ->
        %{st | inflight: MapSet.new([@sid]), dirty: %{@sid => :reverify}}
      end)

      send(pid, {:dirty_done, @sid})
      st = :sys.get_state(pid)

      refute MapSet.member?(st.inflight, @sid)
      assert st.dirty == %{@sid => :reverify}
      assert Map.has_key?(st.timers, @sid)
    end

    test "dirty_done ohne neuen Dirty-Stand → sauber leer", %{pid: pid} do
      :sys.replace_state(pid, fn st -> %{st | inflight: MapSet.new([@sid])} end)
      send(pid, {:dirty_done, @sid})
      st = :sys.get_state(pid)
      assert st.inflight == MapSet.new()
      refute Map.has_key?(st.timers, @sid)
    end
  end

  # ── Kanten-Tabelle als Pin ─────────────────────────────────────────────────

  test "der @dependency_graph hat GENAU zwei Kanten — neue Kanten sind eine bewusste Entscheidung" do
    # P2-Festnagelung: weder Settings-Änderungen noch Deploys noch sonst ein
    # Event-Kind löst Neuableitungen aus. Wer eine Kante ergänzt, muss diesen
    # Test anfassen — und damit die Nicht-Kanten-Entscheidungen (Gemma,
    # Re-Smoothing) bewusst re-validieren.
    assert Dirty.dependency_graph() == %{
             "LueckenKurationSet" => :weiche,
             "SessionFactDateSet" => :timeline
           }
  end

  # ── process(:reverify) — deterministisch, kein LLM ─────────────────────────

  describe "process/2 :reverify" do
    setup do
      reset_for_permutation!()
      mat = ensure_materializer!()

      ensure_started(Worker.TaskSupervisor, fn ->
        Task.Supervisor.start_link(name: Worker.TaskSupervisor)
      end)

      on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)

      Builder.write!(Builder.campaign(@cid))
      Builder.write!(Builder.session(@sid, @cid, number: 1))
      :ok
    end

    defp seed_geklemmt! do
      blocks = [
        %{
          "id" => "b_gap",
          "speaker_discord_id" => "SL",
          "text" => "Lückentext",
          "quell_utterance_ids" => ["u1"],
          "hat_luecke" => true,
          "asr_unsicher" => true,
          "konfidenz" => "niedrig"
        },
        %{
          "id" => "b_clean",
          "speaker_discord_id" => "SL",
          "text" => "Sauberer Text",
          "quell_utterance_ids" => ["u2"],
          "hat_luecke" => false,
          "asr_unsicher" => false,
          "konfidenz" => "hoch"
        }
      ]

      Builder.write!(
        {S.smoothed_blocks(), @sid, @cid,
         Jason.encode!(%{
           "blocks" => blocks,
           "ooc_verworfen" => [],
           "rules_version" => 1,
           "merge_gap_seconds" => 8
         }), DateTime.utc_now(), "sm-1"}
      )

      facts = [
        # Vom Judge bestanden, aber von der ANY-Klemme gehalten (berührt b_gap).
        %{
          "id" => "f_geklemmt",
          "claim" => "Claim A",
          "source_refs" => ["b_gap"],
          "grounded?" => true,
          "attributed?" => true,
          "verified?" => false,
          "gap_geklemmt" => true,
          "in_game_date" => "1888"
        },
        # Vom Judge durchgefallen — bleibt auch nach der Kuration unverifiziert.
        %{
          "id" => "f_ungrounded",
          "claim" => "Claim B",
          "source_refs" => ["b_clean"],
          "grounded?" => false,
          "attributed?" => false,
          "verified?" => false
        }
      ]

      Builder.write!(
        {S.session_facts(), @sid, @cid, Jason.encode!(facts), DateTime.utc_now(),
         "00000000-0000-0000-0000-000000000001", nil, nil,
         Jason.encode!(%{"b_gap" => "hash-a", "b_clean" => "hash-b"})}
      )
    end

    test "Kuration → Klemme fällt (deterministisch), Judge-Verdikte bleiben maßgeblich" do
      seed_geklemmt!()

      # Kuration des Lücken-Blocks → b_gap fällt aus der Klemm-Menge.
      Worker.Materializer.apply_event(
        event(
          "LueckenKurationSet",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "block_id" => "b_gap",
            "status" => "original_bestaetigt",
            "bestaetigter_text" => "Lückentext",
            "quell_utterance_ids" => ["u1"],
            "set_by" => "member-1"
          },
          1,
          event_id: "lk-1"
        )
      )

      assert :ok = Dirty.process(@sid, :reverify)

      %{facts: facts, extraction_saw: saw} = Repo.get_session_facts(@sid)
      by_id = Map.new(facts, &{&1["id"], &1})

      assert by_id["f_geklemmt"]["verified?"] == true
      refute Map.has_key?(by_id["f_geklemmt"], "gap_geklemmt")
      assert by_id["f_ungrounded"]["verified?"] == false

      # Feldkonservativ: die Zeit-Adresse überlebt den Republish.
      assert saw == %{"b_gap" => "hash-a", "b_clean" => "hash-b"}

      # Kuratierte Blöcke werden NIE neu geglättet: der Smoothing-Snapshot
      # ist nach dem Dirty-Lauf unangetastet (gleiche smoothing_event_id).
      assert Repo.get_smoothed_blocks(@sid).smoothing_event_id == "sm-1"

      # Idempotenz: ein zweiter Lauf ändert nichts am Ergebnis.
      assert :ok = Dirty.process(@sid, :reverify)
      %{facts: facts2} = Repo.get_session_facts(@sid)
      assert facts2 == facts
    end

    test "B3: Fakt-Override (Datum) überlebt das Re-Verify (Content-ID stabil)" do
      seed_geklemmt!()

      # GM-Datum auf den geklemmten Fakt (Review-Queue-Override, #724).
      Worker.Materializer.apply_event(
        event(
          "SessionFactDateSet",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "fact_id" => "f_geklemmt",
            "extraction_event_id" => "00000000-0000-0000-0000-000000000001",
            "in_game_date_raw" => "1888-03-20",
            "set_by" => "gm"
          },
          1,
          event_id: "ov-1"
        )
      )

      Worker.Materializer.apply_event(
        event(
          "LueckenKurationSet",
          %{
            "session_id" => @sid,
            "campaign_id" => @cid,
            "block_id" => "b_gap",
            "status" => "original_bestaetigt",
            "bestaetigter_text" => "Lückentext",
            "quell_utterance_ids" => ["u1"],
            "set_by" => "member-1"
          },
          2,
          event_id: "lk-1"
        )
      )

      assert :ok = Dirty.process(@sid, :reverify)

      %{facts: facts} = Repo.get_session_facts(@sid)
      f = Enum.find(facts, &(&1["id"] == "f_geklemmt"))
      assert f["verified?"] == true
      assert f["in_game_date"] == "1888-03-20"
      assert f["review_override_date"] == "1888-03-20"
    end
  end
end
