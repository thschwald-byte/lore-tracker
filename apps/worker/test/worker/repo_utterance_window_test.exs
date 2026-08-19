defmodule Worker.RepoUtteranceWindowTest do
  @moduledoc """
  Issue #1087: der campaign-Snapshot lieferte alle Utterances einer Kampagne an
  jeden Betrachter — real gemessen 5.553 Zeilen = 4,8 MB Heap, bei 381,5 MiB
  Cgroup-Limit auf Prod. Diese Tests nageln das Ladefenster fest: was
  ausgeliefert wird, was daneben an Zählern mitreisen MUSS (ohne die kann der
  Hub nicht weiterblättern), und dass die nachladenden Scopes weder fremde
  Kampagnen noch Nicht-Member bedienen.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo

  @cid "utt-window-camp"
  @other "utt-window-other"
  @owner "did-owner-window"
  @member "did-member-window"
  @stranger "did-stranger-window"

  @big 250
  @small 10
  @tail 200

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)

    build_campaign(
      campaign_id: @cid,
      name: "Fenster-Kampagne",
      owner_did: @owner,
      owner_name: "Owner Window",
      members: [@member],
      sessions: [@big, @small],
      apply: true
    )

    build_campaign(
      campaign_id: @other,
      name: "Fremde Kampagne",
      owner_did: @stranger,
      owner_name: "Stranger",
      sessions: [5],
      base_seq: 10_000,
      apply: true
    )

    {:ok, s1: "#{@cid}-s1", s2: "#{@cid}-s2", other_s1: "#{@other}-s1"}
  end

  describe "campaign_utterance_tail/2" do
    test "liefert nur den Schwanz je Session, aber die volle Gesamtzahl", ctx do
      {utts, counts, froms} = Repo.campaign_utterance_tail(@cid, @tail)

      assert length(utts) == @tail + @small
      assert counts == %{ctx.s1 => @big, ctx.s2 => @small}

      # Startindex des gelieferten Fensters: die grosse Session beginnt erst
      # bei 50, die kleine passt komplett.
      assert froms == %{ctx.s1 => @big - @tail, ctx.s2 => 0}
    end

    test "der Schwanz ist das ENDE der Session, nicht der Anfang", ctx do
      {utts, _counts, _froms} = Repo.campaign_utterance_tail(@cid, @tail)

      s1_ids = utts |> Enum.filter(&(&1.session_id == ctx.s1)) |> Enum.map(& &1.id)

      assert List.last(s1_ids) == "#{ctx.s1}-u#{@big}"
      refute "#{ctx.s1}-u1" in s1_ids
    end

    test "Sessions kleiner als das Fenster bleiben vollständig", ctx do
      {utts, _counts, froms} = Repo.campaign_utterance_tail(@cid, @tail)

      assert froms[ctx.s2] == 0
      assert Enum.count(utts, &(&1.session_id == ctx.s2)) == @small
    end
  end

  describe "utterance_slice/4" do
    test "schneidet absolut, nicht relativ zum geladenen Rest", ctx do
      {utts, total} = Repo.utterance_slice(@cid, ctx.s1, 0, 50)

      assert total == @big
      assert length(utts) == 50
      assert hd(utts).id == "#{ctx.s1}-u1"
      assert List.last(utts).id == "#{ctx.s1}-u50"
    end

    test "über das Ende hinaus ist kein Fehler, nur kürzer", ctx do
      {utts, total} = Repo.utterance_slice(@cid, ctx.s1, @big - 3, 100)

      assert total == @big
      assert length(utts) == 3
    end

    test "nil für eine Session, die zu einer anderen Kampagne gehört", ctx do
      # Die session_id kommt vom Client — ohne diese Prüfung könnte ein Member
      # von Kampagne A das Protokoll von Kampagne B lesen.
      assert Repo.utterance_slice(@cid, ctx.other_s1, 0, 10) == nil
    end

    test "nil für eine unbekannte Session" do
      assert Repo.utterance_slice(@cid, "gibt-es-nicht", 0, 10) == nil
    end
  end

  describe "utterances_by_ids/2" do
    test "liefert die Zeilen samt absoluter Position in ihrer Session", ctx do
      {utts, indices} =
        Repo.utterances_by_ids(@cid, ["#{ctx.s1}-u1", "#{ctx.s1}-u#{@big}", "#{ctx.s2}-u3"])

      assert length(utts) == 3
      assert indices["#{ctx.s1}-u1"] == 0
      assert indices["#{ctx.s1}-u#{@big}"] == @big - 1
      assert indices["#{ctx.s2}-u3"] == 2
    end

    test "IDs fremder Kampagnen fallen weg, ohne den Rest mitzureissen", ctx do
      {utts, indices} = Repo.utterances_by_ids(@cid, ["#{ctx.other_s1}-u1", "#{ctx.s2}-u1"])

      assert Enum.map(utts, & &1.id) == ["#{ctx.s2}-u1"]
      refute Map.has_key?(indices, "#{ctx.other_s1}-u1")
    end

    test "unbekannte IDs ergeben eine leere Antwort, keinen Fehler" do
      assert {[], %{}} = Repo.utterances_by_ids(@cid, ["gibt-es-nicht"])
    end
  end

  describe "campaign-Snapshot" do
    test "liefert das Fenster plus die Zähler zum Weiterblättern", ctx do
      snap = Repo.snapshot(%{"kind" => "campaign", "id" => @cid, "viewer_discord_id" => @owner})

      assert length(snap["utterances"]) == @tail + @small
      assert snap["utterance_counts"] == %{ctx.s1 => @big, ctx.s2 => @small}
      assert snap["utterance_from"] == %{ctx.s1 => @big - @tail, ctx.s2 => 0}
    end
  end

  describe "campaign_utterances-Scope" do
    defp scoped(extra, viewer \\ @owner) do
      Repo.snapshot(
        Map.merge(
          %{"kind" => "campaign_utterances", "id" => @cid, "viewer_discord_id" => viewer},
          extra
        )
      )
    end

    test "slice-Modus liefert Ausschnitt, Startindex und Gesamtzahl", ctx do
      snap = scoped(%{"session_id" => ctx.s1, "from" => 10, "count" => 5})

      assert snap["mode"] == "slice"
      assert snap["from"] == 10
      assert snap["total"] == @big
      assert Enum.map(snap["utterances"], & &1["id"]) == for(i <- 11..15, do: "#{ctx.s1}-u#{i}")
    end

    test "ids-Modus liefert Zeilen und Positionen", ctx do
      snap = scoped(%{"ids" => ["#{ctx.s1}-u7"]})

      assert snap["mode"] == "ids"
      assert Enum.map(snap["utterances"], & &1["id"]) == ["#{ctx.s1}-u7"]
      assert snap["indices"]["#{ctx.s1}-u7"] == 6
    end

    test "Nicht-Member bekommt forbidden — in beiden Modi", ctx do
      assert scoped(%{"session_id" => ctx.s1, "from" => 0, "count" => 5}, @stranger) ==
               %{"forbidden" => true}

      assert scoped(%{"ids" => ["#{ctx.s1}-u1"]}, @stranger) == %{"forbidden" => true}
    end

    test "fremde Session ergibt unknown_session statt fremder Daten", ctx do
      assert scoped(%{"session_id" => ctx.other_s1, "from" => 0, "count" => 5}) ==
               %{"error" => "unknown_session"}
    end

    test "kaputte Indizes werden geklemmt statt zu crashen", ctx do
      snap = scoped(%{"session_id" => ctx.s1, "from" => "nein", "count" => nil})

      assert snap["from"] == 0
      assert snap["utterances"] == []
    end

    test "ohne session_id und ohne ids: bad_request" do
      assert scoped(%{}) == %{"error" => "bad_request"}
    end
  end
end
