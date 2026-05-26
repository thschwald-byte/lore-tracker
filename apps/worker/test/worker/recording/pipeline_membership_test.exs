defmodule Worker.Recording.PipelineMembershipTest do
  @moduledoc """
  Issue #236: Pipeline.maybe_run/2 darf nicht mehr auf `owner_discord_id`
  testen, sondern auf Membership. Sonst läuft die Pipeline für Hub-User-
  ohne-eigenen-Worker nie, weil der Fallback-Worker (Issue #146) den
  Owner-Check immer fail't.

  Issue #255 (Flake-Fix): vorher wurde via `:sys.get_state(Pipeline).running`
  getestet — race-anfällig, weil `Task.start` in `maybe_run` einen `:stage_done`-
  Roundtrip triggert, der den Marker SOFORT wieder entfernt wenn die Session
  keine Utterances hat (run_stages skippt sofort). Resultat: Test sah leeres
  running-Set obwohl Pipeline korrekt gestartet wurde.

  Neuer Ansatz: capture_log + assert auf die `Logger.info`-Lines aus
  `maybe_run/3` (`"starting stages for session=…"` vs `"is not a member;
  skipping"`). Testet das Verhalten direkt, race-frei.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Worker.TestHelper

  alias Worker.Recording.Pipeline
  alias Worker.Repo
  alias Worker.Schema.Builder

  setup do
    clear_all_tables!()

    # Pipeline-Prozess idempotent starten (Worker.Application startet ihn nur
    # bei gepaartem Worker — Test-Boot ist nicht gepaart).
    pid =
      case Pipeline.start_link([]) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    # Test-env hat default `Logger.level: :warning` (config/test.exs) — wir
    # brauchen :info damit die `Logger.info`-Branch-Marker durchkommen.
    prev_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: prev_level)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

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

    log = capture_log(fn -> Pipeline.run_for_session(sid) end)

    assert log =~ "starting stages for session=#{sid}"
    refute log =~ "is not a member"
  end

  test "läuft wenn Worker-Admin Spielleiter ist (Standard-Owner-Pfad)" do
    {_cid, sid} = setup_campaign([{"admin-did", :spielleiter}])
    Repo.put_state(:admin_discord_id, "admin-did")

    log = capture_log(fn -> Pipeline.run_for_session(sid) end)

    assert log =~ "starting stages for session=#{sid}"
    refute log =~ "is not a member"
  end

  test "skipped wenn Worker-Admin nicht Member ist" do
    {_cid, sid} = setup_campaign([{"some-other-user", :spielleiter}])
    Repo.put_state(:admin_discord_id, "admin-not-member")

    log = capture_log(fn -> Pipeline.run_for_session(sid) end)

    assert log =~ "admin=admin-not-member is not a member; skipping"
    refute log =~ "starting stages"
  end
end
