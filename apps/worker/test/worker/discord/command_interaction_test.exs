defmodule Worker.Discord.CommandInteractionTest do
  @moduledoc """
  Issue #1033: die Schranken und Antwortpfade von `/lore` — ohne
  Discord-Verbindung.

  Geprüft wird `execute/4`, weil dort die Autorisierung sitzt. `handle/1`
  liefert nur `:ok`; der Text (und damit die eigentliche Aussage) ginge im Test
  verloren.

  **Die wichtigste Zusage hier:** ein Slash-Command kommt am Hub vorbei, und
  `Recorder.stop_for_campaign/1` hat keine eigene Rollen-Prüfung. Ohne die
  Schranke in diesem Modul könnte jeder Server-Teilnehmer eine fremde Aufnahme
  beenden — und im Discord-Server sitzen regelmäßig Leute, die mit der Runde
  nichts zu tun haben.

  Issue #1082: die Schranke verläuft an der **Mitgliedschaft**, nicht an der
  Spielleiter-Rolle. Wer am Tisch sitzt, darf die Aufnahme bedienen; wer nicht
  dazugehört, nicht.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Discord.CommandInteraction
  alias Worker.Schema.Builder

  @guild "693035395352625183"

  setup do
    clear_all_tables!()
    mat_pid = ensure_materializer!()

    # `status` und `stop` fragen den Recorder. Ohne ihn stirbt der Aufruf mit
    # `exit :noproc` — den fängt `execute/4` zwar ab (s. `safe/1`), aber dann
    # prüfte der Test den Ausweichpfad statt der Sache.
    ensure_started(Worker.Recording.Recorder, fn ->
      Worker.Recording.Recorder.start_link([])
    end)

    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp campaign_on_guild(name, opts) do
    cid = "camp-cmd-#{System.unique_integer([:positive])}"
    guild = Keyword.get(opts, :guild, @guild)

    Builder.write!(Builder.campaign(cid, name: name))

    # `guild: nil` = die Kampagne ist noch an keinen Server gebunden (der
    # Ausgangspunkt der Autokonfiguration, #1081).
    if guild do
      Builder.write!(Builder.campaign_discord_config(cid, guild_id: guild))
    end

    Enum.each(Keyword.get(opts, :members, []), fn {did, role} ->
      Builder.write!(Builder.campaign_member(cid, did, role: role))
    end)

    cid
  end

  describe "Autorisierung" do
    test "ein Mitspieler darf die Aufnahme stoppen (seit #1082)" do
      campaign_on_guild("Skandal", members: [{"gm", :spielleiter}, {"spieler", :spieler}])

      text = CommandInteraction.execute(@guild, "spieler", :stop, nil)

      refute text =~ "kein Mitglied"
      assert text =~ "keine Aufnahme"
    end

    test "ein Fremder ohne jede Mitgliedschaft darf nicht starten" do
      campaign_on_guild("Skandal", members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "fremder", :start, nil)

      assert text =~ "kein Mitglied"
      assert text =~ "Skandal"
    end

    test "ein Fremder darf auch nicht stoppen" do
      campaign_on_guild("Skandal", members: [{"gm", :spielleiter}])

      assert CommandInteraction.execute(@guild, "fremder", :stop, nil) =~ "kein Mitglied"
    end

    test "status darf jeder — auch ohne Mitgliedschaft" do
      campaign_on_guild("Skandal", members: [{"gm", :spielleiter}])

      # Transparenz-Seite der Einwilligung: wer im Kanal sitzt, darf wissen,
      # ob aufgezeichnet wird.
      text = CommandInteraction.execute(@guild, "irgendwer", :status, nil)

      refute text =~ "Nur die Spielleitung"
      assert text =~ "keine Aufnahme"
    end
  end

  describe "Kampagnen-Auflösung über die Guild" do
    test "kein Eintrag für diesen Server" do
      text = CommandInteraction.execute("999999999", "gm", :status, nil)

      assert text =~ "keine Kampagne konfiguriert"
    end

    test "zwei Kampagnen auf einem Server verlangen eine Angabe" do
      campaign_on_guild("Erste", members: [{"gm", :spielleiter}])
      campaign_on_guild("Zweite", members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :status, nil)

      assert text =~ "Mehrere Kampagnen"
      assert text =~ "Erste"
      assert text =~ "Zweite"
    end

    test "mit Angabe wird die gemeinte gewählt" do
      campaign_on_guild("Erste", members: [{"gm", :spielleiter}])
      campaign_on_guild("Zweite", members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :status, "zweite")

      assert text =~ "Zweite"
      refute text =~ "Mehrere Kampagnen"
    end

    test "eine Kampagne auf einer ANDEREN Guild wird nicht mitgezählt" do
      campaign_on_guild("Hier", members: [{"gm", :spielleiter}])
      campaign_on_guild("Woanders", guild: "111111111", members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :status, nil)

      assert text =~ "Hier"
      refute text =~ "Mehrere Kampagnen"
    end
  end

  describe "stop ohne laufende Aufnahme" do
    test "sagt das, statt einen Erfolg zu behaupten" do
      campaign_on_guild("Skandal", members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :stop, nil)

      assert text =~ "keine Aufnahme"
      refute text =~ "beendet"
    end
  end

  describe "Autokonfiguration beim ersten Start (#1081)" do
    test "noch nicht eingerichtet und Aufrufer in keinem Sprachkanal → sagt, was zu tun ist" do
      # Ohne Nostrum liefert `NostrumSafe.voice_states/1` eine leere Liste —
      # derselbe Zustand wie „sitzt in keinem Kanal". Der Bot darf dann keinen
      # Kanal erraten.
      campaign_on_guild("Neue Runde", guild: nil, members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :start, "Neue Runde")

      assert text =~ "noch nicht eingerichtet"
      assert text =~ "Geh in den Kanal"
    end

    test "an einen anderen Server gebunden → wird nicht still umgehängt" do
      campaign_on_guild("Fremde Runde", guild: "111111111", members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :start, "Fremde")

      assert text =~ "anderen Discord-Server"
      assert text =~ "111111111"
      refute text =~ "eingetragen"
    end

    test "eine noch nicht eingerichtete eigene Kampagne steht überhaupt zur Auswahl" do
      # Ohne diesen Pfad wäre die Autokonfiguration unerreichbar: die Kampagne
      # hängt an keiner Guild, also findet `campaigns_for_guild/1` sie nie.
      campaign_on_guild("Ungebunden", guild: nil, members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "gm", :start, "Ungebunden")

      refute text =~ "keine Kampagne konfiguriert"
    end

    test "Nicht-Mitglieder sehen fremde ungebundene Kampagnen nicht" do
      campaign_on_guild("Geheim", guild: nil, members: [{"gm", :spielleiter}])

      text = CommandInteraction.execute(@guild, "fremder", :start, "Geheim")

      assert text =~ "keine Kampagne konfiguriert"
    end
  end

  describe "handle/1" do
    test "ein Nicht-lore-Command ist ein stiller No-op" do
      assert :ok = CommandInteraction.handle(%{data: %{name: "andere"}, guild_id: 1})
    end

    test "eine Interaction ohne Daten crasht nicht" do
      assert :ok = CommandInteraction.handle(%{})
    end
  end
end
