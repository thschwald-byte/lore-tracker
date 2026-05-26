defmodule Worker.MaterializerAudioConsentTest do
  @moduledoc """
  Issue #64: AudioConsentRecorded schreibt eine Row pro discord_id mit
  version + accepted_at. Worker.Repo.audio_consent/1 liest sie zurück.
  Idempotent — Replay desselben Events überschreibt die Row mit den
  selben Werten.
  """

  use ExUnit.Case, async: false

  alias Worker.{Materializer, Repo}
  alias Worker.Schema.Mnesia, as: S

  @did "user-consent-test"

  setup do
    {:atomic, :ok} = :mnesia.clear_table(S.audio_consents())
    {:atomic, :ok} = :mnesia.clear_table(S.worker_state())

    mat_pid =
      case Materializer.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, _}} -> nil
      end

    on_exit(fn ->
      if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill)
    end)

    :ok
  end

  defp event(payload, seq) do
    %{
      "seq" => seq,
      "ts" => DateTime.to_iso8601(DateTime.utc_now()),
      "author_worker_id" => "test",
      "payload" => Map.put(payload, "kind", "AudioConsentRecorded")
    }
  end

  test "schreibt version + accepted_at, Repo liest die Row" do
    ts = "2026-05-26T10:00:00Z"

    ev =
      event(
        %{"discord_id" => @did, "version" => "v1", "accepted_at" => ts},
        1
      )

    assert {:applied, 1} = Materializer.apply_event(ev)

    assert %{version: "v1", accepted_at: %DateTime{} = at} = Repo.audio_consent(@did)
    assert DateTime.to_iso8601(at) == ts
  end

  test "unbekannter User → Repo.audio_consent/1 returns nil" do
    refute Repo.audio_consent("never-consented")
  end

  test "Replay desselben Events ist idempotent" do
    ts = "2026-05-26T10:05:00Z"

    ev =
      event(
        %{"discord_id" => @did, "version" => "v1", "accepted_at" => ts},
        1
      )

    assert {:applied, 1} = Materializer.apply_event(ev)

    ev2 = %{ev | "seq" => 2}
    assert {:applied, 2} = Materializer.apply_event(ev2)

    assert %{version: "v1"} = Repo.audio_consent(@did)
  end

  test "Version-Bump überschreibt alte Row" do
    Materializer.apply_event(
      event(
        %{
          "discord_id" => @did,
          "version" => "v1",
          "accepted_at" => "2026-01-01T00:00:00Z"
        },
        1
      )
    )

    Materializer.apply_event(
      event(
        %{
          "discord_id" => @did,
          "version" => "v2",
          "accepted_at" => "2026-05-26T10:00:00Z"
        },
        2
      )
    )

    assert %{version: "v2"} = Repo.audio_consent(@did)
  end

  test "fehlende version → Default v1" do
    ev = event(%{"discord_id" => @did, "accepted_at" => "2026-05-26T10:00:00Z"}, 1)
    assert {:applied, 1} = Materializer.apply_event(ev)
    assert %{version: "v1"} = Repo.audio_consent(@did)
  end
end
