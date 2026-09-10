defmodule Worker.Repo.FaktenFensterTest do
  @moduledoc """
  Issue #1204: die Fakten-Spalte bekommt je Session nur ein Fenster, die
  Review-Liste reist im Haupt-Snapshot nur als Zahl — beides nur, wenn der
  Hub danach fragt. Ohne Flag muss jede Antwort byte-identisch zur alten sein,
  sonst bricht ein zurückgerollter Hub still.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Repo.FaktenFenster
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-fakten-fenster"

  setup do
    clear_all_tables!()
    :ok
  end

  defp put_facts(sid, facts) do
    Worker.Schema.Builder.write!(
      {S.session_facts(), sid, @cid, Jason.encode!(facts), DateTime.utc_now(), "ext-#{sid}", nil,
       nil, nil}
    )
  end

  defp fakten(sid, n, attrs \\ %{}) do
    for i <- 1..n do
      Map.merge(
        %{
          "id" => "#{sid}-f#{i}",
          "claim" => "Fakt #{i}",
          "narration_time" => "present",
          "verified?" => true,
          "in_game_date" => nil
        },
        attrs
      )
    end
  end

  defp ids(antwort, sid),
    do: antwort["facts"] |> Enum.filter(&(&1["session_id"] == sid)) |> Enum.map(& &1["id"])

  describe "fakten/2" do
    test "ohne Flag byte-identisch zur Kurations-Liste" do
      put_facts("s-1", fakten("s-1", 120))

      assert FaktenFenster.fakten(@cid, %{}) ==
               %{"facts" => Repo.list_campaign_facts_curation(@cid)}
    end

    test "mit Tail: je Session die letzten n, dazu Gesamtzahl und Start" do
      put_facts("s-1", fakten("s-1", 120))
      put_facts("s-2", fakten("s-2", 10))

      antwort = FaktenFenster.fakten(@cid, %{"fakten_tail" => 50})

      assert ids(antwort, "s-1") == for(i <- 71..120, do: "s-1-f#{i}")
      assert ids(antwort, "s-2") == for(i <- 1..10, do: "s-2-f#{i}")

      assert antwort["fakten_fenster"] == %{
               "s-1" => %{"total" => 120, "from" => 70},
               "s-2" => %{"total" => 10, "from" => 0}
             }
    end

    test "ein geblättertes Fenster gilt nur für seine Session" do
      put_facts("s-1", fakten("s-1", 120))
      put_facts("s-2", fakten("s-2", 80))

      antwort =
        FaktenFenster.fakten(@cid, %{
          "fakten_tail" => 50,
          "fakten_fenster" => %{"s-1" => %{"from" => 20, "count" => 30}}
        })

      assert ids(antwort, "s-1") == for(i <- 21..50, do: "s-1-f#{i}")
      assert antwort["fakten_fenster"]["s-1"] == %{"total" => 120, "from" => 20}
      assert ids(antwort, "s-2") == for(i <- 31..80, do: "s-2-f#{i}")
    end

    test "passt alles ins Fenster, ist die Liste die der Kurations-Liste" do
      put_facts("s-1", fakten("s-1", 30))
      put_facts("s-2", fakten("s-2", 12))

      antwort = FaktenFenster.fakten(@cid, %{"fakten_tail" => 50})
      assert antwort["facts"] == Repo.list_campaign_facts_curation(@cid)
    end

    test "ein kaputter Fenster-Wunsch crasht nicht, sondern bekommt den Tail" do
      put_facts("s-1", fakten("s-1", 120))

      antwort =
        FaktenFenster.fakten(@cid, %{"fakten_tail" => 50, "fakten_fenster" => "kaputt"})

      assert length(ids(antwort, "s-1")) == 50
    end
  end

  describe "schnitt/3" do
    test "Tail, Deckel, Klemmen" do
      assert FaktenFenster.schnitt(nil, 120, 50) == {70, 50}
      assert FaktenFenster.schnitt(nil, 10, 50) == {0, 10}
      assert FaktenFenster.schnitt(nil, 0, 50) == {0, 0}
      # Deckel 200 — auch wenn ein Hub-Fehler mehr verlangt.
      assert FaktenFenster.schnitt(nil, 1000, 999) == {800, 200}
      assert FaktenFenster.schnitt(%{"from" => 20, "count" => 30}, 120, 50) == {20, 30}
      assert FaktenFenster.schnitt(%{"from" => 110, "count" => 30}, 120, 50) == {110, 10}
      assert FaktenFenster.schnitt(%{"from" => -5, "count" => 999}, 1000, 50) == {0, 200}
      assert FaktenFenster.schnitt(%{"from" => 500, "count" => 10}, 120, 50) == {120, 0}
      assert FaktenFenster.schnitt("kaputt", 120, 50) == {70, 50}
    end
  end

  describe "review/4" do
    setup do
      # Flashback ohne Datum und ohne Offset ist unplatzierbar (#746).
      put_facts("s-1", fakten("s-1", 2, %{"narration_time" => "flashback"}))
      :ok
    end

    test "mit Flag nur die Zahl, keine Liste" do
      antwort =
        FaktenFenster.review(%{}, %{"review_facts" => "anzahl"}, @cid, &Function.identity/1)

      assert antwort == %{"review_facts_count" => 2}
    end

    test "ohne Flag die Liste wie bisher, durch serialize" do
      antwort = FaktenFenster.review(%{}, %{}, @cid, &Map.put(&1, "serialisiert", true))

      assert length(antwort["review_facts"]) == 2
      assert Enum.all?(antwort["review_facts"], & &1["serialisiert"])
      refute Map.has_key?(antwort, "review_facts_count")
    end
  end
end
