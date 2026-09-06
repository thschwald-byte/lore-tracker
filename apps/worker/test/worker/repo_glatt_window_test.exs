defmodule Worker.RepoGlattWindowTest do
  @moduledoc """
  Issue #1152 (Epic #1146): die geglätteten Blöcke waren die einzige große
  Liste, die #1087 nicht gefenstert hat — an seattleV4 gemessen 2436 KB pro
  Betrachter, 74 % des Haupt-Snapshots.

  Diese Tests nageln drei Dinge fest:

  1. **Ohne Flag ändert sich nichts.** Das ist die Rollback-Sicherheit des
     ganzen Cuts: ein alter Hub gegen einen neuen Worker bekommt unverändert
     alles. Gepinnt wird der exakte Feldsatz je Block — Byte-Identität folgt
     daraus, weil Elixir-Maps kanonisch sind (gleiche Paare ⇒ gleicher Term).
  2. **Das Skelett ist vollständig.** Kein Block fehlt, und `status` +
     `quell_utterance_ids` stehen auch weit außerhalb des Fensters. Ohne sie
     rechnete der Hub falsche Zähler und die Verweis-Karte bräche still ab
     (#1094) — beides ohne jede Fehlermeldung.
  3. **Nachgeladen wird in zwei Formen.** Die Kuratieren-Ansicht filtert über
     ein PRÄDIKAT; ihre Blöcke liegen über die ganze Session verstreut (an
     seattleV4: die letzten 150 Treffer auf Position 1230..1795 von 1802). Ein
     Bereich `[from, count)` kann das nicht ausdrücken.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Repo.Luecken

  @cid "glatt-window-camp"
  @other "glatt-window-other"
  @owner "did-owner-glatt"
  @member "did-member-glatt"
  @stranger "did-stranger-glatt"

  @gross 250
  @klein 10
  @tail 200

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      name: "Glättungs-Fenster",
      owner_did: @owner,
      owner_name: "Owner Glatt",
      members: [@member],
      sessions: [@gross, @klein],
      apply: true
    )

    build_campaign(
      campaign_id: @other,
      name: "Fremde Kampagne",
      owner_did: @stranger,
      owner_name: "Stranger",
      sessions: [3],
      base_seq: 50_000,
      apply: true
    )

    smooth!("#{@cid}-s1", @cid, @gross, 20_000)
    smooth!("#{@cid}-s2", @cid, @klein, 21_000)

    {:ok, s1: "#{@cid}-s1", s2: "#{@cid}-s2", other_s1: "#{@other}-s1"}
  end

  # Ein Block je Utterance — so ist die Blockposition zugleich die
  # Utterance-Nummer, und „Block 3" ist im Test nachvollziehbar.
  defp smooth!(sid, cid, n, seq) do
    blocks =
      for i <- 1..n//1 do
        %{
          "id" => "#{sid}-b#{i}",
          "speaker_discord_id" => "SL",
          "text" => "Block #{i} geglättet",
          "quell_utterance_ids" => ["#{sid}-u#{i}"],
          "hat_luecke" => rem(i, 5) == 0
        }
      end

    Materializer.apply_event(
      event(
        "TranscriptSmoothed",
        %{
          "session_id" => sid,
          "campaign_id" => cid,
          "smoothed_at" => "2026-09-01T20:00:00Z",
          "blocks" => blocks,
          "ooc_verworfen" => [],
          "rules_version" => 7,
          "merge_gap_seconds" => 8
        },
        seq,
        event_id: "sm-#{sid}"
      )
    )
  end

  defp kuriere!(sid, cid, block_id, quell, seq) do
    Materializer.apply_event(
      event(
        "LueckenKurationSet",
        %{
          "session_id" => sid,
          "campaign_id" => cid,
          "block_id" => block_id,
          "status" => "bestaetigt",
          "bestaetigter_text" => "von Hand bestätigt",
          "quell_utterance_ids" => quell,
          "set_by" => @member
        },
        seq,
        event_id: "lk-#{block_id}"
      )
    )
  end

  defp view(smoothed, sid), do: Enum.find(smoothed, &(&1["session_id"] == sid))
  defp bloecke(smoothed, sid), do: view(smoothed, sid)["blocks"]

  # ── 1. Rollback-Sicherheit ────────────────────────────────────────────────

  describe "ohne Flag" do
    test "jeder Block trägt exakt den Feldsatz von vor #1152", ctx do
      alle = Luecken.text_keys() ++ Luecken.skelett_keys()

      for b <- bloecke(Repo.smoothed_for_campaign(@cid), ctx.s1) do
        assert Enum.sort(Map.keys(b)) == Enum.sort(alle)
      end
    end

    test "auch der erste Block einer langen Session trägt seinen Text", ctx do
      [erster | _] = bloecke(Repo.smoothed_for_campaign(@cid), ctx.s1)

      assert erster["text"] == "Block 1 geglättet"
      assert erster["text_smoothed"] == "Block 1 geglättet"
      assert erster["roh_text"] == "Utterance 1 in #{ctx.s1}"
    end

    test "fenster: false ist Byte für Byte dasselbe wie gar keine Option" do
      ohne = :erlang.term_to_binary(Repo.smoothed_for_campaign(@cid))
      aus = :erlang.term_to_binary(Repo.smoothed_for_campaign(@cid, fenster: false))

      assert ohne == aus
    end

    test "der Session-Kopf bleibt unverändert", ctx do
      sm = view(Repo.smoothed_for_campaign(@cid), ctx.s1)

      assert Enum.sort(Map.keys(sm)) ==
               Enum.sort(~w(session_id session_number rules_version merge_gap_seconds
                            ooc_verworfen_count praesenz_ping_verworfen_count verwaist blocks))

      assert sm["rules_version"] == 7
      assert sm["merge_gap_seconds"] == 8
    end
  end

  # ── 2. Skelett ────────────────────────────────────────────────────────────

  describe "mit Fenster — das Skelett bleibt vollständig" do
    test "kein Block fehlt", ctx do
      sm = Repo.smoothed_for_campaign(@cid, fenster: true)

      assert length(bloecke(sm, ctx.s1)) == @gross
      assert length(bloecke(sm, ctx.s2)) == @klein
    end

    test "Blöcke außerhalb des Fensters tragen NUR das Skelett", ctx do
      [erster | _] = bloecke(Repo.smoothed_for_campaign(@cid, fenster: true), ctx.s1)

      assert Enum.sort(Map.keys(erster)) == Enum.sort(Luecken.skelett_keys())
      refute Map.has_key?(erster, "text")
      refute Map.has_key?(erster, "roh_text")
    end

    test "Blöcke im Fenster tragen den vollen Satz", ctx do
      letzter = List.last(bloecke(Repo.smoothed_for_campaign(@cid, fenster: true), ctx.s1))

      assert Enum.sort(Map.keys(letzter)) ==
               Enum.sort(Luecken.text_keys() ++ Luecken.skelett_keys())

      assert letzter["text"] == "Block #{@gross} geglättet"
    end

    test "quell_utterance_ids überleben außerhalb des Fensters — sonst bricht die Verweis-Karte still ab (#1094)",
         ctx do
      for b <- bloecke(Repo.smoothed_for_campaign(@cid, fenster: true), ctx.s1) do
        assert b["quell_utterance_ids"] != []
      end
    end

    test "status überlebt außerhalb des Fensters — sonst zählt der Hub falsch", ctx do
      # Block 5 hat eine Lücke und liegt weit VOR dem Fenster (Fenster ab 50).
      kuriere!(ctx.s1, @cid, "#{ctx.s1}-b5", ["#{ctx.s1}-u5"], 30_000)

      b5 =
        Repo.smoothed_for_campaign(@cid, fenster: true)
        |> bloecke(ctx.s1)
        |> Enum.find(&(&1["block_id"] == "#{ctx.s1}-b5"))

      assert b5["status"] == "bestaetigt"
      assert b5["hat_luecke"] == true
      refute Map.has_key?(b5, "text")
    end

    test "der Kuratier-Zähler des Hubs stimmt trotz Fenster", ctx do
      gefenstert = bloecke(Repo.smoothed_for_campaign(@cid, fenster: true), ctx.s1)
      voll = bloecke(Repo.smoothed_for_campaign(@cid), ctx.s1)

      zaehle = &Enum.count(&1, fn b -> b["hat_luecke"] and is_nil(b["status"]) end)

      assert zaehle.(gefenstert) == zaehle.(voll)
      assert zaehle.(gefenstert) == div(@gross, 5)
    end
  end

  # ── 3. Budget ─────────────────────────────────────────────────────────────

  describe "Budget über die Sessions" do
    test "die jüngste Session bekommt den vollen Schwanz", ctx do
      betextet =
        Repo.smoothed_for_campaign(@cid, fenster: true)
        |> bloecke(ctx.s1)
        |> Enum.count(&Map.has_key?(&1, "text"))

      assert betextet == @tail
    end

    test "eine Session kleiner als der Schwanz bleibt vollständig betextet", ctx do
      betextet =
        Repo.smoothed_for_campaign(@cid, fenster: true)
        |> bloecke(ctx.s2)
        |> Enum.count(&Map.has_key?(&1, "text"))

      assert betextet == @klein
    end

    test "ist das Budget verbraucht, behält jede Session einen Rest" do
      cid = "glatt-budget-camp"

      build_campaign(
        campaign_id: cid,
        name: "Budget",
        owner_did: @owner,
        sessions: [200, 200, 200, 200],
        base_seq: 60_000,
        apply: true
      )

      for n <- 1..4, do: smooth!("#{cid}-s#{n}", cid, 200, 70_000 + n * 100)

      betextet =
        cid
        |> Repo.smoothed_for_campaign(fenster: true)
        |> Enum.sort_by(& &1["session_number"])
        |> Enum.map(fn sm -> Enum.count(sm["blocks"], &Map.has_key?(&1, "text")) end)

      # Budget 600 = 3 × 200, von der jüngsten abwärts; die älteste fällt auf
      # den Mindestrest statt auf null.
      assert betextet == [10, 200, 200, 200]
      assert Enum.all?(betextet, &(&1 > 0))
    end
  end

  # ── 4. Nachladen ──────────────────────────────────────────────────────────

  describe "Nachladen per ids — der Prädikat-Fall" do
    test "liefert verstreute Blöcke, die kein Bereich zusammenfasst", ctx do
      ids = ["#{ctx.s1}-b1", "#{ctx.s1}-b120", "#{ctx.s2}-b3"]
      texte = Repo.smoothed_texts_by_ids(@cid, ids)

      assert Map.keys(texte) |> Enum.sort() == Enum.sort(ids)
      assert texte["#{ctx.s1}-b1"]["text"] == "Block 1 geglättet"
      assert texte["#{ctx.s1}-b120"]["roh_text"] == "Utterance 120 in #{ctx.s1}"
    end

    test "die Felder sind identisch zur Voll-Antwort — sonst driften die Pfade unsichtbar auseinander",
         ctx do
      voll =
        Repo.smoothed_for_campaign(@cid)
        |> bloecke(ctx.s1)
        |> Enum.find(&(&1["block_id"] == "#{ctx.s1}-b7"))

      nach = Repo.smoothed_texts_by_ids(@cid, ["#{ctx.s1}-b7"])["#{ctx.s1}-b7"]

      assert nach == Map.take(voll, Luecken.text_keys())
    end

    test "unbekannte IDs ergeben eine leere Antwort, keinen Fehler" do
      assert Repo.smoothed_texts_by_ids(@cid, ["gibt-es-nicht"]) == %{}
      assert Repo.smoothed_texts_by_ids(@cid, []) == %{}
    end

    test "IDs einer fremden Kampagne treffen nicht", ctx do
      assert Repo.smoothed_texts_by_ids(@other, ["#{ctx.s1}-b1"]) == %{}
    end
  end

  describe "Nachladen per slice — der Bereichs-Fall" do
    test "schneidet absolut und meldet die Gesamtzahl", ctx do
      assert {texte, total} = Repo.smoothed_texts_slice(@cid, ctx.s1, 10, 3)

      assert total == @gross
      assert Map.keys(texte) |> Enum.sort() == ["#{ctx.s1}-b11", "#{ctx.s1}-b12", "#{ctx.s1}-b13"]
    end

    test "über das Ende hinaus ist kein Fehler, nur kürzer", ctx do
      assert {texte, _} = Repo.smoothed_texts_slice(@cid, ctx.s1, @gross - 2, 50)
      assert map_size(texte) == 2
    end

    test "nil für eine Session aus einer anderen Kampagne", ctx do
      assert Repo.smoothed_texts_slice(@cid, ctx.other_s1, 0, 5) == nil
    end

    test "nil für eine unbekannte Session" do
      assert Repo.smoothed_texts_slice(@cid, "gibt-es-nicht", 0, 5) == nil
    end

    test "eine Session ohne Glättung ist leer, nicht unbekannt" do
      cid = "glatt-ohne-glaettung"

      build_campaign(
        campaign_id: cid,
        owner_did: @owner,
        sessions: [2],
        base_seq: 80_000,
        apply: true
      )

      assert Repo.smoothed_texts_slice(cid, "#{cid}-s1", 0, 5) == {%{}, 0}
    end
  end

  # ── 5. Verhandlung am Scope ───────────────────────────────────────────────

  describe "campaign_luecken-Scope" do
    defp scope(kind, extra \\ %{}) do
      Repo.snapshot(
        Map.merge(%{"kind" => kind, "id" => @cid, "viewer_discord_id" => @member}, extra)
      )
    end

    test "ohne Flag unverändert" do
      assert scope("campaign_luecken")["smoothed"] == Repo.smoothed_for_campaign(@cid)
    end

    test "mit Flag gefenstert", ctx do
      sm = scope("campaign_luecken", %{"glatt" => "fenster"})["smoothed"]

      assert length(bloecke(sm, ctx.s1)) == @gross
      refute Map.has_key?(hd(bloecke(sm, ctx.s1)), "text")
    end

    test "ein unbekannter Flag-Wert liefert die Voll-Antwort statt zu raten" do
      assert scope("campaign_luecken", %{"glatt" => "kaputt"})["smoothed"] ==
               Repo.smoothed_for_campaign(@cid)
    end

    test "Nicht-Member bekommt forbidden — mit und ohne Flag" do
      for extra <- [%{}, %{"glatt" => "fenster"}] do
        assert Repo.snapshot(
                 Map.merge(
                   %{
                     "kind" => "campaign_luecken",
                     "id" => @cid,
                     "viewer_discord_id" => @stranger
                   },
                   extra
                 )
               ) == %{"forbidden" => true}
      end
    end
  end

  describe "campaign_luecken_slice-Scope" do
    test "ids-Modus", ctx do
      res = scope("campaign_luecken_slice", %{"block_ids" => ["#{ctx.s1}-b2"]})

      assert res["mode"] == "ids"
      assert res["texte"]["#{ctx.s1}-b2"]["text"] == "Block 2 geglättet"
    end

    test "slice-Modus liefert Startindex und Gesamtzahl", ctx do
      res =
        scope("campaign_luecken_slice", %{"session_id" => ctx.s1, "from" => 5, "count" => 2})

      assert res["mode"] == "slice"
      assert res["from"] == 5
      assert res["total"] == @gross
      assert map_size(res["texte"]) == 2
    end

    test "kaputte Indizes werden geklemmt statt zu crashen", ctx do
      res =
        scope("campaign_luecken_slice", %{
          "session_id" => ctx.s1,
          "from" => -5,
          "count" => "viele"
        })

      assert res["from"] == 0
      assert res["texte"] == %{}
    end

    test "fremde Session ergibt unknown_session statt fremder Daten", ctx do
      assert scope("campaign_luecken_slice", %{"session_id" => ctx.other_s1})["error"] ==
               "unknown_session"
    end

    test "ohne beides: bad_request" do
      assert scope("campaign_luecken_slice")["error"] == "bad_request"
    end

    test "Nicht-Member bekommt forbidden" do
      assert Repo.snapshot(%{
               "kind" => "campaign_luecken_slice",
               "id" => @cid,
               "viewer_discord_id" => @stranger,
               "block_ids" => []
             }) == %{"forbidden" => true}
    end
  end

  # ── 6. Wächter über die Feld-Aufteilung ───────────────────────────────────

  describe "die Aufteilung selbst" do
    test "Skelett und Texte überschneiden sich nicht" do
      assert MapSet.disjoint?(
               MapSet.new(Luecken.text_keys()),
               MapSet.new(Luecken.skelett_keys())
             )
    end

    test "zusammen ergeben sie genau den vollen Block — kein Feld fällt zwischen die Listen",
         ctx do
      voll = hd(bloecke(Repo.smoothed_for_campaign(@cid), ctx.s1))

      assert Enum.sort(Map.keys(voll)) ==
               Enum.sort(Luecken.text_keys() ++ Luecken.skelett_keys())
    end
  end
end
