defmodule Worker.MaterializerUtteranceDeletedTest do
  @moduledoc """
  Smoke tests for `UtteranceDeleted`: row is removed; idempotent on
  unknown ids.
  """

  use ExUnit.Case, async: false

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @sid "sess-udel-test"
  @did "did-udel-test"
  @utt_id "utt-udel-1"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.utterances())
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid =
      case Worker.Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({
          S.utterances(),
          @utt_id,
          @sid,
          @did,
          DateTime.utc_now(),
          "Whisper-Halluzination",
          nil,
          :confirmed
        })
      end)

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp event(kind, payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", kind)
    }
  end

  test "deletes the row" do
    ev = event("UtteranceDeleted", %{
      "id" => @utt_id,
      "session_id" => @sid,
      "deleted_by" => "some-did"
    }, 300)

    assert {:applied, 300} = Materializer.apply_event(ev)
    assert :mnesia.dirty_read(S.utterances(), @utt_id) == []
  end

  test "unknown id is a no-op" do
    ev = event("UtteranceDeleted", %{
      "id" => "unknown",
      "session_id" => "x",
      "deleted_by" => "y"
    }, 301)

    assert {:applied, 301} = Materializer.apply_event(ev)
    # Original row still there:
    assert [_] = :mnesia.dirty_read(S.utterances(), @utt_id)
  end
end
