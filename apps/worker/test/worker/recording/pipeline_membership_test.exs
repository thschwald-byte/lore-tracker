defmodule Worker.Recording.PipelineMembershipTest do
  @moduledoc """
  Issue #236: Pipeline.maybe_run/2 darf nicht mehr auf `owner_discord_id`
  testen, sondern auf Membership. Sonst läuft die Pipeline für Hub-User-
  ohne-eigenen-Worker nie, weil der Fallback-Worker (Issue #146) den
  Owner-Check immer fail't.

  Verifiziert wird via `:sys.get_state(Pipeline).running` — wenn maybe_run
  die Stages startet, landet die session_id im `running`-MapSet.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Schema.Builder
  alias Worker.Recording.Pipeline
  alias Worker.Repo

  setup do
    clear_all_tables!()

    # Pipeline-Prozess idempotent starten (Worker.Application startet ihn nur
    # bei gepaartem Worker — Test-Boot ist nicht gepaart).
    pid =
      case Pipeline.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    %{pid: pid}
  end

  defp setup_campaign(members) do
    cid = "camp-pipeline-mem-#{System.unique_integer([:positive])}"
    sid = "sess-pipeline-mem-#{System.unique_integer([:positive])}"

    Builder.write!(Builder.campaign(cid, name: "Pipeline-Test"))
    Builder.write!(Builder.session(sid, cid, number: 1))

    Enum.each(members, fn {did, role} ->
      Builder.write!(Builder.campaign_member(cid, did, role: role))
    end)

    {cid, sid}
  end

  test "läuft wenn Worker-Admin Member der Kampagne ist (egal mit welcher Rolle)" do
    {_cid, sid} = setup_campaign([{"admin-did", :spieler}, {"other", :spielleiter}])
    Repo.put_state(:admin_discord_id, "admin-did")

    Pipeline.run_for_session(sid)

    running = :sys.get_state(Pipeline).running
    assert MapSet.member?(running, sid), "session muss in running stehen wenn Admin Member ist"
  end

  test "läuft wenn Worker-Admin Spielleiter ist (Standard-Owner-Pfad)" do
    {_cid, sid} = setup_campaign([{"admin-did", :spielleiter}])
    Repo.put_state(:admin_discord_id, "admin-did")

    Pipeline.run_for_session(sid)

    assert MapSet.member?(:sys.get_state(Pipeline).running, sid)
  end

  test "skipped wenn Worker-Admin nicht Member ist" do
    {_cid, sid} = setup_campaign([{"some-other-user", :spielleiter}])
    Repo.put_state(:admin_discord_id, "admin-not-member")

    Pipeline.run_for_session(sid)

    refute MapSet.member?(:sys.get_state(Pipeline).running, sid),
           "session darf nicht in running stehen wenn Admin nicht Member ist"
  end
end
