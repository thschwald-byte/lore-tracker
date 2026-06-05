defmodule Worker.Recording.PipelineElectionTest do
  @moduledoc """
  Issue #365: Single-Worker-Election im event-getriggerten Pipeline-Pfad.

  Bei mehreren connected Member-Workern wird `UtterancesTranscribed` via Hub an
  ALLE geforwarded — ohne Filter würde jeder die Stages 2-4 starten (doppelte
  LLM-Calls + Doppel-Events). Nur der Worker, der das Event selbst produziert hat
  (`author_worker_id == eigene worker_id`), fährt die Pipeline.

  Test-Ansatz analog `pipeline_membership_test.exs`: capture_log + assert auf die
  `Logger.info`-Branch-Marker aus `maybe_run/3` ("starting stages for session=…"
  bzw. "is not a member; skipping"). `:sys.get_state/1` nach dem `send/2` zwingt
  den GenServer, die `handle_info`-Message vor dem Log-Check zu verarbeiten
  (race-frei, da Messages in-order laufen).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Schema.Builder

  describe "elected?/2 (pures Election-Prädikat)" do
    test "true wenn author_worker_id == eigene worker_id (Producer)" do
      assert Pipeline.elected?(%{"author_worker_id" => "w1"}, "w1")
    end

    test "false wenn ein anderer Worker produziert hat (Empfänger)" do
      refute Pipeline.elected?(%{"author_worker_id" => "w2"}, "w1")
    end

    test "false bei author_worker_id == nil auf gepairtem Worker (Catch-up/Pull)" do
      refute Pipeline.elected?(%{"author_worker_id" => nil}, "w1")
      refute Pipeline.elected?(%{}, "w1")
    end

    test "true bei nil == nil (ungepairter Single-Worker-Dev)" do
      assert Pipeline.elected?(%{"author_worker_id" => nil}, nil)
      assert Pipeline.elected?(%{}, nil)
    end
  end

  describe "handle_info UtterancesTranscribed — Election-Gate" do
    setup do
      clear_all_tables!()

      # Issue #571: maybe_run/3 spawnt via Task.Supervisor — in Standalone-
      # Tests den Supervisor explizit anwerfen.
      ensure_started(Worker.TaskSupervisor, fn ->
        Task.Supervisor.start_link(name: Worker.TaskSupervisor)
      end)

      pid =
        case Pipeline.start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      prev_level = Logger.level()
      Logger.configure(level: :info)

      on_exit(fn ->
        Logger.configure(level: prev_level)
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      %{pid: pid}
    end

    defp setup_member_campaign do
      cid = "camp-election-#{System.unique_integer([:positive])}"
      sid = "sess-election-#{System.unique_integer([:positive])}"

      Builder.write!(Builder.campaign(cid, name: "Election-Test"))
      Builder.write!(Builder.session(sid, cid, number: 1))
      Builder.write!(Builder.campaign_member(cid, "admin-did", role: :spielleiter))

      Repo.put_state(:admin_discord_id, "admin-did")
      {cid, sid}
    end

    defp transcribed_event(sid, author) do
      {:applied,
       %{
         "author_worker_id" => author,
         "payload" => %{"kind" => "UtterancesTranscribed", "session_id" => sid}
       }}
    end

    test "Producer (author == worker_id) startet die Pipeline", %{pid: pid} do
      {_cid, sid} = setup_member_campaign()
      Repo.put_state(:worker_id, "w-self")

      log =
        capture_log(fn ->
          send(pid, transcribed_event(sid, "w-self"))
          _ = :sys.get_state(pid)
        end)

      assert log =~ "starting stages for session=#{sid}"
    end

    test "Empfänger (author == fremde worker_id) startet NICHT", %{pid: pid} do
      {_cid, sid} = setup_member_campaign()
      Repo.put_state(:worker_id, "w-self")

      log =
        capture_log(fn ->
          send(pid, transcribed_event(sid, "w-other"))
          _ = :sys.get_state(pid)
        end)

      # Vor dem Member-Check ge-skippt → weder "starting stages" noch
      # "is not a member": die Election greift zuerst.
      refute log =~ "starting stages"
      refute log =~ "is not a member"
    end

    test "Catch-up-Event (author == nil) auf gepairtem Worker startet NICHT", %{pid: pid} do
      {_cid, sid} = setup_member_campaign()
      Repo.put_state(:worker_id, "w-self")

      log =
        capture_log(fn ->
          send(pid, transcribed_event(sid, nil))
          _ = :sys.get_state(pid)
        end)

      refute log =~ "starting stages"
    end
  end
end
