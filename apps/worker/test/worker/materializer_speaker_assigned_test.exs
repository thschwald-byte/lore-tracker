defmodule Worker.MaterializerSpeakerAssignedTest do
  @moduledoc """
  Issue #19: `SpeakerAssigned` pflegt die `worker_speaker_assignments`-Tabelle.
  Utterances behalten ihr Pseudo-Label — diese Tabelle mappt Label → echte
  discord_id. Re-Assignment überschreibt idempotent; leere discord_id hebt auf.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @sid "sess-ss-test"
  @label "speaker:sess-ss-test:0"

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())
    ensure_materializer!()
    :ok
  end

  test "assign schreibt eine Zuordnung" do
    ev =
      event(
        "SpeakerAssigned",
        %{"session_id" => @sid, "speaker_label" => @label, "discord_id" => "did-alice"},
        1000
      )

    assert {:applied, 1000} = Materializer.apply_event(ev)

    assert [%{speaker_label: @label, discord_id: "did-alice"}] =
             Repo.list_speaker_assignments(@sid)
  end

  test "re-assign überschreibt idempotent dasselbe Label" do
    Materializer.apply_event(
      event(
        "SpeakerAssigned",
        %{"session_id" => @sid, "speaker_label" => @label, "discord_id" => "did-alice"},
        1000
      )
    )

    Materializer.apply_event(
      event(
        "SpeakerAssigned",
        %{"session_id" => @sid, "speaker_label" => @label, "discord_id" => "did-bob"},
        1001
      )
    )

    assert [%{discord_id: "did-bob"}] = Repo.list_speaker_assignments(@sid)
  end

  test "leere discord_id hebt die Zuordnung auf" do
    Materializer.apply_event(
      event(
        "SpeakerAssigned",
        %{"session_id" => @sid, "speaker_label" => @label, "discord_id" => "did-alice"},
        1000
      )
    )

    Materializer.apply_event(
      event(
        "SpeakerAssigned",
        %{"session_id" => @sid, "speaker_label" => @label, "discord_id" => ""},
        1001
      )
    )

    assert [] = Repo.list_speaker_assignments(@sid)
  end
end
