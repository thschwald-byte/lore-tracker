defmodule Worker.Recording.SpurIsolierungTest do
  @moduledoc """
  Issue #1054: Eine abgebrochene Spur darf die anderen nicht mitreißen — und
  was nicht transkribiert wurde, darf nicht als erledigt weggeräumt werden.

  Am 13.08.2026 starb die Transkription bei Spur 2 von 18. Die restlichen 16
  liefen nie, das Audio wurde trotzdem archiviert; gerettet hat den Abend nur,
  dass ein Archiv-Verzeichnis gesetzt war — bei „nach Transkription löschen"
  wäre der Mitschnitt weg gewesen.

  Geprüft wird beides: die reine Entscheidungslogik (ohne Dateisystem), die
  echte Dateibewegung (mit Dateisystem, ohne Whisper) und per Quelltext die
  Stellen, an denen die Verdrahtung still brechen kann — der Transkriptions-
  Pfad ist ohne Whisper, GPU und Mnesia-Sitzung nicht end-to-end fahrbar.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Recording.AudioBuffer
  alias Worker.Recording.AudioBuffer.Archivierung

  @transcribe File.read!("lib/worker/recording/transcribe.ex")
  @puffer File.read!("lib/worker/recording/audio_buffer.ex")
  @spuren File.read!("lib/worker/recording/transcribe/spuren.ex")

  setup do
    clear_all_tables!()
    base = Path.join(System.tmp_dir!(), "lore_spur_test_#{System.unique_integer([:positive])}")
    live = Path.join(base, "live")
    done = Path.join(base, "done")
    Worker.Settings.put(:audio_dir, live)
    Worker.Settings.put(:audio_done_dir, done)

    on_exit(fn ->
      File.rm_rf(base)
      Worker.Settings.put(:audio_dir, "/tmp/lore_audio")
      Worker.Settings.put(:audio_done_dir, "/tmp/lore_audio_done")
    end)

    {:ok, live: live, done: done}
  end

  # Eine Sitzung mit N Spuren, jede mit ihren drei Dateien (Ton, Zeitanker,
  # Umwandlung) — genau das Layout, das in Prod im Archiv liegt.
  defp mk_session(live, sid, keys) do
    dir = Path.join(live, sid)
    File.mkdir_p!(dir)

    for key <- keys, endung <- [".webm", ".chunks.jsonl", ".wav"] do
      File.write!(Path.join(dir, key <> endung), "X")
    end

    # Der Geburts-Vermerk, den `open_session` anlegt (#934).
    File.write!(Path.join(dir, ".retention.json"), ~s({"created_at":"x","purge_after":null}))

    dir
  end

  describe "Entscheid: Ende-Grund allein reicht nicht" do
    test "alles durch → archivieren" do
      assert Archivierung.entscheide(:normal, :ok) == :alles
    end

    test "gemeldete offene Spuren → nur die übrigen archivieren" do
      assert Archivierung.entscheide(:normal, {:teilweise, ["b"]}) == {:teilweise, ["b"]}
    end

    test "leere Liste offener Spuren ist kein Teilausfall" do
      assert Archivierung.entscheide(:normal, {:teilweise, []}) == :alles
    end

    test "der Kern des Defekts: normales Ende OHNE Meldung archiviert nicht mehr" do
      # Die GpuQueue fängt jede Ausnahme ab und gibt sie als Wert zurück; der
      # Task endete danach `:normal`. Genau hier wurde aus einem Fehlschlag ein
      # Erfolg. Fail-closed: lieber ein doppeltes Protokoll (sichtbar) als ein
      # verlorener Abend (endgültig).
      assert Archivierung.entscheide(:normal, nil) == :liegen_lassen
    end

    test "Fehler der Warteschlange → nichts wegräumen" do
      assert Archivierung.entscheide(:normal, {:error, {%RuntimeError{}, []}}) == :liegen_lassen
    end

    test "abnormales Ende → wie bisher liegen lassen" do
      assert Archivierung.entscheide({:shutdown, :killed}, :ok) == :liegen_lassen
    end
  end

  describe "Dateien einer offenen Spur erkennen" do
    test "alle Endungen derselben Spur bleiben zusammen" do
      for name <- ["a.webm", "a.chunks.jsonl", "a.wav"] do
        assert Archivierung.bleibt_liegen?(name, ["a"])
      end
    end

    test "eine künftige vierte Endung wird mit erfasst" do
      # Der Präfix-Vergleich ist Absicht: eine Liste bekannter Endungen hätte
      # genau eine vergessene Sorte gebraucht, damit der Zeitanker einer
      # offenen Spur ins Archiv wandert und die Wiederholung ohne ihn läuft.
      assert Archivierung.bleibt_liegen?("a.vad.json", ["a"])
    end

    test "Schlüssel mit Punkt (Discord-Fenster) trennt sauber" do
      assert Archivierung.bleibt_liegen?("249497534228070400.100.webm", ["249497534228070400.100"])

      refute Archivierung.bleibt_liegen?(
               "249497534228070400.101.webm",
               ["249497534228070400.100"]
             )
    end

    test "fremde Spuren bleiben unberührt" do
      refute Archivierung.bleibt_liegen?("b.webm", ["a"])
      refute Archivierung.bleibt_liegen?("ab.webm", ["a"])
    end

    test "ohne offene Spuren wandert alles" do
      assert Archivierung.aufteilen(["a.webm", "b.webm"], []) == {["a.webm", "b.webm"], []}
    end
  end

  describe "Dateibewegung am echten Dateisystem" do
    test "Teilausfall: die geglückten Spuren wandern, die offene bleibt liegen", %{
      live: live,
      done: done
    } do
      sid = "sess-teil"
      dir = mk_session(live, sid, ["a", "b", "c"])

      AudioBuffer.archive_session_audio(sid, ["b"])

      archiviert = Path.join(done, sid) |> File.ls!() |> Enum.sort()
      assert "a.webm" in archiviert and "c.webm" in archiviert
      refute Enum.any?(archiviert, &String.starts_with?(&1, "b."))

      # Die offene Spur liegt vollständig weiter im Live-Verzeichnis — samt
      # Zeitanker, sonst bekämen ihre Utterances beim zweiten Anlauf falsche
      # Zeitstempel. Der Geburts-Vermerk der Sitzung bleibt bei ihr.
      assert dir |> File.ls!() |> Enum.sort() == [
               ".retention.json",
               "b.chunks.jsonl",
               "b.wav",
               "b.webm"
             ]
    end

    test "die Wiederherstellung findet danach GENAU die offene Spur", %{live: live} do
      sid = "sess-recover"
      dir = mk_session(live, sid, ["a", "b"])
      AudioBuffer.archive_session_audio(sid, ["b"])

      webms = dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".webm"))
      {:ok, files} = Worker.Recording.AudioBuffer.Recovery.recover_files(dir, webms)

      # Der Grund für die datei-genaue Archivierung: bliebe alles liegen,
      # stünde hier auch "a" — und der zweite Anlauf erzeugte dessen
      # Utterances ein zweites Mal.
      assert Enum.map(files, &elem(&1, 0)) == ["b"]
    end

    test "voller Erfolg räumt das Verzeichnis ab", %{live: live, done: done} do
      sid = "sess-voll"
      dir = mk_session(live, sid, ["a"])

      AudioBuffer.archive_session_audio(sid)

      refute File.dir?(dir)

      assert Path.join(done, sid) |> File.ls!() |> Enum.sort() ==
               [".retention.json"] ++
                 ["a.chunks.jsonl", "a.wav", "a.webm"]
    end

    test "der zweite Anlauf löscht NICHT, was der erste archiviert hat", %{
      live: live,
      done: done
    } do
      # Fund beim Bau von #1054: der Bestandscode löschte das Ziel-Verzeichnis
      # vorab (`File.rm_rf(dest)`) und benannte dann das Quellverzeichnis um.
      # Solange eine Sitzung genau einmal archiviert wurde, war das harmlos —
      # mit dem zweiten Anlauf einer teilweise archivierten Sitzung wäre es
      # Datenverlust IM ARCHIV geworden.
      sid = "sess-zweimal"
      mk_session(live, sid, ["a", "b"])
      AudioBuffer.archive_session_audio(sid, ["b"])

      # Der Wiederholungs-Lauf bringt die offene Spur durch.
      AudioBuffer.archive_session_audio(sid)

      namen = Path.join(done, sid) |> File.ls!()
      assert "a.webm" in namen, "die beim ersten Lauf gesicherte Spur wurde gelöscht"
      assert "b.webm" in namen
    end
  end

  describe "Verdrahtung (Quelltext — ohne Whisper nicht fahrbar)" do
    test "jede Spur läuft durch die Isolierung, nicht als blankes Enum.map" do
      assert @transcribe =~ "Spuren.isoliert(campaign_id, flat_key",
             "Der Per-Spieler-Pfad ruft transcribe_one ohne Absicherung — die erste Ausnahme reisst die Schleife hoch (#1054)."

      assert @transcribe =~ "Spuren.isoliert(campaign_id, key",
             "Der Raummikro-Pfad ist nicht abgesichert (#1054)."
    end

    test "die Isolierung fängt auch throw und exit" do
      # Benannter Nebenfund des Tickets: ein `throw`/`exit` erzeugte vorher
      # GAR KEINEN Fehlereintrag, nur die Erfolgsmeldung der Warteschlange.
      [_, rumpf] = String.split(@spuren, "def isoliert(campaign_id, key, fun) do", parts: 2)
      rumpf = String.slice(rumpf, 0, 800)
      assert rumpf =~ "rescue"
      assert rumpf =~ "catch"
    end

    test "der Ausgang des Laufs wird an den Puffer gemeldet" do
      assert @puffer =~ "send(puffer, {:transcribe_ergebnis, self(), ergebnis})",
             "Der Rückgabewert der Warteschlange erreicht den Archivierungs-Entscheid nicht (#1054)."
    end

    test "die Pid des Puffers wird VOR der Closure gebunden" do
      # In der Closure wäre `self()` der Task — die Meldung ginge an ihn selbst,
      # der Puffer sähe nie ein Ergebnis und liesse (fail-closed) alles liegen:
      # aus dem Defekt würde ein doppeltes Protokoll. Dieselbe Falle wie bei
      # `start_async` in der CampaignLive (#1149).
      [_, rumpf] = String.split(@puffer, "defp start_transcribe_task", parts: 2)
      vor_closure = String.split(rumpf, "Task.Supervisor.start_child", parts: 2) |> hd()

      assert vor_closure =~ "puffer = self()",
             "self() wird erst in der Closure gebunden — dort ist es die Pid des Tasks (#1054)."
    end

    test "der Entscheid läuft über die pure Regel, nicht über einen if am Ende-Grund" do
      assert @puffer =~ "Archivierung.entscheide(reason, ergebnis)"
    end

    test "das Ziel-Verzeichnis wird beim Archivieren nie vorab geleert" do
      [_, rumpf] = String.split(@puffer, "def archive_session_audio", parts: 2)

      # Kommentarzeilen raus: die Begründung DARF den alten Code benennen —
      # sonst verbietet der Wächter genau die Erklärung, warum es ihn gibt.
      rumpf =
        rumpf
        |> String.slice(0, 2500)
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
        |> Enum.join("\n")

      refute rumpf =~ "File.rm_rf(dest)",
             "Das Archiv wird vor dem Verschieben geleert — der zweite Anlauf einer teilweise archivierten Sitzung löscht damit die bereits gesicherten Spuren (#1054)."
    end

    test "das Zustandsfeld ist im initialen Aufbau angelegt" do
      # #1005-Lehre: ein per Map-Update geschriebenes Feld, das `init/1` nicht
      # anlegt, wirft einen KeyError und schickt den GenServer in eine
      # Neustart-Schleife.
      assert @puffer =~ "transcribe_ergebnisse: %{}"
    end
  end
end
