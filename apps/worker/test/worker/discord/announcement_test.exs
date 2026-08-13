defmodule Worker.Discord.AnnouncementTest do
  @moduledoc """
  Issue #989: die gesprochene Consent-Ansage beim Discord-Voice-Join.

  Gepinnt: der Ansagetext (inkl. Kampagnenname, Fallback ohne Namen,
  Whitespace-Kollaps, Längen-Deckel), das `:piper_not_configured`-Verhalten auf
  einem Worker ohne TTS, der Cache (zweiter Join einer Kampagne erzeugt NICHT
  neu), die zwei Fehlerpfade (Exit≠0 **und** Exit 0 ohne Ausgabedatei — die
  Silent-Failure-Variante) und die **Shell-Injection-Fläche**: der Kampagnenname
  ist GM-getippter Freitext und geht in einen Subprocess-Aufruf.

  Läuft ohne echtes piper: ein **Fake-piper** (Shell-Skript) protokolliert den
  empfangenen stdin-Text und die Aufrufzahl. Damit ist der Injection-Test kein
  „hoffentlich"-Argument, sondern eine Zusicherung, die auch im CI (kein piper,
  kein ffmpeg) mitläuft.
  """

  use ExUnit.Case, async: false

  alias Worker.Discord.Announcement

  # „Lorspai" ist die phonetische Schreibweise für die TTS (#989-Live-Abnahme:
  # „LoreSpy" wurde deutsch als „Schpei" ausgesprochen; `sp-` am Wortanfang wird
  # im Deutschen zu „schp", in der Wortmitte nicht).
  @prefix "Der Lorspai hat den Kanal betreten und nimmt die Sitzung"

  setup do
    tmp = Path.join(System.tmp_dir!(), "ansage-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    # Beweis-Dateien des Fake-piper: jede Zeile ein Aufruf (stdin-Text).
    seen = Path.join(tmp, "seen.txt")
    canary = Path.join(tmp, "CANARY_PWNED")

    on_exit(fn ->
      File.rm_rf(tmp)
      # Cache-Dir leeren, damit ein Lauf den nächsten nicht über den Cache füttert.
      File.rm_rf(cache_dir())
      Worker.Settings.put(:piper_bin, nil)
      Worker.Settings.put(:piper_model, nil)
    end)

    File.rm_rf(cache_dir())
    {:ok, tmp: tmp, seen: seen, canary: canary}
  end

  # Der Cache-Dir, den `Announcement` benutzt (gleiche Ableitung: mnesia_dir/tts).
  defp cache_dir do
    :mnesia.system_info(:directory) |> to_string() |> Path.join("tts")
  rescue
    _ -> Path.join(System.tmp_dir!(), "lore-tts")
  end

  # Fake-piper: liest stdin, hängt den Text an `seen` an, schreibt eine
  # nicht-leere „WAV"-Datei an --output_file. `mode` steuert die Fehlerfälle.
  defp fake_piper!(tmp, seen, mode) do
    path = Path.join(tmp, "fake_piper.sh")

    body = """
    #!/bin/sh
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --output_file) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cat >> "#{seen}"
    printf '\\n' >> "#{seen}"
    #{case mode do
      :ok -> ~s(printf 'RIFFFAKEWAV' > "$out"\nexit 0)
      :exit_0_no_file -> "exit 0"
      :fail -> ~s(echo "piper kaputt" >&2\nexit 3)
    end}
    """

    File.write!(path, body)
    File.chmod!(path, 0o755)
    Worker.Settings.put(:piper_bin, path)
    Worker.Settings.put(:piper_model, Path.join(tmp, "stimme.onnx"))
    path
  end

  defp seen_lines(seen) do
    case File.read(seen) do
      {:ok, c} -> c |> String.split("\n") |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  end

  describe "text_for/1 — der Ansagetext" do
    test "nennt die Kampagne beim Namen (die Kernanforderung aus #989)" do
      assert Announcement.text_for("Romeo und Julia") =~
               "#{@prefix} für die Kampagne Romeo und Julia auf."
    end

    test "ohne Namen: neutrale Fassung statt eines Lochs im Satz" do
      expected = "#{@prefix} für diese Kampagne auf."
      assert Announcement.text_for(nil) =~ expected
      assert Announcement.text_for("") =~ expected
      assert Announcement.text_for("   \n  ") =~ expected
    end

    test "Whitespace + Zeilenumbrüche werden kollabiert (piper liest Zeilen als Sätze)" do
      assert Announcement.text_for("Die\n\nwilde   Runde") =~
               "#{@prefix} für die Kampagne Die wilde Runde auf."
    end

    test "überlanger Name wird gedeckelt (keine Minuten-Ansage)" do
      text = Announcement.text_for(String.duplicate("Ka", 200))
      # Deckel gilt für den NAMEN. Der Consent-Teil ist seit #1032 bedingt und
      # fehlt hier, weil niemand als offen übergeben wurde.
      assert String.length(text) < String.length(@prefix) + 120
    end

    # ─── #1002: die Bitte um Einwilligung ──────────────────────────

    test "ohne Offene endet die Eröffnung nach dem Kampagnennamen (Issue #1032)" do
      # Der Kern der Entscheidung: die Einwilligungs-Bitte hing vorher
      # UNBEDINGT dran und wurde auch dann vorgelesen, wenn längst alle
      # zugestimmt hatten — rund 10 der 17 Sekunden, jedes Mal.
      text = Announcement.text_for("Testrunde", [])

      assert text == "#{@prefix} für die Kampagne Testrunde auf."
      refute text =~ "Zustimmung"
      refute text =~ "Chat"
    end

    test "mit Offenen nennt sie die Namen und sagt einmal, wo man zustimmt" do
      text = Announcement.text_for("Testrunde", ["Kai", "Mira"])

      assert text =~ "für die Kampagne Testrunde auf."
      assert text =~ "Es fehlt die Zustimmung von Kai und Mira für die Audioaufnahme."
      assert text =~ "Bitte im Chat der Aufnahme zustimmen."
    end

    test "eine offene Person: Singular ohne Aufzählung" do
      assert Announcement.text_for("R", ["Kai"]) =~ "Zustimmung von Kai für die Audioaufnahme."
    end

    test "Offene ohne sprechbaren Namen: die ANZAHL bleibt erhalten" do
      # „Es fehlt wer" ist die Information, der Name ist Zugabe — ein Emoji-Nick
      # darf die Aussage nicht verschlucken.
      assert Announcement.text_for("R", ["🎲"]) =~ "Zustimmung einer Person"
      assert Announcement.text_for("R", ["🎲", "***"]) =~ "Zustimmung von 2 Personen"
    end

    test "Vorgabewert: text_for/1 verhält sich wie „niemand offen\"" do
      assert Announcement.text_for("Testrunde") == Announcement.text_for("Testrunde", [])
    end

    test "die Ansage bittet NICHT um den gesprochenen Satz" do
      # Issue #1005 setzte den Sprach-Weg aus (Akustik ist nicht
      # identitätsgebunden — Cross-Talk könnte einem Dritten eine Zustimmung
      # unterstellen), Issue #1032 hat ihn ausgebaut. Eine Ansage, die um etwas
      # bittet, das nichts auslöst, wäre schlimmer als keine: die Leute
      # sprechen, nichts passiert, die Spur fehlt hinterher.
      text = Announcement.text_for("Testrunde", ["Kai"])
      refute text =~ "sag jetzt"
      refute text =~ "Ich stimme der Aufnahme zu"
    end

    test "Sonderzeichen im Namen bleiben Text (kein Escaping-Artefakt im Satz)" do
      assert Announcement.text_for(~s(Toms 'wilde' Runde)) =~ ~s(Toms 'wilde' Runde)
    end
  end

  describe "wav_for_text/1 — Erzeugung, Cache, Fehler" do
    test "ohne piper-Settings: benannter Zustand, kein Crash" do
      Worker.Settings.put(:piper_bin, nil)
      Worker.Settings.put(:piper_model, nil)
      assert {:error, :piper_not_configured} = Announcement.wav_for_text("Test.")
    end

    test "leere Strings zählen als nicht konfiguriert (nicht als Pfad \"\")" do
      Worker.Settings.put(:piper_bin, "   ")
      Worker.Settings.put(:piper_model, "")
      assert {:error, :piper_not_configured} = Announcement.wav_for_text("Test.")
    end

    test "erzeugt die Datei und liefert ihren Pfad", %{tmp: tmp, seen: seen} do
      fake_piper!(tmp, seen, :ok)

      assert {:ok, path} = Announcement.wav_for_text("Eine Ansage.")
      assert File.exists?(path)
      assert File.stat!(path).size > 0
      assert seen_lines(seen) == ["Eine Ansage."]
    end

    test "zweiter Aufruf kommt aus dem Cache (kein zweiter piper-Lauf)", %{tmp: tmp, seen: seen} do
      fake_piper!(tmp, seen, :ok)
      text = "Zweimal dieselbe Ansage."

      assert {:ok, p1} = Announcement.wav_for_text(text)
      assert {:ok, p2} = Announcement.wav_for_text(text)
      assert p1 == p2
      # Genau EIN piper-Aufruf für zwei Anfragen.
      assert seen_lines(seen) == [text]
    end

    test "anderer Text (z.B. Kampagne umbenannt) → andere Datei", %{tmp: tmp, seen: seen} do
      fake_piper!(tmp, seen, :ok)

      assert {:ok, p1} = Announcement.wav_for_text(Announcement.text_for("Alter Name"))
      assert {:ok, p2} = Announcement.wav_for_text(Announcement.text_for("Neuer Name"))
      refute p1 == p2
      assert length(seen_lines(seen)) == 2
    end

    test "0-Byte-Datei ist KEIN Cache-Treffer (abgebrochener Vorlauf)", %{tmp: tmp, seen: seen} do
      fake_piper!(tmp, seen, :ok)
      text = "Kaputter Cache."
      {:ok, path} = Announcement.wav_for_text(text)

      File.write!(path, "")
      assert {:ok, ^path} = Announcement.wav_for_text(text)
      # Neu erzeugt → zweiter Aufruf.
      assert length(seen_lines(seen)) == 2
      assert File.stat!(path).size > 0
    end

    test "piper exit≠0 → sichtbarer Fehler mit Ausgabe", %{tmp: tmp, seen: seen} do
      fake_piper!(tmp, seen, :fail)

      assert {:error, {:tts_failed, msg}} = Announcement.wav_for_text("Scheitert.")
      assert msg =~ "exit 3"
      assert msg =~ "piper kaputt"
    end

    test "piper exit 0 OHNE Ausgabedatei → Fehler statt Erfolgsmeldung", %{tmp: tmp, seen: seen} do
      # Die Silent-Failure-Klasse: „erfolgreich" gelaufen, aber kein Ergebnis.
      fake_piper!(tmp, seen, :exit_0_no_file)

      assert {:error, {:tts_failed, msg}} = Announcement.wav_for_text("Kein Output.")
      assert msg =~ "exit 0"
    end

    test "nicht existierendes Binary → Fehler, kein Crash", %{tmp: tmp} do
      Worker.Settings.put(:piper_bin, Path.join(tmp, "gibt-es-nicht"))
      Worker.Settings.put(:piper_model, Path.join(tmp, "stimme.onnx"))

      assert {:error, {:tts_failed, _}} = Announcement.wav_for_text("Ansage.")
    end
  end

  describe "Shell-Injection über den Kampagnennamen (GM-getippter Freitext)" do
    test "Metazeichen werden vorgelesen, nicht ausgeführt", %{
      tmp: tmp,
      seen: seen,
      canary: canary
    } do
      fake_piper!(tmp, seen, :ok)
      File.rm(canary)

      evil = [
        "Runde'; touch " <> canary <> "; echo '",
        "Runde$(touch " <> canary <> ")",
        "Runde`touch " <> canary <> "`",
        "Runde && touch " <> canary,
        "Runde | touch " <> canary,
        "Runde\"; touch " <> canary <> "; \""
      ]

      for name <- evil do
        assert {:ok, _} = name |> Announcement.text_for() |> Announcement.wav_for_text()
      end

      refute File.exists?(canary),
             "Shell-Injection über den Kampagnennamen gelungen — der Name darf NIE in die Kommandozeile"

      # Und der Name kam vollständig als TEXT an (nicht zerschnitten/geschluckt).
      lines = seen_lines(seen)
      assert length(lines) == length(evil)
      assert Enum.any?(lines, &(&1 =~ "touch"))
    end

    test "Kampagnenname mit Anführungszeichen erzeugt trotzdem eine Ansage", %{
      tmp: tmp,
      seen: seen
    } do
      fake_piper!(tmp, seen, :ok)

      assert {:ok, _} =
               ~s(Toms 'wilde' "Runde") |> Announcement.text_for() |> Announcement.wav_for_text()

      assert seen_lines(seen) |> List.first() =~ ~s(Toms 'wilde' "Runde")
    end
  end

  # ─── Issue #1005: Ansagen im laufenden Betrieb ──────────────────

  describe "text_for_join/2 — consent-bewusst (Live-Abnahme #1013, Wortlaut vom Auftraggeber)" do
    test "mit Aufnahmefreigabe: Beitritt + Audio-wird-aufgezeichnet" do
      assert Announcement.text_for_join("Kai", true) ==
               "Kai ist beigetreten. Audio wird aufgezeichnet."
    end

    test "ohne Freigabe: Beitritt + Zustimmungs-Hinweis mit Namen" do
      assert Announcement.text_for_join("Kai", false) ==
               "Kai ist beigetreten. Du musst der Verarbeitung im Chat zustimmen, " <>
                 "um die Audioaufnahme zu starten."
    end

    test "ohne Namen eine namenlose Fassung (die Ansage darf nie ausfallen)" do
      for missing <- [nil, "", "   "] do
        assert Announcement.text_for_join(missing, true) ==
                 "Eine weitere Person ist beigetreten. Audio wird aufgezeichnet."

        assert Announcement.text_for_join(missing, false) =~
                 "Eine weitere Person ist beigetreten. Sie muss der Verarbeitung im Chat zustimmen"
      end
    end

    test "unsprechbarer Name (Emoji/Symbole) fällt auf die namenlose Fassung" do
      # piper würde daraus eine unhörbare WAV erzeugen — und pro Variante eine
      # neue, weil der Cache auf dem Text-Hash keyt.
      assert Announcement.text_for_join("🎲🎲🎲", true) =~ "Eine weitere Person ist beigetreten."
      assert Announcement.text_for_join("***", false) =~ "Eine weitere Person ist beigetreten."
    end

    test "Name wird normalisiert (Whitespace, Deckel)" do
      assert Announcement.text_for_join("  Kai\n\nBauer  ", true) =~ "Kai Bauer ist beigetreten."
      lang = Announcement.text_for_join(String.duplicate("Ka", 200), true)
      assert String.length(lang) < 160
    end
  end

  describe "text_for_pending/1 — Sammel-Ansage mit Plural" do
    test "eine Person: Singular" do
      text = Announcement.text_for_pending(["Kai"])
      assert text == "Keine Zustimmung von Kai."

      # Issue #1032: die Erinnerung nennt NUR noch Namen. Die Anleitung steht
      # einmalig in der Eröffnung bzw. in der Beitritts-Ansage des Betroffenen —
      # sie hier zu wiederholen war der teuerste Posten der alten Redezeit
      # (15 s statt 3 s je Erinnerung).
      refute text =~ "Chat"
      refute text =~ "zustimmen"
    end

    test "zwei Personen: A und B, Plural" do
      assert Announcement.text_for_pending(["Kai", "Mira"]) ==
               "Keine Zustimmung von Kai und Mira."
    end

    test "drei und mehr: Komma-Liste mit und" do
      assert Announcement.text_for_pending(["Kai", "Mira", "Ola"]) ==
               "Keine Zustimmung von Kai, Mira und Ola."

      assert Announcement.text_for_pending(["A", "B", "C", "D"]) =~ "von A, B, C und D."
    end

    test "leere Liste → nil (es gibt nichts anzusagen)" do
      assert Announcement.text_for_pending([]) == nil
      assert Announcement.text_for_pending(nil) == nil
    end

    test "Namen vorhanden, aber keiner sprechbar → Anzahl bleibt erhalten" do
      assert Announcement.text_for_pending(["🎲"]) == "Keine Zustimmung von einer Person."
      assert Announcement.text_for_pending(["🎲", "***"]) == "Keine Zustimmung von 2 Personen."
    end

    test "teilweise sprechbar: nur die sprechbaren werden genannt" do
      text = Announcement.text_for_pending(["Kai", "🎲"])
      assert text == "Keine Zustimmung von Kai."
      refute text =~ "🎲"
    end
  end

  describe "text_for_granted/1 — die Bestätigung" do
    test "nennt den Namen" do
      assert Announcement.text_for_granted("Kai") == "Kai hat der Aufnahme zugestimmt."
    end

    test "ohne Namen bleibt die Bestätigung erhalten" do
      assert Announcement.text_for_granted(nil) == "Die Zustimmung wurde gespeichert."
    end
  end
end
