defmodule Worker.MaterializerSessionCaptureModeTest do
  @moduledoc """
  Issue #987 (Nachtrag zu #985): Konvergenz + Cascade für das
  SessionCaptureModeSet-Whole-Snapshot-Artefakt (`worker_session_capture_modes`).

  Kern-Invariante wie bei CampaignDiscordConfigSet: **Whole-Snapshot ⇒
  Voll-Ersatz, kein Feld-Merge**. Zwei DIVERGENTE Payloads → der höhere
  event_id gewinnt KOMPLETT.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Repo
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-capture-mode-987"
  @sid "sess-capture-mode-987"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp mode_ev(mode, seq, event_id) do
    event(
      "SessionCaptureModeSet",
      %{"session_id" => @sid, "campaign_id" => @cid, "mode" => mode, "set_by" => "did-1"},
      seq,
      event_id: event_id
    )
  end

  defp read_row(tbl, key) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(tbl, key) end)
    rows
  end

  defp fold_meta_row(tbl, key, fold) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(S.fold_meta(), {tbl, key, fold}) end)
    rows
  end

  test "materialisiert → Repo.get_session_capture_mode liest zurück" do
    assert {:applied, 1} = Materializer.apply_event(mode_ev("discord", 1, "cm-ev-1"))
    assert Repo.get_session_capture_mode(@sid) == "discord"
  end

  test "fehlende Row → nil (noch keine Wahl getroffen)" do
    assert Repo.get_session_capture_mode(@sid) == nil
  end

  test "bad session_id/campaign_id wird verworfen statt zu crashen" do
    ev = event("SessionCaptureModeSet", %{"session_id" => nil, "mode" => "discord"}, 1)
    assert {:applied, 1} = Materializer.apply_event(ev)
    assert Repo.get_session_capture_mode(@sid) == nil
  end

  test "unbekannter mode-Wert wird verworfen statt zu crashen" do
    ev =
      event(
        "SessionCaptureModeSet",
        %{"session_id" => @sid, "campaign_id" => @cid, "mode" => "raummikro"},
        1
      )

    assert {:applied, 1} = Materializer.apply_event(ev)
    assert Repo.get_session_capture_mode(@sid) == nil
  end

  test "LWW: zwei DIVERGENTE Payloads, höherer event_id gewinnt KOMPLETT, jede Reihenfolge konvergiert" do
    events = [mode_ev("browser", 1, "cm-ev-1"), mode_ev("discord", 2, "cm-ev-2")]

    results = materialize_permutations(events, fn -> Repo.get_session_capture_mode(@sid) end)

    Enum.each(results, fn r -> assert r == "discord" end)
    assert Enum.uniq(results) == ["discord"]
  end

  test "nil-event_id (schlüsselloses Alt-Event) clobbert eine geschlüsselte Row NICHT" do
    reset_for_permutation!()
    Materializer.apply_event(mode_ev("discord", 1, "cm-ev-keyed"))

    Materializer.apply_event(
      event(
        "SessionCaptureModeSet",
        %{"session_id" => @sid, "campaign_id" => @cid, "mode" => "browser"},
        2
      )
    )

    assert Repo.get_session_capture_mode(@sid) == "discord"
  end

  describe "Cascade" do
    test "SessionDeleted räumt Row + fold_meta" do
      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          1
        )
      )

      Materializer.apply_event(mode_ev("discord", 2, "cm-ev-sd"))

      assert Repo.get_session_capture_mode(@sid) == "discord"
      assert read_row(S.session_capture_modes(), @sid) != []
      assert fold_meta_row(S.session_capture_modes(), @sid, :session_capture_mode_set) != []

      Materializer.apply_event(
        event("SessionDeleted", %{"session_id" => @sid, "campaign_id" => @cid}, 3)
      )

      assert Repo.get_session_capture_mode(@sid) == nil
      assert read_row(S.session_capture_modes(), @sid) == []
      assert fold_meta_row(S.session_capture_modes(), @sid, :session_capture_mode_set) == []
    end

    test "CampaignDeleted räumt die Row campaign-weit" do
      Materializer.apply_event(event("CampaignCreated", %{"id" => @cid, "name" => "Camp"}, 1))

      Materializer.apply_event(
        event(
          "SessionScheduled",
          %{"id" => @sid, "campaign_id" => @cid, "number" => 1, "name" => "S1"},
          2
        )
      )

      Materializer.apply_event(mode_ev("browser", 3, "cm-ev-cd"))
      assert Repo.get_session_capture_mode(@sid) == "browser"

      Materializer.apply_event(
        event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 4)
      )

      assert Repo.get_session_capture_mode(@sid) == nil
      assert read_row(S.session_capture_modes(), @sid) == []
    end
  end
end
