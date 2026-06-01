defmodule Worker.RepoListSessionSummariesTest do
  @moduledoc """
  Issue #24: Resümee-Spalte muss nach Session-Nummer aufsteigend sortiert
  sein (Session 1 oben, Session N unten) — NICHT nach `generated_at`
  (wann die LLM-Pipeline den Text erzeugt hat).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-listsum-test"

  setup do
    clear_all_tables!()

    Builder.write!(Builder.campaign(@cid, name: "Test Campaign"))

    # 3 Sessions in „falscher" Reihenfolge anlegen — number 3, 1, 2 —
    # damit der Test wirklich Number-Sortierung prüft und nicht zufällig
    # die Insert-Reihenfolge.
    Builder.write_many!([
      Builder.session("sess-c", @cid, number: 3, name: "Akt III", status: :completed),
      Builder.session("sess-a", @cid, number: 1, name: "Akt I", status: :completed),
      Builder.session("sess-b", @cid, number: 2, name: "Akt II", status: :completed)
    ])

    # Resümees in noch wieder anderer Reihenfolge anlegen, mit
    # generated_at-Werten die die alte Sortierung „neueste zuerst"
    # genau umkehren würden zur richtigen Reihenfolge.
    now = DateTime.utc_now()

    :mnesia.transaction(fn ->
      Enum.each(
        [
          {"sess-a", 0, "Resümee Akt I (zuerst erzeugt)"},
          {"sess-c", 100, "Resümee Akt III (zuletzt erzeugt)"},
          {"sess-b", 50, "Resümee Akt II (mittendrin erzeugt)"}
        ],
        fn {sid, ts_offset, content} ->
          :mnesia.write({
            S.session_summaries(),
            sid,
            @cid,
            content,
            DateTime.add(now, ts_offset, :second),
            :llm,
            # Issue #114: source_refs-Spalte (7. Feld) — der stale Test schrieb
            # noch das Pre-#114-6-Tupel → Mnesia-Arity-Abbruch → leere Liste.
            []
          })
        end
      )
    end)

    :ok
  end

  test "sortiert nach session.number aufsteigend (Issue #24)" do
    result = Repo.list_session_summaries(@cid)

    assert Enum.map(result, & &1.session_id) == ["sess-a", "sess-b", "sess-c"]
  end

  test "Resümee ohne zugehörige Session landet ans Ende statt zu crashen" do
    :mnesia.transaction(fn ->
      :mnesia.write({
        S.session_summaries(),
        "sess-orphan",
        @cid,
        "Resümee ohne Session",
        DateTime.utc_now(),
        :llm,
        []
      })
    end)

    result = Repo.list_session_summaries(@cid)

    assert List.last(result).session_id == "sess-orphan"
    assert length(result) == 4
  end
end
