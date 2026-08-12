defmodule Worker.Discord.ConsentButtonTest do
  @moduledoc """
  Issue #1005: der Klick-Weg. Die Negativfälle sind hier die eigentliche Arbeit —
  Discord-Nachrichten bleiben liegen, also ist der Klick auf die Nachricht einer
  **früheren Aufnahme** der Normalfall, nicht der Ausnahmefall. Würde er
  durchgehen, entstünde eine Zustimmung für eine Sitzung, von der die Person
  nichts weiß.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.ConsentButton
  alias Worker.Recording.ConsentPhrase

  @session "019ff4ad-8674-7a27-9a31-e8f875c02595"
  @other_session "019ff000-0000-7000-8000-000000000000"

  defp version, do: ConsentPhrase.version()

  describe "custom_id/2 und parse_custom_id/1" do
    test "Rundreise für beide Aktionen" do
      for action <- [:grant, :revoke] do
        id = ConsentButton.custom_id(action, @session)
        assert {:ok, ^action, v, @session} = ConsentButton.parse_custom_id(id)
        assert v == version()
      end
    end

    test "bleibt unter dem Discord-Limit von 100 Zeichen" do
      assert String.length(ConsentButton.custom_id(:grant, @session)) <= 100
      assert String.length(ConsentButton.custom_id(:revoke, @session)) <= 100
    end

    test "Müll wird nicht geraten" do
      for bad <- [
            "",
            "audio_consent",
            "audio_consent|grant",
            "audio_consent|grant|v1",
            "audio_consent|bogus|v1|#{@session}",
            "fremdes_feature|grant|v1|#{@session}",
            "audio_consent|grant||#{@session}",
            "audio_consent|grant|v1|",
            nil,
            42
          ] do
        assert ConsentButton.parse_custom_id(bad) == {:error, :malformed},
               "wurde fälschlich geparst: #{inspect(bad)}"
      end
    end
  end

  describe "verdict_for_click/3 — die Gültigkeitsentscheidung" do
    test "gültiger Klick auf die laufende Sitzung" do
      parsed = ConsentButton.parse_custom_id(ConsentButton.custom_id(:grant, @session))
      assert ConsentButton.verdict_for_click(parsed, version(), @session) == {:accept, :grant}
    end

    test "Widerruf-Klick wird als solcher erkannt" do
      parsed = ConsentButton.parse_custom_id(ConsentButton.custom_id(:revoke, @session))
      assert ConsentButton.verdict_for_click(parsed, version(), @session) == {:accept, :revoke}
    end

    test "Klick auf die Nachricht einer FRÜHEREN Aufnahme wird abgelehnt" do
      # Der wichtigste Negativfall: Discord-Nachrichten bleiben liegen.
      parsed = ConsentButton.parse_custom_id(ConsentButton.custom_id(:grant, @other_session))

      assert ConsentButton.verdict_for_click(parsed, version(), @session) ==
               {:reject, :stale_session}
    end

    test "Klick mit altem Einwilligungs-Wortlaut wird abgelehnt" do
      parsed = {:ok, :grant, "v0", @session}

      assert ConsentButton.verdict_for_click(parsed, version(), @session) ==
               {:reject, :stale_version}
    end

    test "kaputte custom_id wird abgelehnt" do
      assert ConsentButton.verdict_for_click({:error, :malformed}, version(), @session) ==
               {:reject, :malformed}

      assert ConsentButton.verdict_for_click(:unerwartet, version(), @session) ==
               {:reject, :malformed}
    end

    test "Version wird VOR der Session geprüft (beide falsch → Version gewinnt)" do
      # Reihenfolge festgenagelt, damit die Rückmeldung an den Nutzer stabil ist.
      parsed = {:ok, :grant, "v0", @other_session}

      assert ConsentButton.verdict_for_click(parsed, version(), @session) ==
               {:reject, :stale_version}
    end
  end

  describe "payload/2 — schlichte Map, kein Component-Struct" do
    test "enthält zwei Buttons mit den richtigen custom_ids" do
      payload = ConsentButton.payload(@session, "Testrunde")

      assert [row] = payload[:components]
      assert row.type == 1
      assert [grant, revoke] = row.components

      assert grant.custom_id == ConsentButton.custom_id(:grant, @session)
      assert revoke.custom_id == ConsentButton.custom_id(:revoke, @session)
      assert grant.type == 2 and revoke.type == 2
    end

    test "kein Feld ist nil (Discord-Body soll keine null-Felder tragen)" do
      # Der Grund, warum die Map handgebaut ist: Nostrums Component-Struct
      # serialisiert alle 18 Felder inkl. null, und das ist ungetestetes Terrain.
      [row] = ConsentButton.payload(@session)[:components]

      for button <- row.components, {key, value} <- button do
        refute is_nil(value), "#{key} ist nil"
      end

      refute Enum.any?(row, fn {_k, v} -> is_nil(v) end)
    end

    test "Text nennt beide Wege, die Konsequenz und den Widerruf ohne falsche Zusage" do
      text = ConsentButton.content("Testrunde")

      assert text =~ "Testrunde"
      assert text =~ "Ich stimme zu"
      assert text =~ ConsentPhrase.canonical_phrase()
      assert text =~ "nicht gespeichert"
      assert text =~ "widerrufen"
      # Wichtig: kein Löschversprechen — der Widerruf beendet nur die Aufnahme.
      assert text =~ "nicht gelöscht"
    end

    test "ohne Kampagnennamen bleibt der Text sinnvoll" do
      text = ConsentButton.content(nil)
      refute text =~ "für die Kampagne"
      assert text =~ "wird aufgezeichnet"
    end
  end

  describe "Rückmeldungs-Texte" do
    test "Zustimmung und Widerruf werden unterschiedlich bestätigt" do
      assert ConsentButton.ack_text(:grant) =~ "gespeichert"
      assert ConsentButton.ack_text(:revoke) =~ "nicht mehr aufgezeichnet"
      # Auch hier: keine Löschzusage.
      assert ConsentButton.ack_text(:revoke) =~ "unberührt"
    end

    test "jeder Ablehnungsgrund hat einen eigenen Text" do
      for reason <- [:malformed, :stale_version, :stale_session] do
        text = ConsentButton.reject_text(reason)
        assert is_binary(text) and text != ""
      end

      assert ConsentButton.reject_text(:stale_session) =~ "früheren Aufnahme"
    end
  end
end
