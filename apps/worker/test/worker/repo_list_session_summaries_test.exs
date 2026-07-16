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

    # Builder hält die session_summaries-Arity zentral (Issue #462) — kein
    # hartkodiertes Tupel mehr, write_many! raised bei Arity-Drift statt still
    # zu aborten (vgl. #459).
    Builder.write_many!(
      Enum.map(
        [
          {"sess-a", 0, "Resümee Akt I (zuerst erzeugt)"},
          {"sess-c", 100, "Resümee Akt III (zuletzt erzeugt)"},
          {"sess-b", 50, "Resümee Akt II (mittendrin erzeugt)"}
        ],
        fn {sid, ts_offset, content} ->
          Builder.session_summary(sid, @cid,
            content_md: content,
            generated_at: DateTime.add(now, ts_offset, :second)
          )
        end
      )
    )

    :ok
  end

  test "sortiert nach session.number aufsteigend (Issue #24)" do
    result = Repo.list_session_summaries(@cid)

    assert Enum.map(result, & &1.session_id) == ["sess-a", "sess-b", "sess-c"]
  end

  test "Resümee ohne zugehörige Session landet ans Ende statt zu crashen" do
    Builder.write!(
      Builder.session_summary("sess-orphan", @cid, content_md: "Resümee ohne Session")
    )

    result = Repo.list_session_summaries(@cid)

    assert List.last(result).session_id == "sess-orphan"
    assert length(result) == 4
  end
end
