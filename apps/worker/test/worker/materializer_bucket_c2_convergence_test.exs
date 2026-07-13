defmodule Worker.MaterializerBucketC2ConvergenceTest do
  @moduledoc """
  Issue #824 (I7-Bucket-C2, Epic #766): Convergence-Tests für die
  Session-Status-Lattice (SessionStarted/SessionEnded/RecordingStateChanged)
  und die Consent-Version-Max-Lattice (AudioConsentRecorded).

  Anders als Bucket C (#816, reines LWW auf `event_id`) braucht dieser
  Bucket einen Rang-Vergleich statt Zeit-Vergleich — ein `:completed` darf
  nie von einem `:recording`/`:scheduled` zurückgedreht werden, unabhängig
  von Ankunftsreihenfolge oder Timestamp. Dasselbe Pairwise-Reihenfolge-
  Pattern wie `materializer_bucket_c_convergence_test.exs` (Basis-Entität
  vor JEDER der 2 Reihenfolgen frisch aufgebaut, nur die 2 konkurrierenden
  Events umsortiert).
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  import ExUnit.CaptureLog

  alias Worker.Materializer
  alias Worker.Repo

  @cid "camp-824"
  @sid "camp-824-s1"
  @member_did "did-member-824"
  @owner_did "did-owner-824"
  @consent_did "did-consent-824"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp next_seq, do: System.unique_integer([:positive, :monotonic])

  # Kampagne + 1 Session (nur SessionScheduled, kein SessionStarted) frisch
  # aufbauen — für jede der 2 Reihenfolgen neu aufgerufen.
  defp seed_session! do
    build_campaign(
      campaign_id: @cid,
      owner_did: @owner_did,
      members: [@member_did],
      sessions: [],
      apply: true
    )

    Materializer.apply_event(
      event(
        "SessionScheduled",
        %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
        next_seq(),
        event_id: "seed-session-scheduled"
      )
    )
  end

  defp apply_pairwise!(order) do
    reset_for_permutation!()
    seed_session!()
    Enum.each(order, &Materializer.apply_event/1)
  end

  defp assert_pairwise_converges!(a, b, read_fn, expected) do
    for order <- [[a, b], [b, a]] do
      apply_pairwise!(order)

      assert read_fn.() == expected,
             "Reihenfolge #{inspect(Enum.map(order, & &1["event_id"]))} lieferte falsches Ergebnis"
    end
  end

  describe "Session-Status-Lattice" do
    test "SessionEnded (:completed) übersteht ein nachgezogenes SessionStarted (:recording)" do
      started =
        event("SessionStarted", %{"id" => @sid, "campaign_id" => @cid}, next_seq(),
          event_id: "e-started"
        )

      ended =
        event("SessionEnded", %{"id" => @sid, "campaign_id" => @cid}, next_seq(),
          event_id: "e-ended"
        )

      assert_pairwise_converges!(
        started,
        ended,
        fn -> Repo.get_session(@sid).status end,
        :completed
      )
    end

    test "SessionEnded (:completed) übersteht ein nachgezogenes RecordingStateChanged(:idle)" do
      ended =
        event("SessionEnded", %{"id" => @sid, "campaign_id" => @cid}, next_seq(),
          event_id: "e-ended2"
        )

      idle =
        event("RecordingStateChanged", %{"session_id" => @sid, "state" => "idle"}, next_seq(),
          event_id: "e-idle"
        )

      assert_pairwise_converges!(ended, idle, fn -> Repo.get_session(@sid).status end, :completed)
    end

    test "RecordingStateChanged(:processing) überschreibt :scheduled — legitimer Rang-Vorwärtssprung" do
      processing =
        event(
          "RecordingStateChanged",
          %{"session_id" => @sid, "state" => "processing"},
          next_seq(),
          event_id: "e-proc"
        )

      apply_pairwise!([processing])

      assert Repo.get_session(@sid).status == :processing
    end

    test "verworfenes Status-Update loggt (Reject-Log)" do
      reset_for_permutation!()
      seed_session!()

      Materializer.apply_event(
        event("SessionEnded", %{"id" => @sid, "campaign_id" => @cid}, next_seq(),
          event_id: "e-ended3"
        )
      )

      # Siehe #816-Präzedenz: Logger.debug/1 wird bei der Default-Test-
      # Logger-Config (:warning) vor dem Backend gefiltert — expliziter
      # Per-Modul-Level-Override auf das aufrufende Modul ist der einzige
      # Weg, der zuverlässig durchgreift.
      Logger.put_module_level(Worker.Materializer, :debug)

      log =
        capture_log(fn ->
          Materializer.apply_event(
            event("SessionStarted", %{"id" => @sid, "campaign_id" => @cid}, next_seq(),
              event_id: "e-started3"
            )
          )
        end)

      Logger.delete_module_level(Worker.Materializer)

      assert log =~ "session status rejected"
      assert Repo.get_session(@sid).status == :completed
    end
  end

  describe "AudioConsentRecorded Max-Version-Lattice" do
    defp consent_event(version, accepted_at, event_id) do
      event(
        "AudioConsentRecorded",
        %{"discord_id" => @consent_did, "version" => version, "accepted_at" => accepted_at},
        next_seq(),
        event_id: event_id
      )
    end

    test "v2 gewinnt gegen ein nachgezogenes v1, unabhängig von Reihenfolge" do
      v1 = consent_event("v1", "2026-01-01T00:00:00Z", "e-consent-v1")
      v2 = consent_event("v2", "2026-06-01T00:00:00Z", "e-consent-v2")

      for order <- [[v1, v2], [v2, v1]] do
        reset_for_permutation!()
        Enum.each(order, &Materializer.apply_event/1)

        assert Repo.audio_consent(@consent_did).version == "v2",
               "Reihenfolge #{inspect(Enum.map(order, & &1["event_id"]))} lieferte falsches Ergebnis"
      end
    end

    test "Gleichstand (gleiche Version) — späterer accepted_at gewinnt, unabhängig von Reihenfolge" do
      early = consent_event("v1", "2026-01-01T00:00:00Z", "e-consent-early")
      late = consent_event("v1", "2026-06-01T00:00:00Z", "e-consent-late")

      for order <- [[early, late], [late, early]] do
        reset_for_permutation!()
        Enum.each(order, &Materializer.apply_event/1)

        assert DateTime.to_iso8601(Repo.audio_consent(@consent_did).accepted_at) ==
                 "2026-06-01T00:00:00Z",
               "Reihenfolge #{inspect(Enum.map(order, & &1["event_id"]))} lieferte falsches Ergebnis"
      end
    end
  end
end
