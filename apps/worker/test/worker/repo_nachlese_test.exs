defmodule Worker.RepoNachleseTest do
  @moduledoc """
  Issue #907 (Epic #900 S4): der Nachlese-Reader + der campaign_nachlese-
  Snapshot-Scope. Gepinnt: Recap-Pick (letzte Session MIT Resümee, leer-Fall),
  Bögen-Gruppierung offen/geschlossen (inkl. Legacy-:aufgelöst für arc-lose
  Stränge) + aktiv-zuerst-Sortierung, Themen ohne Rauschen, Who's-who
  (pc?-Heuristik, kanonisierte Stränge, letzte Erwähnung, PC-zuerst-Sort),
  Member-Gate + Wire-Encodebarkeit.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-nachlese-907"
  @member "did-spieler-907"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, members: [@member], sessions: [1, 1, 1, 1, 1], apply: true)
    :ok
  end

  defp fact(id, thread, opts \\ []) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "thread" => thread,
      "character_alias" => Keyword.get(opts, :alias, ""),
      "entity_id" => Keyword.get(opts, :entity, ""),
      "verified?" => Keyword.get(opts, :verified?, true),
      "fact_type" => "ereignis"
    }
  end

  defp seed_facts!(session_n, facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{session_n}", "campaign_id" => @cid, "facts" => facts},
        seq,
        event_id: "sfe-na-#{session_n}-#{seq}"
      )
    )
  end

  defp seed_summary!(session_n, md, seq) do
    Materializer.apply_event(
      event(
        "SessionSummaryGenerated",
        %{
          "session_id" => "#{@cid}-s#{session_n}",
          "campaign_id" => @cid,
          "content_md" => md,
          "source" => "llm",
          "flagged_claims" => []
        },
        seq,
        event_id: "ssg-na-#{seq}"
      )
    )
  end

  defp seed_registry!(kinds, cluster_map, seq) do
    Materializer.apply_event(
      event(
        "ThreadRegistryComputed",
        %{"campaign_id" => @cid, "cluster_map" => cluster_map, "kinds" => kinds},
        seq,
        event_id: "trc-na-#{seq}"
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
          "leitfrage_draft" => "Frage zu #{arc_id}?",
          "seed_raw_labels" => seeds
        },
        seq,
        event_id: "ac-na-#{seq}"
      )
    )
  end

  defp progression!(arc_id, session_n, md, seq, flagged \\ []) do
    Materializer.apply_event(
      event(
        "ArcProgressionGenerated",
        %{
          "campaign_id" => @cid,
          "arc_id" => arc_id,
          "session_id" => "#{@cid}-s#{session_n}",
          "session_number" => session_n,
          "content_md" => md,
          "flagged_claims" => flagged,
          "render_backend" => "local",
          "render_model" => "qwen2.5:7b"
        },
        seq,
        event_id: "apg-na-#{seq}"
      )
    )
  end

  defp nachlese, do: Repo.campaign_nachlese(@cid)

  test "recap: letzte Session MIT Resümee gewinnt; ohne Resümees nil" do
    assert nachlese().recap == nil

    seed_summary!(1, "Erstes Resümee.", 100)
    seed_summary!(3, "Drittes Resümee.", 101)

    r = nachlese().recap
    assert r.content_md == "Drittes Resümee."
    assert r.session_number == 3
  end

  test "boegen: offen/geschlossen-Split, aktiv zuerst, Titel = Leitfrage-Fallback" do
    # aktiv (S5-Fakt), ruhend (nur S1), geschlossen (Arc-Akt), legacy-aufgelöst (arc-los).
    seed_facts!(5, [fact("f1", "der aktive Bogen")], 100)

    seed_facts!(
      1,
      [
        fact("f2", "der ruhende Bogen"),
        fact("f3", "der zu Bogen"),
        fact("f4", "der legacy Bogen")
      ],
      101
    )

    arc!("arc_aktiv", ["der aktive bogen"], 102)
    arc!("arc_zu", ["der zu bogen"], 103)

    Materializer.apply_event(
      event(
        "ArcClosed",
        %{
          "arc_id" => "arc_zu",
          "campaign_id" => @cid,
          "grund" => "geloest",
          "wasserlinie_session" => 5,
          "set_by" => "d"
        },
        104,
        event_id: "acl-na-1"
      )
    )

    Materializer.apply_event(
      event(
        "ThreadOverrideSet",
        %{
          "campaign_id" => @cid,
          "canonical" => "der legacy Bogen",
          "action" => "resolve",
          "set_by" => "d"
        },
        105,
        event_id: "tos-na-1"
      )
    )

    b = nachlese().boegen

    # Offen: aktiv (S5) VOR ruhend; Titel aus der Leitfrage bzw. canonical.
    assert [aktiv, ruhend] = b.offen
    assert aktiv.titel == "Frage zu arc_aktiv?"
    refute aktiv.ruht?
    assert ruhend.canonical == "der ruhende Bogen"
    assert ruhend.titel == "der ruhende Bogen"
    assert ruhend.ruht?

    assert Enum.map(b.geschlossen, & &1.canonical) |> Enum.sort() ==
             ["der legacy Bogen", "der zu Bogen"]

    assert Enum.find(b.geschlossen, &(&1.canonical == "der zu Bogen")).arc_grund == "geloest"
  end

  # Issue #838: pro Bogen ALLE Prosa-Progressions-Einträge, chronologisch —
  # Toms expliziter Wunsch (Design K), nicht nur ein stets überschriebener
  # "aktueller Stand".
  test "boegen: entries = volle Prosa-Progressions-Chronik chronologisch nach Sitzung, unabhängig von der Schreib-Reihenfolge" do
    seed_facts!(1, [fact("f1", "der aktive Bogen")], 100)
    arc!("arc_aktiv", ["der aktive bogen"], 101)

    # Absichtlich in umgekehrter Sitzungs-Reihenfolge geschrieben.
    progression!("arc_aktiv", 3, "Dritter Stand.", 102)
    progression!("arc_aktiv", 1, "Erster Stand.", 103, ["unbelegte Aussage"])

    assert [aktiv] = nachlese().boegen.offen
    assert Enum.map(aktiv.entries, & &1.session_number) == [1, 3]
    assert Enum.map(aktiv.entries, & &1.content_md) == ["Erster Stand.", "Dritter Stand."]
    assert Enum.at(aktiv.entries, 0).flagged_claims == ["unbelegte Aussage"]
  end

  test "boegen: ohne Progressions-Eintrag bleibt entries leer (Template-Fallback auf die Fakt(en)-Zeile)" do
    seed_facts!(1, [fact("f1", "der Bogen ohne Eintrag")], 100)
    arc!("arc_ohne", ["der bogen ohne eintrag"], 101)

    assert [%{entries: []}] = nachlese().boegen.offen
  end

  test "themen: context ja, rauschen nie" do
    seed_facts!(1, [fact("f1", "die Welt"), fact("f2", "das Protokoll")], 100)
    seed_registry!(%{"die welt" => "context", "das protokoll" => "rauschen"}, %{}, 101)

    t = nachlese()
    assert [%{titel: "die Welt"}] = t.themen
    refute Enum.any?(t.boegen.offen, &(&1.canonical == "das Protokoll"))
  end

  test "who: pc?-Heuristik, kanonisierte Stränge, letzte Erwähnung, PCs zuerst" do
    Materializer.apply_event(
      event(
        "CampaignAliasSet",
        %{"campaign_id" => @cid, "discord_id" => @member, "character_name" => "Skrapnik"},
        100,
        event_id: "cas-na-1"
      )
    )

    seed_facts!(
      1,
      [
        fact("f1", "der Auftrag", alias: "Romeo", entity: "romeo"),
        fact("f2", "der Auftrag", alias: "Romeo", entity: "romeo")
      ],
      101
    )

    seed_facts!(5, [fact("f3", "der Auftrags-Coup", alias: "Skrapnik", entity: "skrapnik")], 102)
    seed_registry!(%{}, %{"der auftrags-coup" => "der Auftrag"}, 103)

    who = nachlese().who

    # PC (Skrapnik, 1 Fakt) sortiert VOR NPC (Romeo, 2 Fakten).
    assert [pc, npc] = who
    assert pc.alias == "Skrapnik"
    assert pc.pc?
    assert pc.last_session == 5
    # Roh-Label über die Cluster-Map kanonisiert.
    assert pc.threads == ["der Auftrag"]
    assert npc.alias == "Romeo"
    refute npc.pc?
    assert npc.fact_count == 2
  end

  test "who: Fakten ohne Figur fallen raus; unverifizierte zählen nicht" do
    seed_facts!(
      1,
      [fact("f1", "x"), fact("f2", "x", alias: "Geist", verified?: false)],
      100
    )

    assert nachlese().who == []
  end

  test "campaign_nachlese-Scope: member-gated, Wire-Keys + Jason-encodebar" do
    seed_summary!(1, "R.", 100)
    seed_facts!(1, [fact("f1", "der Auftrag", alias: "Romeo")], 101)

    snap =
      Repo.snapshot(%{
        "kind" => "campaign_nachlese",
        "id" => @cid,
        "viewer_discord_id" => @member
      })

    assert %{"campaign" => %{"name" => _}, "recap" => %{"content_md" => "R."}} = snap
    assert is_list(snap["boegen_offen"])
    assert is_list(snap["who"])
    assert {:ok, _} = Jason.encode(snap)

    assert %{"forbidden" => true} =
             Repo.snapshot(%{
               "kind" => "campaign_nachlese",
               "id" => @cid,
               "viewer_discord_id" => "did-fremd"
             })
  end
end
