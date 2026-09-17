defmodule Worker.Discord.VoiceSessionShutdownTest do
  @moduledoc """
  Issue #1053: die Voice-Sitzung muss ihr letztes Fenster wegschreiben dürfen.

  Ohne `shutdown:` in der `child_spec` gilt der OTP-Vorgabewert von 5000 ms.
  `terminate/2` schreibt in dieser Zeit das letzte Fenster weg — je Sprecher
  dekodieren, Stille einfügen, neu kodieren. Was nicht fertig wird, killt der
  Supervisor hart: bis zu ein volles Fenster aller Sprecher, am Ende **jeder**
  Aufnahme, sichtbar nur als fehlende Minute im Protokoll.

  Die 60 Sekunden aus `Recorder.stop_for_campaign/1` (#1011) sind die Wartezeit
  des **Aufrufers** und haben den Kill nie verhindert — zwei Fristen, die wie
  eine aussahen.

  Geprüft wird die `child_spec` selbst, nicht ein laufender Prozess: eine echte
  `VoiceSession` braucht einen verbundenen Discord-Bot. Die Kill-Frist ist aber
  genau hier festgelegt, und hier war sie vergessen.
  """
  use ExUnit.Case, async: true

  alias Worker.Discord.VoiceSession

  defp spec, do: VoiceSession.child_spec(%{guild_id: 4242, campaign_id: "c-1053"})

  test "die child_spec setzt eine eigene Abschaltfrist" do
    assert %{shutdown: ms} = spec()

    assert is_integer(ms),
           "ohne shutdown: gilt der OTP-Vorgabewert 5000 ms — genau der #1053-Defekt"
  end

  test "die Frist ist deutlich grösser als der OTP-Vorgabewert" do
    # 5000 ist der Wert, unter dem das letzte Fenster verloren ging. Alles,
    # was ihn nicht klar überschreitet, hätte den Defekt nicht behoben.
    assert spec()[:shutdown] > 5_000
  end

  test "die Warnschwelle liegt UNTER der Abschaltfrist" do
    # Der eigentliche Fund von #1053: `log_flush_duration/3` warnt ab
    # `discord_flush_slow_ms` — und diese Schwelle lag bei genau 5000 ms,
    # also exakt dort, wo der Supervisor bereits gekillt hatte. Die Warnung
    # konnte per Konstruktion nie geschrieben werden.
    #
    # Ein Wächter, dessen Schwelle jenseits der Grenze liegt, an der das
    # Beobachtete aufhört zu existieren, meldet nie etwas — und wird genau
    # deshalb für beruhigend gehalten (CLAUDE.md, „Ein Wächter, der nie
    # anschlägt, ist unbewiesen").
    warnung = Worker.Settings.get(:discord_flush_slow_ms)
    frist = spec()[:shutdown]

    assert warnung < frist,
           "Warnschwelle #{warnung}ms >= Abschaltfrist #{frist}ms — die Warnung kann nie feuern"
  end

  test "die Frist lässt dem übrigen Stop-Pfad Luft" do
    # Nach dem Beenden der Voice-Sitzung finalisiert `Recorder` noch den
    # AudioBuffer, und alles zusammen läuft im 60-Sekunden-Budget von
    # `stop_for_campaign/1`. Eine Frist, die das Budget ausschöpft, liesse
    # dafür nichts übrig — dann stürbe der Aufrufer an seiner eigenen Frist.
    assert spec()[:shutdown] < 60_000
  end

  test "restart: :transient bleibt unberührt" do
    # Ein geplanter Stop ruft `GenServer.stop/1` mit `:normal` und darf keinen
    # Neustart auslösen; nur ein abnormaler Exit (Gateway-Abbruch, Decode-
    # Crash) soll die Sitzung wiederbeleben.
    assert spec()[:restart] == :transient
  end
end
