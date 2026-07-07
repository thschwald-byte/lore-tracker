defmodule Worker.MaterializerApplyBatchTest do
  @moduledoc """
  Issue #717: `Materializer.apply_batch/1` läuft jetzt als EIN GenServer-Call
  (Schleife im Server-Prozess) statt N serieller Einzel-Calls aus dem
  Slipstream-Handler. Der Vertrag muss dabei identisch bleiben:

  - Events strikt sequenziell in Listen-Reihenfolge applied.
  - Rückgabe = höchste applied seq (skipped Events zählen nicht runter).
  - event_id-Idempotenz unverändert (bereits applied → :skipped im Batch).
  - Leerer Batch → last_applied_seq, kein Call.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid = ensure_materializer!()

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp user_event(seq, did) do
    %{
      "seq" => seq,
      "event_id" =>
        "019e7170-#{String.pad_leading(Integer.to_string(seq), 4, "0")}-7000-8000-000000000000",
      "payload" => %{
        "kind" => "UserUpserted",
        "discord_id" => did,
        "display_name" => "User #{did}"
      },
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  test "Batch wird sequenziell applied, Rückgabe = höchste seq" do
    events = for n <- 1..5, do: user_event(n, "did-batch-#{n}")

    assert Materializer.apply_batch(events) == 5
    assert Materializer.last_applied_seq() == 5

    # alle 5 User materialisiert
    for n <- 1..5 do
      assert Worker.Repo.get_user("did-batch-#{n}")
    end
  end

  test "Idempotenz im Batch: bereits applied Events werden geskippt, max-seq bleibt korrekt" do
    e1 = user_event(1, "did-dup")
    assert {:applied, 1} = Materializer.apply_event(e1)

    # Batch mit dem Duplikat + einem neuen Event
    assert Materializer.apply_batch([e1, user_event(2, "did-neu")]) == 2
    assert Materializer.last_applied_seq() == 2
  end

  test "leerer Batch → last_applied_seq ohne Server-Roundtrip" do
    assert Materializer.apply_batch([]) == 0

    assert {:applied, 7} = Materializer.apply_event(user_event(7, "did-x"))
    assert Materializer.apply_batch([]) == 7
  end

  test "großer Batch (200 Events) läuft in einem Call durch" do
    events = for n <- 1..200, do: user_event(n, "did-bulk-#{n}")
    assert Materializer.apply_batch(events) == 200
    assert Worker.Repo.get_user("did-bulk-200")
  end
end
