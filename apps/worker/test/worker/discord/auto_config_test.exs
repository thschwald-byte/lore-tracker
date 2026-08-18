defmodule Worker.Discord.AutoConfigTest do
  @moduledoc """
  Issue #1081: die Entscheidung, ob und wie eine Kampagne beim ersten
  `/lore start` an einen Server gebunden wird. Pur — ohne Nostrum, ohne Mnesia.
  """
  use ExUnit.Case, async: true

  alias Worker.Discord.AutoConfig

  defp campaign(guild, channel) do
    %{id: "c-1", name: "Testrunde", discord_guild_id: guild, discord_voice_channel_id: channel}
  end

  describe "decide/3" do
    test "nicht eingerichtet + Aufrufer im Sprachkanal → einrichten" do
      assert {:ok, {:configure, "g-1", "v-9"}} =
               AutoConfig.decide(campaign(nil, nil), "g-1", "v-9")
    end

    test "bereits auf diesen Server und Kanal eingerichtet → nichts tun" do
      assert {:ok, :already_configured} =
               AutoConfig.decide(campaign("g-1", "v-9"), "g-1", "v-9")
    end

    test "eingerichtet, Aufrufer sitzt nirgends → trotzdem nichts tun" do
      # Der GM startet vom Schreibtisch aus, während die Runde schon im Kanal
      # sitzt. Eine fertige Konfiguration braucht seinen Aufenthaltsort nicht.
      assert {:ok, :already_configured} =
               AutoConfig.decide(campaign("g-1", "v-9"), "g-1", nil)
    end

    test "gleicher Server, anderer Kanal → Kanal umstellen" do
      # Die Runde ist umgezogen. Harmlos, keine Rückfrage.
      assert {:ok, {:move_channel, "g-1", "v-neu"}} =
               AutoConfig.decide(campaign("g-1", "v-alt"), "g-1", "v-neu")
    end

    test "an einen ANDEREN Server gebunden → niemals still umhängen" do
      # Das würde die Aufnahme in der anderen Runde abklemmen, ohne dass es
      # dort jemand merkt. Der wichtigste Fall dieses Moduls.
      assert {:error, {:bound_elsewhere, "g-alt"}} =
               AutoConfig.decide(campaign("g-alt", "v-1"), "g-neu", "v-9")
    end

    test "fremder Server gewinnt auch dann, wenn der Aufrufer nirgends sitzt" do
      assert {:error, {:bound_elsewhere, "g-alt"}} =
               AutoConfig.decide(campaign("g-alt", "v-1"), "g-neu", nil)
    end

    test "nicht eingerichtet + Aufrufer in keinem Kanal → nicht raten" do
      assert {:error, :not_in_voice} = AutoConfig.decide(campaign(nil, nil), "g-1", nil)
    end

    test "ohne Guild (Direktnachricht) → nichts zu entscheiden" do
      assert {:error, :not_in_voice} = AutoConfig.decide(campaign(nil, nil), nil, "v-9")
    end

    test "leere Strings zählen wie nicht gesetzt" do
      # Der Reset-Pfad aus #985 schreibt ""/"" statt zu löschen.
      assert {:ok, {:configure, "g-1", "v-9"}} = AutoConfig.decide(campaign("", ""), "g-1", "v-9")
    end

    test "Integer-IDs (Nostrum) und String-IDs (Mnesia) sind gleichwertig" do
      assert {:ok, :already_configured} =
               AutoConfig.decide(campaign("42", "99"), 42, 99)
    end
  end

  describe "voice_channel_of/2" do
    @states [
      %{user_id: 111, channel_id: 900},
      %{user_id: 222, channel_id: 901},
      # Kanal verlassen: channel_id nil
      %{user_id: 333, channel_id: nil}
    ]

    test "findet den Kanal des Aufrufers" do
      assert "900" = AutoConfig.voice_channel_of(@states, "111")
      assert "901" = AutoConfig.voice_channel_of(@states, 222)
    end

    test "wer den Kanal verlassen hat, sitzt nirgends" do
      assert nil == AutoConfig.voice_channel_of(@states, "333")
    end

    test "unbekannter User, leere Liste, Müll → nil statt Absturz" do
      assert nil == AutoConfig.voice_channel_of(@states, "999")
      assert nil == AutoConfig.voice_channel_of([], "111")
      assert nil == AutoConfig.voice_channel_of(nil, "111")
      assert nil == AutoConfig.voice_channel_of(@states, nil)
    end
  end
end
