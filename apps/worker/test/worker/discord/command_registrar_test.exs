defmodule Worker.Discord.CommandRegistrarTest do
  @moduledoc """
  Issue #1033: die Anmeldung der Slash-Commands bei Discord.

  In der Testumgebung gibt es keine Discord-Verbindung — der Bulk-Overwrite
  scheitert also zwangsläufig. Genau das macht den Fehlerpfad prüfbar, und der
  ist hier der eigentliche Gegenstand: eine gescheiterte Registrierung ist von
  außen **nicht** erkennbar (der Command taucht im Server einfach nie auf), und
  war damit ein Kandidat für die Silent-Failure-Klasse, gegen die #1008 die
  übrigen Discord-Fehlerklassen eingeführt hat.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Discord.{CommandRegistrar, Consumer}
  alias Worker.Schema.Builder

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp configured_campaign(cid, guild) do
    Builder.write!(Builder.campaign(cid, name: "Kampagne #{cid}"))
    Builder.write!(Builder.campaign_discord_config(cid, guild_id: guild))
  end

  defp registration_errors do
    Worker.Repo.last_n_pipeline_errors()
    |> Enum.filter(&(&1.error_type == "command_registration_failed"))
  end

  test "ein Fehlschlag wird pro betroffener Kampagne sichtbar" do
    configured_campaign("c1", "42")
    configured_campaign("c2", "42")
    configured_campaign("c3", "99")

    assert :ok = CommandRegistrar.register_for_guild(42)

    errors = registration_errors()
    assert length(errors) == 2
    assert errors |> Enum.map(& &1.campaign_id) |> Enum.sort() == ["c1", "c2"]

    # Der Text muss den nächsten Schritt nennen — ein Fehlercode allein lässt
    # den GM allein (die #1008-Regel für diese Fehlerklasse).
    assert Enum.all?(errors, &(&1.message =~ "applications.commands"))
    assert Enum.all?(errors, &(&1.stage == "discord_commands"))
  end

  test "ohne Kampagne auf dieser Guild wird nichts gemeldet" do
    configured_campaign("c1", "99")

    assert :ok = CommandRegistrar.register_for_guild(42)

    assert [] = registration_errors()
  end

  test "Guild-ID als String funktioniert genauso" do
    configured_campaign("c1", "42")

    assert :ok = CommandRegistrar.register_for_guild("42")

    assert [_one] = registration_errors()
  end

  test "GUILD_AVAILABLE löst die Registrierung aus" do
    configured_campaign("c1", "42")

    assert :ok = Consumer.handle_event({:GUILD_AVAILABLE, %{id: 42}, nil})

    assert [_one] = registration_errors()
  end

  test "GUILD_CREATE ebenfalls — ein neu beigetretener Server bekommt die Commands" do
    configured_campaign("c1", "42")

    assert :ok = Consumer.handle_event({:GUILD_CREATE, %{id: 42}, nil})

    assert [_one] = registration_errors()
  end
end
