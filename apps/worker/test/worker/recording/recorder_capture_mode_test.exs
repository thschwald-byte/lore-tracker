defmodule Worker.Recording.RecorderCaptureModeTest do
  @moduledoc """
  Issue #987 (Nachtrag zu #985): `Recorder.choose_capture_mode/3` — die
  session-weite Discord/Browser-Exklusivität. Der volle `start_for_owner/2`-
  Pfad braucht Materializer+AudioBuffer-Bootstrap (s. `RecorderPermissionTest`-
  Moduledoc: „Full-Stack-Integration ist in der PR-Test-Acceptance
  abgedeckt") — hier wird `state.by_campaign` direkt via `:sys.replace_state`
  gesetzt, exakt das etablierte Muster aus `AudioBufferStreamersTest` für
  GenServer-State, den über die öffentliche API zu erreichen unverhältnismäßig
  wäre.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Recording.Recorder

  setup do
    clear_all_tables!()
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())

    {:ok, _} = start_supervised({Registry, keys: :unique, name: Worker.Discord.Registry})

    {:ok, _} =
      start_supervised(
        {DynamicSupervisor, name: Worker.Discord.BotSupervisor, strategy: :one_for_one}
      )

    if pid = Process.whereis(Recorder) do
      Process.exit(pid, :kill)

      Enum.reduce_while(1..50, :ok, fn _, _ ->
        if Process.whereis(Recorder), do: {:cont, Process.sleep(10)}, else: {:halt, :ok}
      end)
    end

    pid = start_supervised!({Recorder, nil})
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    %{pid: pid}
  end

  defp seed_active_session(pid, campaign_id, session_id) do
    entry = %{
      campaign_id: campaign_id,
      campaign_name: "Cap-Mode-Test",
      session_id: session_id,
      owner_discord_id: "gm-1",
      started_at: DateTime.utc_now(),
      discord_guild_id: nil
    }

    :sys.replace_state(pid, fn state ->
      %{state | by_campaign: Map.put(state.by_campaign, campaign_id, entry)}
    end)
  end

  test "keine aktive Session -> :not_recording" do
    refute Recorder.get("no-such-campaign")

    assert {:error, :not_recording} =
             Recorder.choose_capture_mode("did", "no-such-campaign", :browser)
  end

  test "erste Wahl 'browser' -> {:ok, :browser}, persistiert im Reader", %{pid: pid} do
    cid = "camp-cm-1"
    sid = "sess-cm-1"
    seed_active_session(pid, cid, sid)

    assert {:ok, :browser} = Recorder.choose_capture_mode("did-1", cid, :browser)
    assert Worker.Repo.get_session_capture_mode(sid) == "browser"
  end

  test "erneuter Klick auf denselben Modus ist idempotent", %{pid: pid} do
    cid = "camp-cm-2"
    sid = "sess-cm-2"
    seed_active_session(pid, cid, sid)

    assert {:ok, :browser} = Recorder.choose_capture_mode("did-1", cid, :browser)
    assert {:ok, :browser} = Recorder.choose_capture_mode("did-2", cid, :browser)
  end

  test "'discord' NACH bereits gewähltem 'browser' -> :already_chosen, Modus bleibt browser", %{
    pid: pid
  } do
    cid = "camp-cm-3"
    sid = "sess-cm-3"
    seed_active_session(pid, cid, sid)

    assert {:ok, :browser} = Recorder.choose_capture_mode("did-1", cid, :browser)

    assert {:error, :already_chosen, "browser"} =
             Recorder.choose_capture_mode("did-2", cid, :discord)

    assert Worker.Repo.get_session_capture_mode(sid) == "browser"
  end

  test "'discord' ohne echten Nostrum.Bot -> :discord_unavailable, KEIN Modus gesetzt (Buttons bleiben offen)",
       %{pid: pid} do
    cid = "camp-cm-4"
    sid = "sess-cm-4"
    seed_active_session(pid, cid, sid)

    assert {:error, :discord_unavailable} = Recorder.choose_capture_mode("did-1", cid, :discord)
    assert Worker.Repo.get_session_capture_mode(sid) == nil

    # Buttons bleiben offen -> ein Folge-Klick auf "browser" muss noch möglich sein.
    assert {:ok, :browser} = Recorder.choose_capture_mode("did-1", cid, :browser)
  end
end
