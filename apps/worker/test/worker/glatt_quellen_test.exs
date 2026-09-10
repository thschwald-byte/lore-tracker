defmodule Worker.GlattQuellenTest do
  @moduledoc """
  Issue #1198: der Worker löst die `source_refs` der Derivationen selbst auf und
  rechnet den 🕳-Marker — der Hub bekommt nicht mehr das Skelett aller Blöcke.

  Festgenagelt werden vier Dinge:

  1. **Ohne Flag ändert sich nichts** — die Rollback-Sicherheit für einen alten
     Hub. Verglichen wird gegen `Worker.Repo.Snapshots.snapshot/1` direkt.
  2. **Dieselbe Auflösung wie bisher im Hub** (`Refs.resolve_source_refs/2`,
     #1094): Unbekanntes und Altdaten durchreichen, Blöcke ohne Quellen
     durchreichen, `uniq`.
  3. **Kampagnenweit.** Ein Chronik-Eintrag, der Blöcke aus zwei Sessions
     zitiert, wird vollständig aufgelöst und bekommt seinen Marker.
  4. **Der Marker ist in jeder Antwort vollständig** — auch die schmale
     Chronik-Antwort nennt die Resümee-Marker.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Repo.GlattQuellen

  @cid "glatt-quellen-camp"
  @owner "did-owner-gq"
  @member "did-member-gq"
  @stranger "did-stranger-gq"
  @s1 "#{@cid}-s1"
  @s2 "#{@cid}-s2"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      owner_did: @owner,
      members: [@member],
      sessions: [6, 4],
      apply: true
    )

    # S1: b1 (Lücke, offen), b2 (keine Lücke), b3 (Lücke, gleich kuratiert).
    smooth!(@s1, [{"b1", [1, 2], true}, {"b2", [3, 4], false}, {"b3", [5, 6], true}], 30_000)
    # S2: c1 (Lücke, offen), c2 (keine Lücke), c0 (bekannt, aber ohne Quellen).
    smooth!(@s2, [{"c1", [1, 2], true}, {"c2", [3, 4], false}, {"c0", [], false}], 30_001)

    apply!("LueckenKurationSet", 30_002, %{
      "session_id" => @s1,
      "campaign_id" => @cid,
      "block_id" => "#{@s1}-b3",
      "status" => "bestaetigt",
      "bestaetigter_text" => "bestätigt",
      "quell_utterance_ids" => ["#{@s1}-u5", "#{@s1}-u6"],
      "set_by" => @member
    })

    summary!(@s1, ["#{@s1}-b1", "#{@s1}-b2"], 30_010)
    summary!(@s2, ["#{@s2}-c2"], 30_011)

    # Zitiert Blöcke BEIDER Sessions — nur c1 (S2) ist offen.
    chronik!("chr-quer", @s1, ["#{@s1}-b2", "#{@s2}-c1"], 30_020)
    # Altdaten: source_refs sind Utterance-IDs, keine Blöcke.
    chronik!("chr-alt", @s1, ["#{@s1}-u6"], 30_021)

    kapitel!(@s1, ["#{@s1}-b3"], 30_030)
    kapitel!(@s2, ["#{@s2}-c2", "#{@s2}-c0"], 30_031)

    :ok
  end

  defp apply!(kind, seq, payload),
    do: Materializer.apply_event(event(kind, payload, seq, event_id: "gq-#{seq}"))

  defp smooth!(sid, bloecke, seq) do
    blocks =
      for {name, utts, luecke} <- bloecke do
        %{
          "id" => "#{sid}-#{name}",
          "speaker_discord_id" => @owner,
          "text" => "Text #{name}",
          "quell_utterance_ids" => Enum.map(utts, &"#{sid}-u#{&1}"),
          "hat_luecke" => luecke
        }
      end

    apply!("TranscriptSmoothed", seq, %{
      "session_id" => sid,
      "campaign_id" => @cid,
      "smoothed_at" => "2026-09-10T08:00:00Z",
      "blocks" => blocks,
      "ooc_verworfen" => [],
      "rules_version" => 7,
      "merge_gap_seconds" => 8
    })
  end

  defp summary!(sid, refs, seq) do
    apply!("SessionSummaryGenerated", seq, %{
      "session_id" => sid,
      "campaign_id" => @cid,
      "content_md" => "Resümee #{sid}",
      "source" => "llm",
      "source_refs" => refs
    })
  end

  defp chronik!(id, sid, refs, seq) do
    apply!("ChronikEntryChanged", seq, %{
      "id" => id,
      "campaign_id" => @cid,
      "in_game_date" => "Tag 1",
      "label" => id,
      "summary" => "Eintrag #{id}",
      "session_id" => sid,
      "source_refs" => refs
    })
  end

  defp kapitel!(sid, refs, seq) do
    apply!("EposEntryEdited", seq, %{
      "entry_id" => sid,
      "campaign_id" => @cid,
      "parent_id" => @cid,
      "new_md" => "Kapitel #{sid}",
      "source" => "llm",
      "source_refs" => refs
    })
  end

  defp scope(kind, extra),
    do: Map.merge(%{"kind" => kind, "id" => @cid, "viewer_discord_id" => @member}, extra)

  defp finde(liste, key, wert), do: Enum.find(liste, &(&1[key] == wert))

  @marker_soll ["chronik:chr-quer", "summary:#{@s1}"]

  describe "aufloesen/2 — dieselbe Semantik wie bisher im Hub (#1094)" do
    test "Block → Quellen, Unbekanntes und leere Blöcke durchreichen, uniq" do
      index = %{
        "b1" => %{quell: ["u1", "u2"], offen?: true},
        "b0" => %{quell: [], offen?: false}
      }

      assert GlattQuellen.aufloesen(["b1", "u9", "b0", "b1"], index) == ["u1", "u2", "u9", "b0"]
      assert GlattQuellen.aufloesen(nil, index) == []
    end
  end

  describe "block_index/1" do
    test "kennt die Blöcke aller Sessions und rechnet Kuration ein" do
      index = GlattQuellen.block_index(@cid)

      assert index["#{@s1}-b1"] == %{quell: ["#{@s1}-u1", "#{@s1}-u2"], offen?: true}
      assert index["#{@s1}-b2"].offen? == false
      # Lücke, aber kuratiert — kein 🕳 mehr.
      assert index["#{@s1}-b3"].offen? == false
      assert index["#{@s2}-c1"].offen? == true
      assert map_size(index) == 6
    end
  end

  describe "marker/2" do
    test "nennt genau die Derivationen, deren rohe Refs eine offene Lücke treffen" do
      assert GlattQuellen.marker(@cid, GlattQuellen.block_index(@cid)) == @marker_soll
    end
  end

  describe "ohne Flag" do
    test "jede der vier Antworten ist byte-identisch zur Snapshots-Klausel" do
      for kind <- ~w(campaign campaign_summaries campaign_chronik campaign_epos) do
        sc = scope(kind, %{"glatt" => "lazy"})
        assert Repo.snapshot(sc) == Worker.Repo.Snapshots.snapshot(sc), kind
      end
    end
  end

  describe "mit Flag" do
    test "campaign: Derivationen tragen ihre Utterances, kampagnenweit aufgelöst" do
      snap = Repo.snapshot(scope("campaign", %{"glatt" => "lazy", "refs" => "aufgeloest"}))

      refute Map.has_key?(snap, "smoothed")

      assert finde(snap["summaries"], "session_id", @s1)["quell_utterance_ids"] ==
               ["#{@s1}-u1", "#{@s1}-u2", "#{@s1}-u3", "#{@s1}-u4"]

      assert finde(snap["chronik"], "id", "chr-quer")["quell_utterance_ids"] ==
               ["#{@s1}-u3", "#{@s1}-u4", "#{@s2}-u1", "#{@s2}-u2"]

      # Altdaten bleiben stehen, wie sie sind.
      assert finde(snap["chronik"], "id", "chr-alt")["quell_utterance_ids"] == ["#{@s1}-u6"]

      # Ein Block ohne Quellen wird durchgereicht, nicht verschluckt.
      assert finde(snap["epos_chapters"], "id", @s2)["quell_utterance_ids"] ==
               ["#{@s2}-u3", "#{@s2}-u4", "#{@s2}-c0"]

      assert snap["luecken_marker"] == @marker_soll
    end

    test "die schmale Chronik-Antwort trägt trotzdem den VOLLEN Marker" do
      snap = Repo.snapshot(scope("campaign_chronik", %{"refs" => "aufgeloest"}))

      assert Map.keys(snap) |> Enum.sort() == ["chronik", "luecken_marker"]
      assert snap["luecken_marker"] == @marker_soll
    end

    test "Resümee- und Epos-Scope werden ebenfalls angereichert" do
      sum = Repo.snapshot(scope("campaign_summaries", %{"refs" => "aufgeloest"}))
      assert Enum.all?(sum["summaries"], &Map.has_key?(&1, "quell_utterance_ids"))

      epos = Repo.snapshot(scope("campaign_epos", %{"refs" => "aufgeloest"}))
      assert Enum.all?(epos["epos_chapters"], &Map.has_key?(&1, "quell_utterance_ids"))
      assert epos["luecken_marker"] == @marker_soll
    end

    test "eine Ablehnung geht unverändert durch" do
      sc = %{
        scope("campaign_chronik", %{"refs" => "aufgeloest"})
        | "viewer_discord_id" => @stranger
      }

      assert Repo.snapshot(sc) == %{"forbidden" => true}
    end
  end

  describe "sicher/2" do
    test "eine Exception kostet nicht die Antwort — die geht unverändert raus" do
      snap = %{"chronik" => []}

      log =
        capture_log(fn ->
          assert GlattQuellen.sicher(snap, fn _ -> raise "kaputt" end) == snap
        end)

      assert log =~ "Anreicherung gescheitert"
    end

    test "ein exit ebenso" do
      snap = %{"chronik" => []}

      log =
        capture_log(fn ->
          assert GlattQuellen.sicher(snap, fn _ -> exit(:weg) end) == snap
        end)

      assert log =~ "Anreicherung abgebrochen"
    end
  end
end
