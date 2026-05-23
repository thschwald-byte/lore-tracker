defmodule Worker.RepoListSessionSummariesTest do
  @moduledoc """
  Issue #24: Resümee-Spalte muss nach Session-Nummer aufsteigend sortiert
  sein (Session 1 oben, Session N unten) — NICHT nach `generated_at`
  (wann die LLM-Pipeline den Text erzeugt hat).
  """

  use ExUnit.Case, async: false

  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-listsum-test"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.campaigns())
    {:atomic, :ok} = :mnesia.clear_table(S.sessions())
    {:atomic, :ok} = :mnesia.clear_table(S.session_summaries())

    :mnesia.transaction(fn ->
      :mnesia.write({
        S.campaigns(),
        @cid,
        "Test Campaign",
        nil,
        nil,
        :active,
        DateTime.utc_now(),
        %{}
      })

      # 3 Sessions in „falscher" Reihenfolge anlegen — number 3, 1, 2 —
      # damit der Test wirklich Number-Sortierung prüft und nicht zufällig
      # die Insert-Reihenfolge.
      Enum.each(
        [
          {"sess-c", 3, "Akt III"},
          {"sess-a", 1, "Akt I"},
          {"sess-b", 2, "Akt II"}
        ],
        fn {sid, number, name} ->
          :mnesia.write({
            S.sessions(),
            sid,
            @cid,
            number,
            name,
            :completed,
            nil,
            DateTime.utc_now(),
            DateTime.utc_now()
          })
        end
      )

      # Resümees in noch wieder anderer Reihenfolge anlegen, mit
      # generated_at-Werten die die alte Sortierung „neueste zuerst"
      # genau umkehren würden zur richtigen Reihenfolge.
      now = DateTime.utc_now()

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
            :llm
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
        :llm
      })
    end)

    result = Repo.list_session_summaries(@cid)

    assert List.last(result).session_id == "sess-orphan"
    assert length(result) == 4
  end
end
