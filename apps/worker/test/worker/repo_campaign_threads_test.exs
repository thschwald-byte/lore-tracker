defmodule Worker.RepoCampaignThreadsTest do
  @moduledoc """
  Issue #833 (Epic #829 Slice D1): der deterministische Handlungsbogen-Reader
  `Worker.Repo.campaign_threads/1`. Gruppiert verifizierte Fakten über die
  ThreadRegistry-Cluster-Map (#832) zu kanonischen Strängen, leitet Status ab
  (offen/ruhend) + das resolution_suggested?-Flag. Rein lesend, kein LLM.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo, Settings}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-threads-833"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    # 5 Sessions (je 1 Utterance) → Nummern 1..5.
    build_campaign(campaign_id: @cid, sessions: [1, 1, 1, 1, 1], apply: true)
    :ok
  end

  defp fact(id, thread, opts \\ []) do
    %{
      "id" => id,
      "claim" => Keyword.get(opts, :claim, "Fakt #{id}"),
      "thread" => thread,
      "character_alias" => Keyword.get(opts, :alias, ""),
      "fact_type" => Keyword.get(opts, :fact_type, "ereignis"),
      "verified?" => Keyword.get(opts, :verified?, true),
      "review_dismissed" => Keyword.get(opts, :dismissed, false)
    }
  end

  # event_id gesetzt → Apply über den event_id-Pfad, unabhängig vom Seq-Cursor
  # (build_campaign hat die niedrigen Seqs schon verbraucht → sonst Dedup-Skip).
  defp seed(session_n, facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{session_n}", "campaign_id" => @cid, "facts" => facts},
        seq,
        event_id: "sfe-#{@cid}-s#{session_n}-#{seq}"
      )
    )
  end

  defp cluster(map, seq) do
    Materializer.apply_event(
      event("ThreadRegistryComputed", %{"campaign_id" => @cid, "cluster_map" => map}, seq,
        event_id: "trc-#{seq}"
      )
    )
  end

  defp find(threads, canonical), do: Enum.find(threads, &(&1.canonical == canonical))

  test "gruppiert über die Cluster-Map, leitet Status + resolution_suggested? ab" do
    # Cluster-Map: das Fragment „der Skandal-Coup" gehört zu „der Skandal".
    cluster(%{"der skandal-coup" => "der Skandal"}, 1)

    seed(
      1,
      [
        fact("f1", "der Skandal", alias: "König"),
        fact("f2", "die Heirat", alias: "Norton"),
        fact("f3", "der Skandal", verified?: false)
      ],
      2
    )

    # Beide S5-Fakten in EINEM Event — SessionFactsExtracted hat Set-Semantik pro
    # session_id, zwei Events würden sich überschreiben.
    seed(
      5,
      [
        fact("f1", "der Skandal-Coup", alias: "Holmes"),
        fact("f2", "das Geheimnis", alias: "Irene", fact_type: "auflösung")
      ],
      3
    )

    threads = Repo.campaign_threads(@cid)

    # Drei Stränge: der Skandal (offen), das Geheimnis (offen), die Heirat (ruhend).
    assert length(threads) == 3

    skandal = find(threads, "der Skandal")
    # f1(S1) + Fragment(S5) via Cluster-Map zusammengeführt — NICHT der unverified f3.
    assert skandal.fact_count == 2
    assert skandal.sessions_touched == [1, 5]
    assert skandal.opened_in_session == 1
    assert skandal.last_touched_session == 5
    assert skandal.status == :offen
    assert "König" in skandal.entities and "Holmes" in skandal.entities
    refute skandal.resolution_suggested?

    heirat = find(threads, "die Heirat")
    # nur S1 berührt → 4 nachfolgende Sessions ≥ 3 (Default) → ruhend.
    assert heirat.last_touched_session == 1
    assert heirat.status == :ruhend

    geheimnis = find(threads, "das Geheimnis")
    # auflösung setzt NUR das Flag, KEIN Auto-Übergang — Status bleibt offen (S5).
    assert geheimnis.status == :offen
    assert geheimnis.resolution_suggested?

    # Sortierung: offen vor ruhend.
    assert List.last(threads).canonical == "die Heirat"
  end

  test "ohne Cluster-Map: Roh-Labels fallen auf sich selbst zurück (fragmentiert-aber-korrekt)" do
    seed(1, [fact("f1", "der Skandal"), fact("f2", "der Skandal-Coup")], 2)

    threads = Repo.campaign_threads(@cid)
    canons = threads |> Enum.map(& &1.canonical) |> Enum.sort()
    # Kein Clustering → zwei getrennte Stränge (das ist Slice C's Job, hier Fallback).
    assert canons == ["der Skandal", "der Skandal-Coup"]
  end

  test "konsumiert nur verified? == true + nicht-dismissed + nicht-leeres thread" do
    seed(
      1,
      [
        fact("f1", "A", verified?: true),
        fact("f2", "B", verified?: false),
        fact("f3", "C", dismissed: true),
        fact("f4", "", verified?: true)
      ],
      2
    )

    canons = Repo.campaign_threads(@cid) |> Enum.map(& &1.canonical)
    assert canons == ["A"]
  end

  test "thread_dormant_after_sessions steuert die Ruhend-Schwelle" do
    # Strang nur in S1; 4 nachfolgende Sessions.
    seed(1, [fact("f1", "alt")], 2)

    assert find(Repo.campaign_threads(@cid), "alt").status == :ruhend

    # Schwelle auf 5 → 4 nachfolgende reichen nicht mehr → offen.
    Settings.put(:thread_dormant_after_sessions, 5)
    assert find(Repo.campaign_threads(@cid), "alt").status == :offen
  end

  test "leere Kampagne → leere Liste" do
    assert Repo.campaign_threads(@cid) == []
  end
end
