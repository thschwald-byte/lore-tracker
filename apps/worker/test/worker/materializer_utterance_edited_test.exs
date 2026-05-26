defmodule Worker.MaterializerUtteranceEditedTest do
  @moduledoc """
  Smoke tests for `UtteranceEdited` (Issue #3) — replaces text + sets
  status to :edited, preserves all other fields.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Builder
  alias Worker.Schema.Mnesia, as: S

  @sid "sess-uedit-test"
  @did "did-uedit-test"
  @utt_id "utt-uedit-1"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    Builder.write!(
      Builder.utterance(@utt_id, @sid,
        discord_id: @did,
        text: "Ursprüngliches Transkript",
        confidence: nil,
        status: :confirmed
      )
    )

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  test "replaces text + sets status :edited, preserves session/discord/timestamp" do
    ev =
      event(
        "UtteranceEdited",
        %{
          "id" => @utt_id,
          "session_id" => @sid,
          "new_text" => "Korrigierter Text",
          "edited_by" => "some-other-did"
        },
        200
      )

    assert {:applied, 200} = Materializer.apply_event(ev)

    [row] = :mnesia.dirty_read(S.utterances(), @utt_id)
    {_, id, sid, did, _ts, text, _conf, status, deleted_at} = row

    assert id == @utt_id
    assert sid == @sid
    assert did == @did
    assert text == "Korrigierter Text"
    assert status == :edited
    assert deleted_at == nil
  end

  test "unknown id is silently dropped (no crash)" do
    ev =
      event(
        "UtteranceEdited",
        %{"id" => "unknown-utt", "session_id" => "sess-x", "new_text" => "x"},
        201
      )

    assert {:applied, 201} = Materializer.apply_event(ev)
    assert :mnesia.dirty_read(S.utterances(), "unknown-utt") == []
  end
end
