defmodule Worker.SessionFactsTest do
  @moduledoc """
  Issue #651 (Wahrheitsbild, Phase A): das Fakt-Datenmodell — `SessionFactsExtracted`
  materialisiert in `worker_session_facts` (facts_json), `Worker.Repo.get_session_facts/1`
  + `list_campaign_facts/1` lesen es zurück. Additiv, noch nicht pipeline-verdrahtet.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-facts-651"
  @s1 "sess-651-1"
  @s2 "sess-651-2"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp fact(id, claim, alias_name, opts \\ []) do
    %{
      "id" => id,
      "claim" => claim,
      "entity_id" => opts[:entity_id] || id,
      "character_alias" => alias_name,
      "in_game_date" => opts[:in_game_date],
      "source_refs" => opts[:source_refs] || [],
      "verified?" => Keyword.get(opts, :verified?, false)
    }
  end

  defp extract(session_id, facts, seq) do
    Materializer.apply_event(
      event(
        "SessionFactsExtracted",
        %{"session_id" => session_id, "campaign_id" => @cid, "facts" => facts},
        seq
      )
    )
  end

  test "SessionFactsExtracted → get_session_facts liefert die dekodierten Fakten" do
    facts = [
      fact("f1", "Der König beauftragt Holmes.", "König", source_refs: ["u3"], verified?: true),
      fact("f2", "Irene flieht ins Ausland.", "Irene Adler", in_game_date: "Tag 2")
    ]

    assert {:applied, 1} = extract(@s1, facts, 1)

    got = Repo.get_session_facts(@s1)
    assert got.session_id == @s1
    assert got.campaign_id == @cid
    assert length(got.facts) == 2

    [f1, f2] = got.facts
    assert f1["claim"] == "Der König beauftragt Holmes."
    assert f1["verified?"] == true
    assert f1["source_refs"] == ["u3"]
    assert f2["character_alias"] == "Irene Adler"
    assert f2["in_game_date"] == "Tag 2"
  end

  test "Re-Extraktion überschreibt (Set-Semantik pro session_id)" do
    extract(@s1, [fact("f1", "alt", "X")], 1)
    extract(@s1, [fact("f2", "neu", "Y"), fact("f3", "neu2", "Z")], 2)

    got = Repo.get_session_facts(@s1)
    assert length(got.facts) == 2
    assert Enum.map(got.facts, & &1["claim"]) == ["neu", "neu2"]
  end

  test "get_session_facts/1 für unbekannte Session → nil" do
    assert Repo.get_session_facts("ghost") == nil
  end

  test "leere Fakt-Liste → leere Liste (kein Crash)" do
    extract(@s1, [], 1)
    assert Repo.get_session_facts(@s1).facts == []
  end

  describe "list_campaign_facts/1" do
    setup do
      [
        event("SessionScheduled", %{"campaign_id" => @cid, "id" => @s1, "number" => 1, "name" => ""}, 1),
        event("SessionScheduled", %{"campaign_id" => @cid, "id" => @s2, "number" => 2, "name" => ""}, 2)
      ]
      |> Enum.each(&Materializer.apply_event/1)

      :ok
    end

    test "flach + nach session.number geordnet + je Fakt mit session_id" do
      # S2 zuerst extrahiert, S1 danach — Reihenfolge muss trotzdem S1, S2 sein.
      extract(@s2, [fact("b1", "S2-Fakt", "Y")], 10)
      extract(@s1, [fact("a1", "S1-Fakt-1", "X"), fact("a2", "S1-Fakt-2", "X")], 11)

      all = Repo.list_campaign_facts(@cid)

      assert Enum.map(all, & &1["claim"]) == ["S1-Fakt-1", "S1-Fakt-2", "S2-Fakt"]
      assert Enum.map(all, & &1["session_id"]) == [@s1, @s1, @s2]
    end

    test "leer wenn keine Extraktion lief" do
      assert Repo.list_campaign_facts(@cid) == []
    end
  end
end
