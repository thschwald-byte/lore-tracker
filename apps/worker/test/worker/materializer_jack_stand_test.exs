defmodule Worker.MaterializerJackStandTest do
  @moduledoc """
  J4 (#1207): Konvergenz und Cascade für Jacks Stand je Sitzung
  (`worker_jack_staende`). Whole-Snapshot ⇒ Voll-Ersatz: nur der letzte Stand
  zählt, in jeder Reihenfolge.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-jack-1207"
  @sid "sess-jack-1207"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp stand(n),
    do: %{
      "aussagen" => [%{"nummer" => n, "claim" => "Aussage #{n}"}],
      "fortsetzung" => %{"register" => [%{"abschnitt" => "ABLAUF", "schluessel" => "0-9"}]}
    }

  defp stand_ev(n, seq, event_id) do
    event(
      "JackStandAbgelegt",
      %{"session_id" => @sid, "campaign_id" => @cid, "stand" => stand(n)},
      seq,
      event_id: event_id
    )
  end

  defp mit_bloecke(ids, event_id) do
    event(
      "JackStandAbgelegt",
      %{
        "session_id" => @sid,
        "campaign_id" => @cid,
        "stand" => Map.put(stand(1), "bloecke", ids)
      },
      1,
      event_id: event_id
    )
  end

  defp read_row(key) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(S.jack_staende(), key) end)
    rows
  end

  defp nummer do
    case Repo.jack_stand_for_session(@sid) do
      %{stand: %{"aussagen" => [%{"nummer" => n}]}} -> n
      nil -> nil
    end
  end

  test "materialisiert → der Reader liest den Stand zurück" do
    assert {:applied, 1} = Materializer.apply_event(stand_ev(1, 1, "js-ev-1"))

    assert %{stand: %{"aussagen" => [%{"nummer" => 1}], "fortsetzung" => %{"register" => [_]}}} =
             Repo.jack_stand_for_session(@sid)
  end

  test "ohne Stand → nil" do
    assert Repo.jack_stand_for_session(@sid) == nil
  end

  test "ein Payload ohne stand oder ohne IDs wird verworfen statt zu crashen" do
    ev = event("JackStandAbgelegt", %{"session_id" => @sid, "campaign_id" => @cid}, 1)
    assert {:applied, 1} = Materializer.apply_event(ev)
    ev2 = event("JackStandAbgelegt", %{"session_id" => nil, "stand" => stand(1)}, 2)
    assert {:applied, 2} = Materializer.apply_event(ev2)
    assert Repo.jack_stand_for_session(@sid) == nil
  end

  test "LWW: der höhere event_id gewinnt komplett, jede Reihenfolge konvergiert" do
    events = [stand_ev(1, 1, "js-ev-1"), stand_ev(2, 2, "js-ev-2")]
    results = materialize_permutations(events, &nummer/0)
    assert Enum.uniq(results) == [2]
  end

  describe "Worker.Jack.Pipeline.abgelegter_stand/2 (noch N Iterationen)" do
    @kontext_ab [%{id: "b0"}, %{id: "b1"}]

    test "gleiche Blockliste → der Stand" do
      Materializer.apply_event(mit_bloecke(["b0", "b1"], "js-ab-1"))

      assert {:ok, %{"aussagen" => [%{"nummer" => 1}], "bloecke" => ["b0", "b1"]}} =
               Worker.Jack.Pipeline.abgelegter_stand(@sid, @kontext_ab)
    end

    test "geänderte Blockliste → Fehler statt verrutschter Belege" do
      Materializer.apply_event(mit_bloecke(["b0", "bX"], "js-ab-2"))

      assert {:error, {:extraction, {:jack, :blockliste_geaendert}}} =
               Worker.Jack.Pipeline.abgelegter_stand(@sid, @kontext_ab)
    end

    test "Stand ohne Blockliste → Fehler" do
      Materializer.apply_event(stand_ev(1, 1, "js-ab-3"))

      assert {:error, {:extraction, {:jack, :blockliste_unbekannt}}} =
               Worker.Jack.Pipeline.abgelegter_stand(@sid, @kontext_ab)
    end

    test "ohne Stand → Fehler" do
      assert {:error, {:extraction, {:jack, :kein_stand}}} =
               Worker.Jack.Pipeline.abgelegter_stand(@sid, @kontext_ab)
    end
  end

  describe "Cascade" do
    test "SessionDeleted räumt den Stand" do
      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          1
        )
      )

      Materializer.apply_event(stand_ev(1, 2, "js-ev-sd"))
      assert read_row(@sid) != []

      Materializer.apply_event(
        event("SessionDeleted", %{"session_id" => @sid, "campaign_id" => @cid}, 3)
      )

      assert read_row(@sid) == []
    end

    test "CampaignDeleted räumt den Stand kampagnenweit" do
      Materializer.apply_event(event("CampaignCreated", %{"id" => @cid, "name" => "Camp"}, 1))

      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          2
        )
      )

      Materializer.apply_event(stand_ev(1, 3, "js-ev-cd"))
      assert read_row(@sid) != []

      Materializer.apply_event(
        event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 4)
      )

      assert read_row(@sid) == []
    end
  end
end
