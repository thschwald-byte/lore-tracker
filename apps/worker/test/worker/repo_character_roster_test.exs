defmodule Worker.RepoCharacterRosterTest do
  @moduledoc """
  Issue #976 (Epic #911 Slice 3): `Repo.character_roster_for/1` — PC- +
  NPC-Roster für das Cast-Enum der Extraktion. Gepinnt: PC-Union über
  `character_names_for/1`, NPC-Häufigkeits-Schwelle (>=2 verschiedene
  Sessions, nur verifizierte Fakten), Mehrheits-Oberflächenform, leeres
  Roster bei frischer Kampagne.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-cast-roster-976"
  @member "did-cast-roster-976"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    build_campaign(campaign_id: @cid, members: [@member], sessions: [1, 1, 1], apply: true)
    :ok
  end

  defp set_alias!(character_name, seq) do
    Materializer.apply_event(
      event(
        "CampaignAliasSet",
        %{"campaign_id" => @cid, "discord_id" => @member, "character_name" => character_name},
        seq,
        event_id: "cas-cr-#{seq}"
      )
    )
  end

  defp fact(id, entity_id, alias_name, opts \\ []) do
    %{
      "id" => id,
      "claim" => "Fakt #{id}",
      "entity_id" => entity_id,
      "character_alias" => alias_name,
      "verified?" => Keyword.get(opts, :verified?, true)
    }
  end

  defp seed_facts!(session_n, facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => "#{@cid}-s#{session_n}", "campaign_id" => @cid, "facts" => facts},
        seq,
        event_id: "sfe-cr-#{session_n}-#{seq}"
      )
    )
  end

  test "frische Kampagne ohne Sessions -> leeres Roster" do
    assert Repo.character_roster_for(@cid) == []
  end

  test "PC-Union: character_names_for/1 fließt ein" do
    set_alias!("Tharion der Entdecker", 100)
    assert Repo.character_roster_for(@cid) == ["Tharion der Entdecker"]
  end

  test "NPC unter der Schwelle (nur 1 Session) bleibt draußen" do
    seed_facts!(1, [fact("f1", "romeo", "Romeo")], 100)
    assert Repo.character_roster_for(@cid) == []
  end

  test "NPC ab der Schwelle (2 verschiedene Sessions) kommt rein" do
    seed_facts!(1, [fact("f1", "romeo", "Romeo")], 100)
    seed_facts!(2, [fact("f2", "romeo", "Romeo")], 101)
    assert Repo.character_roster_for(@cid) == ["Romeo"]
  end

  test "dieselbe Session mehrfach zählt nicht als zwei Sessions" do
    seed_facts!(1, [fact("f1", "romeo", "Romeo"), fact("f2", "romeo", "Romeo")], 100)
    assert Repo.character_roster_for(@cid) == []
  end

  test "unverifizierte Fakten zählen nicht zur Häufigkeit" do
    seed_facts!(1, [fact("f1", "romeo", "Romeo", verified?: false)], 100)
    seed_facts!(2, [fact("f2", "romeo", "Romeo", verified?: false)], 101)
    assert Repo.character_roster_for(@cid) == []
  end

  test "kanonische Anzeigeform = häufigste Oberflächenform (Mehrheitsentscheid)" do
    seed_facts!(
      1,
      [fact("f1", "romeo", "Romeo"), fact("f2", "romeo", "Romeo Montague")],
      100
    )

    seed_facts!(2, [fact("f3", "romeo", "Romeo")], 101)

    assert Repo.character_roster_for(@cid) == ["Romeo"]
  end

  test "PC + NPC zusammen, keine Duplikate" do
    set_alias!("Romeo", 100)
    seed_facts!(1, [fact("f1", "romeo", "Romeo")], 101)
    seed_facts!(2, [fact("f2", "romeo", "Romeo")], 102)

    assert Repo.character_roster_for(@cid) == ["Romeo"]
  end

  test "strang-lose/leere entity_id fliegt raus" do
    seed_facts!(1, [fact("f1", "", "")], 100)
    seed_facts!(2, [fact("f2", "", "")], 101)

    assert Repo.character_roster_for(@cid) == []
  end
end
