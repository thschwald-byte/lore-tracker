defmodule Worker.RepoUtteranceLiveFilterTest do
  @moduledoc """
  Issue #418: nach dem Live-Removal filtert `Repo.list_utterances/2` Alt-
  `status: :live`-Rows IMMER defensiv raus (die `confirmed`-Batch-Variante
  ist die kanonische). Der frühere `:source`-Opt (#394) ist weg.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Repo
  alias Worker.Schema.Builder

  @sid "sess-live-filter-test"

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

  test "list_utterances filtert :live-Rows raus, liefert nur Batch (confirmed + edited)" do
    assert ids(Repo.list_utterances(@sid)) == ["u-conf-1", "u-edit-1"]
  end

  test "keine zurückgelieferte Utterance hat status :live" do
    refute Enum.any?(Repo.list_utterances(@sid), &(&1.status == :live))
  end
end
