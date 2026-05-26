defmodule Worker.MaterializerUtteranceDeletedTest do
  @moduledoc """
  Smoke tests for `UtteranceDeleted`: row bekommt einen tombstone
  (deleted_at != nil), nicht hart-deletet (Issue #133, Etappe 3d).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @sid "sess-udel-test"
  @did "did-udel-test"
  @utt_id "utt-udel-1"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    Builder.write!(
      Builder.utterance(@utt_id, @sid,
        discord_id: @did,
        text: "Whisper-Halluzination",
        confidence: nil,
        status: :confirmed
      )
    )

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "setzt tombstone (deleted_at != nil), Row bleibt erhalten" do
    ev =
      event(
        "UtteranceDeleted",
        %{"id" => @utt_id, "session_id" => @sid, "deleted_by" => "some-did"},
        300
      )

    assert {:applied, 300} = Materializer.apply_event(ev)

    [row] = :mnesia.dirty_read(S.utterances(), @utt_id)
    # Tuple-Layout: {table, id, sid, did, ts, text, conf, status, deleted_at}
    deleted_at = elem(row, 8)
    assert %DateTime{} = deleted_at
  end

  test "unknown id is a no-op" do
    ev =
      event(
        "UtteranceDeleted",
        %{"id" => "unknown", "session_id" => "x", "deleted_by" => "y"},
        301
      )

    assert {:applied, 301} = Materializer.apply_event(ev)
    # Original row still there + nicht tombstone'd:
    [row] = :mnesia.dirty_read(S.utterances(), @utt_id)
    assert elem(row, 8) == nil
  end
end
