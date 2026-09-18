defmodule Worker.Discord.FlushIdentitaetTest do
  @moduledoc """
  Issue #1052: die Identität eines Clips kommt aus den Frames, nicht aus einer
  beim Speichern frisch geholten Tabelle.

  Jeder Frame trägt seine Identität seit #988 mit sich, aufgelöst im Moment des
  Empfangs. Der Speicherpfad holte bis #1052 trotzdem `Voice.get_ssrc_map/1`
  **beim Schreiben** erneut — also nach dem Fenster, das er gerade wegschreibt:

  - War die Voice-Verbindung in diesem Moment tot, war die Tabelle leer und das
    **ganze Fenster** verloren (bis zu eine Minute, alle Sprecher) — mit einer
    Logzeile und ohne Eintrag in `/admin/errors`.
  - War sie erneuert, konnte eine neu vergebene Kennung Audio unter **fremder
    Identität** speichern, also unter fremder Einwilligung.

  Die Warnung davor stand wörtlich als Kommentar an der Paket-Stelle, während
  der Speicherpfad genau das weiterhin tat.

  Geprüft wird der Quelltext: der Flush läuft nur mit verbundenem Discord-Bot,
  und der Defekt war nie ein Rechenfehler, sondern die **Herkunft** einer
  Angabe.
  """
  use ExUnit.Case, async: true

  @flush "lib/worker/discord/flush.ex"

  setup do
    %{quelle: File.read!(@flush)}
  end

  describe "Herkunft der Identität" do
    test "der Schreibpfad fragt Nostrum nicht mehr nach der Zuordnung", %{quelle: q} do
      refute q =~ "NostrumSafe.ssrc_map",
             "Die Tabelle wird beim Speichern wieder abgefragt — nach einem " <>
               "Voice-Reconnect ist sie leer oder anders belegt (#1052)."
    end

    test "die Zuordnung wird aus den Frames abgeleitet", %{quelle: q} do
      assert q =~ "identitaeten_aus_frames"
    end

    test "jeder Frame trägt beides: Kennung und Identität", %{quelle: q} do
      # Die Ableitung steht und fällt damit, dass beide Felder am Frame sind.
      assert q =~ "& &1.ssrc" and q =~ "& &1.did"
    end
  end

  describe "Mehrdeutigkeit" do
    test "ein doppelt belegter SSRC wird gemeldet statt geraten", %{quelle: q} do
      # Discord vergibt die Kennung nach einem Reconnect neu. Fällt eine neue
      # mit einer alten zusammen, wäre jede Zuordnung geraten — und Audio unter
      # fremder Identität zu speichern hiesse, es unter fremder EINWILLIGUNG zu
      # speichern. Das ist der schwerste denkbare Fehler an dieser Stelle.
      assert q =~ "report_ambiguous_ssrc"
    end

    test "der Vorfall landet in /admin/errors, nicht nur im Log" do
      quelle = File.read!("lib/worker/discord/voice_errors.ex")

      # Der alte Verwurf war der EINZIGE Fehlerpfad im Flush ohne Eintrag dort:
      # ein verlorener Clip stand nur im Log und war für den Spielleiter
      # ununterscheidbar von „hat keiner gesprochen".
      assert quelle =~ "def report_ambiguous_ssrc"
      assert quelle =~ ":ambiguous_ssrc"
      assert quelle =~ "publish_pipeline_error"
    end

    test "der Text nennt Ursache und Folge, nicht nur den Fehlernamen" do
      quelle = File.read!("lib/worker/discord/voice_errors.ex")

      assert quelle =~ "Verbindungsabbruch im Sprachkanal"
      assert quelle =~ "fremder Einwilligung"
    end
  end

  describe "die Fehlerklasse ist im Hub lesbar" do
    test "sie hat eine deutsche Beschriftung" do
      quelle = File.read!("../hub/lib/hub_web/live/admin_errors_live.ex")

      # Ohne `type_label` stünde in /admin/errors der rohe Code — die
      # Discord-Klassen hatten genau dieses Problem schon einmal (#1008).
      assert quelle =~ ~s|type_label("ambiguous_ssrc")|
    end
  end
end
