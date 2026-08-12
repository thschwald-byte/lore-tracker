defmodule Worker.Discord.AutoMemberTest do
  @moduledoc """
  Issue #988: Einwilligung im Voice-Kanal macht zum Mitspieler. Getestet werden
  die Entscheidungs- und Fehlerpfade OHNE Discord-Verbindung — `Nostrum.Api` ist
  hier nicht erreichbar, der Profil-Abruf fällt also auf die Discord-ID als
  Anzeigename zurück (genau der Degradations-Pfad, der auch produktiv bei
  Rate-Limit/Netzfehler greift).
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Discord.AutoMember
  alias Worker.Schema.Builder

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp campaign_with(members) do
    cid = "camp-automember-#{System.unique_integer([:positive])}"
    Builder.write!(Builder.campaign(cid, name: "Auto-Member-Test"))

    Enum.each(members, fn {did, role} ->
      Builder.write!(Builder.campaign_member(cid, did, role: role))
    end)

    cid
  end

  test "Nicht-Mitglied wird aufgenommen (Rolle :spieler)" do
    cid = campaign_with([{"gm", :spielleiter}])

    assert :ok = AutoMember.ensure(cid, "neuer-gast")
    assert Worker.Repo.campaign_role(cid, "neuer-gast") == :spieler
  end

  test "bestehendes Mitglied bleibt unangetastet (idempotent)" do
    cid = campaign_with([{"gm", :spielleiter}, {"alice", :spieler}])

    assert :ok = AutoMember.ensure(cid, "alice")
    assert Worker.Repo.campaign_role(cid, "alice") == :spieler
  end

  test "ein Spielleiter wird NICHT auf :spieler zurückgestuft" do
    cid = campaign_with([{"gm", :spielleiter}])

    assert :ok = AutoMember.ensure(cid, "gm")
    assert Worker.Repo.campaign_role(cid, "gm") == :spielleiter
  end

  test "mehrfacher Aufruf erzeugt kein Chaos (Doppel-Einwilligung im selben Fenster)" do
    cid = campaign_with([{"gm", :spielleiter}])

    assert :ok = AutoMember.ensure(cid, "doppelt")
    assert :ok = AutoMember.ensure(cid, "doppelt")
    assert Worker.Repo.campaign_role(cid, "doppelt") == :spieler
  end

  test "Integer-Discord-ID (so kommt sie aus Nostrum) wird akzeptiert" do
    cid = campaign_with([{"gm", :spielleiter}])

    assert :ok = AutoMember.ensure(cid, 123_456_789)
    assert Worker.Repo.campaign_role(cid, "123456789") == :spieler
  end

  test "unbekannte Kampagne -> kein Crash (best-effort, Aufnahme läuft weiter)" do
    assert :ok = AutoMember.ensure("gibt-es-nicht", "irgendwer")
  end

  test "ohne erreichbare Discord-API bleibt die ID als Anzeigename (statt gar keiner Aufnahme)" do
    cid = campaign_with([{"gm", :spielleiter}])

    assert :ok = AutoMember.ensure(cid, "ohne-profil")

    # Aufgenommen wurde er trotzdem — das ist der Punkt: ein Mitglied ohne
    # schönen Namen ist besser als ein verlorener Teilnehmer.
    assert Worker.Repo.campaign_role(cid, "ohne-profil") == :spieler
    assert %{display_name: "ohne-profil"} = Worker.Repo.get_user("ohne-profil")
  end
end
