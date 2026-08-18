defmodule Worker.Repo.CampaignsForGuildTest do
  @moduledoc """
  Issue #1033: die Rückwärts-Auflösung Guild → Kampagnen. Der Web-Knopf kennt
  seine Kampagne aus der URL; ein Slash-Command kennt nur die Guild.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Schema.Builder

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp config(cid, name, guild, opts \\ []) do
    Builder.write!(Builder.campaign(cid, name: name))

    Builder.write!(
      Builder.campaign_discord_config(cid,
        guild_id: guild,
        voice_channel_id: Keyword.get(opts, :voice_channel_id, "chan-1")
      )
    )
  end

  test "findet die Kampagnen einer Guild" do
    config("c1", "Erste", "g-100")
    config("c2", "Zweite", "g-100")
    config("c3", "Andere", "g-999")

    assert ["Erste", "Zweite"] =
             "g-100" |> Worker.Repo.campaigns_for_guild() |> Enum.map(& &1.name)
  end

  test "sortiert nach Namen — die Antwort im Chat soll stabil sein" do
    config("c1", "Zulu", "g-100")
    config("c2", "Alpha", "g-100")

    assert ["Alpha", "Zulu"] =
             "g-100" |> Worker.Repo.campaigns_for_guild() |> Enum.map(& &1.name)
  end

  test "der Voice-Channel reist mit" do
    config("c1", "Erste", "g-100", voice_channel_id: "voice-42")

    assert [%{voice_channel_id: "voice-42"}] = Worker.Repo.campaigns_for_guild("g-100")
  end

  test "unbekannte Guild ergibt eine leere Liste, keinen Fehler" do
    config("c1", "Erste", "g-100")

    assert [] = Worker.Repo.campaigns_for_guild("g-nichts")
  end

  test "leere und ungültige Eingaben ergeben eine leere Liste" do
    config("c1", "Erste", "g-100")

    assert [] = Worker.Repo.campaigns_for_guild("")
    assert [] = Worker.Repo.campaigns_for_guild("   ")
    assert [] = Worker.Repo.campaigns_for_guild(nil)
    assert [] = Worker.Repo.campaigns_for_guild(123)
  end

  test "eine zurückgesetzte Config (leere Guild) taucht nirgends auf" do
    # Reset-Pfad aus #985: der GM leert beide Felder, die Row bleibt mit ""/"".
    Builder.write!(Builder.campaign("c1", name: "Erste"))
    Builder.write!(Builder.campaign_discord_config("c1", guild_id: "", voice_channel_id: ""))

    assert [] = Worker.Repo.campaigns_for_guild("")
  end

  describe "campaigns_with_guild_for/1 (#1081)" do
    test "liefert die Kampagnen des Mitglieds samt gebundener Guild" do
      config("c1", "Gebunden", "g-100")
      Builder.write!(Builder.campaign("c2", name: "Ungebunden"))

      Enum.each(["c1", "c2"], fn cid ->
        Builder.write!(Builder.campaign_member(cid, "did-me", role: :spieler))
      end)

      by_name =
        "did-me" |> Worker.Repo.campaigns_with_guild_for() |> Map.new(&{&1.name, &1})

      assert by_name["Gebunden"].discord_guild_id == "g-100"
      # Eine noch nicht eingerichtete Kampagne MUSS dabei sein — sie ist der
      # Ausgangspunkt der Autokonfiguration.
      assert by_name["Ungebunden"].discord_guild_id == nil
      assert map_size(by_name) == 2
    end

    test "Rolle spielt keine Rolle — Mitgliedschaft genügt (#1082)" do
      config("c1", "Als Spieler", "g-100")
      Builder.write!(Builder.campaign_member("c1", "did-me", role: :spieler))

      assert [%{name: "Als Spieler"}] = Worker.Repo.campaigns_with_guild_for("did-me")
    end

    test "fremde Kampagnen tauchen nicht auf" do
      config("c1", "Nicht meine", "g-100")
      Builder.write!(Builder.campaign_member("c1", "did-other", role: :spielleiter))

      assert [] = Worker.Repo.campaigns_with_guild_for("did-me")
    end

    test "ungültige Eingabe ergibt eine leere Liste" do
      assert [] = Worker.Repo.campaigns_with_guild_for(nil)
      assert [] = Worker.Repo.campaigns_with_guild_for(123)
    end
  end

  test "eine Config ohne Kampagne wird übersprungen statt zurückgegeben" do
    # Config-Rows werden nie gelöscht; eine gelöschte Kampagne lässt ihre Row
    # stehen. Ein Treffer darauf wäre eine Kampagne, die es nicht gibt.
    Builder.write!(Builder.campaign_discord_config("verwaist", guild_id: "g-100"))
    config("c1", "Echte", "g-100")

    assert ["Echte"] = "g-100" |> Worker.Repo.campaigns_for_guild() |> Enum.map(& &1.name)
  end
end
