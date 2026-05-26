defmodule Worker.Recording.RecorderPermissionTest do
  @moduledoc """
  Issue #225: Recorder.resolve_campaign/2 muss Membership-Rolle prüfen,
  nicht das abgeleitete `owner_discord_id`-Feld. Sonst kann nach einem
  Promote/Demote-Tanz die "falsche" Person als erster Spielleiter aus
  `first_spielleiter/1` returnt werden und der eigentliche Ersteller
  bekommt `:not_owner`.

  Test-Strategie:
  - **Reject-Pfade** (`:not_authorized`, `:campaign_not_found`) gehen
    direkt durch Recorder.start_for_owner — short-circuit, kein
    Materializer/AudioBuffer nötig.
  - **Positiv-Pfade** verifizieren `Worker.Repo.campaign_role/2` direkt
    als der eigentliche Fix-Punkt. Full-Stack-Integration (REC-Start mit
    Session-Creation) ist in der PR-Test-Acceptance abgedeckt.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper
  alias Worker.Schema.Builder
  alias Worker.Recording.Recorder

  setup do
    clear_all_tables!()

    case Recorder.start_link(nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp setup_campaign_with_members(members) do
    cid = "camp-recorder-perm-#{System.unique_integer([:positive])}"
    Builder.write!(Builder.campaign(cid, name: "Recorder-Test"))

    Enum.each(members, fn {did, role} ->
      Builder.write!(Builder.campaign_member(cid, did, role: role))
    end)

    cid
  end

  describe "Recorder.start_for_owner — reject-Pfade" do
    test ":spieler-Member ist nicht autorisiert" do
      cid = setup_campaign_with_members([{"alice", :spielleiter}, {"charlie", :spieler}])

      assert {:error, :not_authorized} = Recorder.start_for_owner("charlie", cid)
    end

    test "Nicht-Member ist nicht autorisiert" do
      cid = setup_campaign_with_members([{"alice", :spielleiter}])

      assert {:error, :not_authorized} = Recorder.start_for_owner("external-user", cid)
    end

    test "Nicht-existente Kampagne returnt :campaign_not_found" do
      assert {:error, :campaign_not_found} =
               Recorder.start_for_owner("alice", "no-such-campaign")
    end
  end

  describe "Worker.Repo.campaign_role/2 — direkter Membership-Check (Fix-Punkt)" do
    test "ersten Spielleiter zulassen (klassischer Fall)" do
      cid = setup_campaign_with_members([{"alice", :spielleiter}])

      assert :spielleiter == Worker.Repo.campaign_role(cid, "alice")
    end

    test "Multi-GM: beide Co-Spielleiter sind :spielleiter, egal wer 'erster' ist" do
      # Vor Issue #225 schlug der Recorder-Check für bob fehl wenn
      # first_spielleiter/1 alice zurückgab. campaign_role/2 ist Member-
      # spezifisch — egal welche Index-Order Mnesia liefert.
      cid = setup_campaign_with_members([{"alice", :spielleiter}, {"bob", :spielleiter}])

      assert :spielleiter == Worker.Repo.campaign_role(cid, "alice")
      assert :spielleiter == Worker.Repo.campaign_role(cid, "bob")
    end

    test ":spieler-Member returnt :spieler" do
      cid = setup_campaign_with_members([{"alice", :spielleiter}, {"charlie", :spieler}])

      assert :spieler == Worker.Repo.campaign_role(cid, "charlie")
    end

    test "Nicht-Member returnt nil" do
      cid = setup_campaign_with_members([{"alice", :spielleiter}])

      assert nil == Worker.Repo.campaign_role(cid, "external-user")
    end
  end
end
