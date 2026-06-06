defmodule Worker.IntentsTest do
  @moduledoc """
  Issue #608: Wire-Shape-Smoke für `Worker.Intents` — laut CLAUDE.md der EINZIGE
  Schreibweg in Prod (RPC-Bridge). Bisher null direkte Coverage.

  Gesicherte Verträge:
  - publish/1 liefert IMMER `{:ok, seq | :pending}`, crasht nie (auch bei Hub-
    offline → `{:ok, :pending}`, kein Datenverlust, kein Raise).
  - Worker-First-Apply: das Event wird lokal angewandt, unabhängig vom Hub-Sync.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.{Intents, Repo}
  alias Worker.Schema.Builder
  alias Shared.Events

  setup do
    clear_all_tables!()
    mat = ensure_materializer!()
    on_exit(fn -> if mat && Process.alive?(mat), do: Process.exit(mat, :kill) end)
    :ok
  end

  test "publish/1 liefert {:ok, :pending} statt zu crashen, wenn der Hub offline ist" do
    log =
      capture_log(fn ->
        assert {:ok, :pending} =
                 Intents.publish(%{
                   "kind" => Events.live_utterances_cleared(),
                   "session_id" => "s-none"
                 })
      end)

    assert log =~ "Hub-Sync failed"
  end

  test "publish/1 wendet das Event lokal an (Worker-First-Apply), auch ohne Hub" do
    # Session mit einer live + einer batch Utterance → live_purge_plan zählt die
    # live-Row als clearable. publish(LiveUtterancesCleared) muss sie lokal
    # entfernen, unabhängig vom (offline) Hub.
    Builder.write!(Builder.session("s-1", "c-1", number: 1))
    Builder.write!(Builder.utterance("u-live", "s-1", status: :live))
    Builder.write!(Builder.utterance("u-batch", "s-1", status: :active))

    assert %{clearable: [{"s-1", 1}], orphan: []} = Repo.live_purge_plan()

    capture_log(fn ->
      assert {:ok, :pending} =
               Intents.publish(%{
                 "kind" => Events.live_utterances_cleared(),
                 "session_id" => "s-1"
               })
    end)

    # live-Row lokal weg → plan leer (apply_local hat gegriffen).
    assert %{clearable: [], orphan: []} = Repo.live_purge_plan()
  end
end
