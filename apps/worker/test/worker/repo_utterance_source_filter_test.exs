defmodule Worker.RepoUtteranceSourceFilterTest do
  @moduledoc """
  Issue #394: `Repo.list_utterances/2` `:source`-Filter — :live → nur live,
  :batch → alles außer live (confirmed/edited/manual), nil → alle.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Builder

  @sid "sess-source-filter-test"

  setup do
    clear_all_tables!()

    base = ~U[2026-06-01 12:00:00Z]

    Builder.write_many!([
      Builder.utterance("u-live-1", @sid,
        status: :live,
        text: "live eins",
        timestamp: DateTime.add(base, 1)
      ),
      Builder.utterance("u-live-2", @sid,
        status: :live,
        text: "live zwei",
        timestamp: DateTime.add(base, 2)
      ),
      Builder.utterance("u-conf-1", @sid,
        status: :confirmed,
        text: "confirmed eins",
        timestamp: DateTime.add(base, 3)
      ),
      Builder.utterance("u-edit-1", @sid,
        status: :edited,
        text: "edited eins",
        timestamp: DateTime.add(base, 4)
      )
    ])

    :ok
  end

  defp ids(utts), do: utts |> Enum.map(& &1.id) |> Enum.sort()

  test "source: :live → nur live-Utterances" do
    assert ids(Repo.list_utterances(@sid, source: :live)) == ["u-live-1", "u-live-2"]
  end

  test "source: :batch → alles AUSSER live (confirmed + edited)" do
    assert ids(Repo.list_utterances(@sid, source: :batch)) == ["u-conf-1", "u-edit-1"]
  end

  test "kein source (nil) → alle Status gemischt" do
    assert ids(Repo.list_utterances(@sid)) ==
             ["u-conf-1", "u-edit-1", "u-live-1", "u-live-2"]
  end

  test "live und batch sind disjunkt + ergeben zusammen alle" do
    live = Repo.list_utterances(@sid, source: :live)
    batch = Repo.list_utterances(@sid, source: :batch)
    all = Repo.list_utterances(@sid)

    assert MapSet.disjoint?(MapSet.new(ids(live)), MapSet.new(ids(batch)))
    assert (ids(live) ++ ids(batch)) |> Enum.sort() == ids(all)
  end
end
