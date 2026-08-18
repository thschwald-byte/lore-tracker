defmodule Worker.Discord.BotGateTest do
  @moduledoc """
  Issue #1076: der Discord-Bot startete nach einem Boot ohne DNS nie mehr.

  Ursache war, dass `BotToken.usable?/0` Netzfehler und Token-Ablehnung auf
  dasselbe `false` kollabierte UND diese Prüfung genau einmal lief — beim
  Boot, als Torwächter für einen statischen Supervisor-Child. Real belegt am
  2026-08-18: vier `:nxdomain`-Fehlversuche des HubClients in den ersten
  Sekunden, danach lief alles außer Discord.

  Geprüft wird hier die Entscheidungs-Tabelle, weil genau sie den Defekt
  trägt. Der HTTP-Aufruf selbst bleibt ungetestet (er ist die Hülle); die
  Abbildung seiner Antworten liegt in `BotToken.classify/1` und hat einen
  eigenen Test.

  **Was dieser Test vom gelöschten `application_discord_bot_child_test.exs`
  erbt:** ein von Discord abgelehnter Token darf NIE zu einem Bot-Start
  führen. Das war der reale PR-Test-Fund aus #985 (Nostrum validiert den
  Token beim Start synchron und riss als Top-Level-Child den ganzen Worker
  mit). Die Lehre gilt unverändert — nur der Ort der Entscheidung hat sich
  verschoben.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.BotGate

  describe "decide/2 — was aus einem Prüf-Ergebnis folgt" do
    test "bestätigter Token startet den Bot" do
      assert BotGate.decide(:ok, 0) == :start
      assert BotGate.decide(:ok, 17) == :start
    end

    test "abgelehnter Token startet NIE — auch nicht nach vielen Versuchen (der #985-Fund)" do
      assert BotGate.decide(:rejected, 0) == {:idle, :rejected}
      assert BotGate.decide(:rejected, 42) == {:idle, :rejected}
    end

    test "kein Token -> Leerlauf, kein Start" do
      assert BotGate.decide(:no_token, 0) == {:idle, :no_token}
    end

    test "Netzfehler -> Wiederholung; das ist der ganze Punkt von #1076" do
      assert {:retry, delay, :nxdomain} = BotGate.decide({:network_error, :nxdomain}, 0)
      assert delay > 0
    end

    test "Netzfehler und Ablehnung fallen NICHT auf dasselbe Ergebnis zusammen" do
      # Der Defekt war genau diese Gleichsetzung: `usable?/0` lieferte für
      # beides `false`, und damit war ein Sekundenbruchteil ohne DNS
      # ununterscheidbar von einem falschen Token.
      assert {:retry, _, _} = BotGate.decide({:network_error, :timeout}, 0)
      assert {:idle, :rejected} = BotGate.decide(:rejected, 0)
    end

    test "der Grund des Netzfehlers reist mit (sonst steht im Log nur 'ging nicht')" do
      assert {:retry, _, {:http_status, 503}} =
               BotGate.decide({:network_error, {:http_status, 503}}, 2)
    end
  end

  describe "backoff_ms/1" do
    test "startet schnell — der DNS-Fall ist nach Sekunden geheilt" do
      assert BotGate.backoff_ms(0) <= 5_000
    end

    test "wächst monoton" do
      delays = Enum.map(0..6, &BotGate.backoff_ms/1)
      assert delays == Enum.sort(delays)
    end

    test "ist gedeckelt — ein tagelang gestörtes Discord darf den Log nicht fluten" do
      assert BotGate.backoff_ms(999) == BotGate.backoff_ms(6)
      assert BotGate.backoff_ms(999) <= 300_000
    end
  end

  describe "status/0" do
    test "liefert auch ohne je gesetzten Zustand eine brauchbare Map (Snapshot darf nie crashen)" do
      status = BotGate.status()
      assert is_map(status)
      assert is_binary(status["state"])
    end
  end
end
