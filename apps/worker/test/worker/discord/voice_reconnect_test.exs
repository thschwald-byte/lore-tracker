defmodule Worker.Discord.VoiceReconnectTest do
  @moduledoc """
  Issue #1050: der Discord-Empfang endete nach jedem Voice-Reconnect endgültig,
  ohne dass es irgendwo sichtbar wurde.

  Zwei Wege führten in denselben Endzustand, und beide werden hier festgehalten:

  1. **Der Socket wird nie neu scharfgeschaltet.** Nostrum öffnet ihn bei JEDEM
     Handshake neu und passiv; `start_listen_async/1` lief genau einmal beim
     ersten Beitritt, sein Rückgabewert wurde verworfen.
  2. **Das eigene Austritts-Ereignis wurde verworfen.** Wird der Bot aus dem
     Kanal geworfen oder verschoben, meldet Discord genau das — die Session
     prüfte „bin ich das selbst?" und tat nichts.

  Geprüft wird hier, was ohne echten Nostrum-Bot prüfbar ist: die Verdrahtung
  (Consumer-Klausel, Zustandsweiche, Timer- und Feld-Disziplin) und die
  Entscheidung im Austritts-Zweig. Dass Discord nach dem erneuten
  Scharfschalten real wieder Pakete liefert, kann nur ein Lauf am echten Server
  zeigen — das ist die Abnahme und steht ausdrücklich aus.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.VoiceSession

  defp quelle(pfad) do
    Path.join([__DIR__, "..", "..", "..", pfad]) |> Path.expand() |> File.read!()
  end

  describe "Consumer: das Ereignis kommt überhaupt an" do
    test "es gibt eine :VOICE_READY-Klausel, die an die Session weiterreicht" do
      src = quelle("lib/worker/discord/consumer.ex")

      assert src =~ "{:VOICE_READY,",
             "Ohne eigene Klausel fällt :VOICE_READY in den Catch-all — genau der Defekt aus #1050"

      assert src =~ "VoiceSession.voice_ready(guild_id)",
             "Die Klausel muss die Session erreichen, sonst ist sie Dekoration"
    end

    test "die Klausel steht VOR dem Catch-all" do
      src = quelle("lib/worker/discord/consumer.ex")
      voice_ready = :binary.match(src, "{:VOICE_READY,") |> elem(0)
      catch_all = :binary.match(src, "def handle_event(_event)") |> elem(0)

      assert voice_ready < catch_all,
             "Nach dem Catch-all wäre die Klausel unerreichbar"
    end
  end

  describe "Session: wann neu scharfgeschaltet wird" do
    test "vor dem ersten Zuhören passiert nichts" do
      # Sonst liefe die Aufzeichnung VOR der Consent-Ansage an (#989-Reihenfolge).
      src = quelle("lib/worker/discord/voice_session.ex")

      assert src =~
               "def handle_cast(:voice_ready, %{listening?: false} = state), do: {:noreply, state}",
             "Ohne diese Weiche schaltet der erste Handshake scharf, bevor die Ansage lief"
    end

    test "im laufenden Betrieb wird scharfgeschaltet und der Rückgabewert ausgewertet" do
      src = quelle("lib/worker/discord/voice_session.ex")

      assert src =~ "NostrumSafe.start_listen(state.guild_id)"

      assert src =~ "report_listen_failed",
             "Ein endgültig misslungenes Scharfschalten muss sichtbar werden — " <>
               "das Verschlucken des Rückgabewerts WAR der Defekt"
    end

    test "NostrumSafe.start_listen/1 reicht den Fehler weiter, statt ihn zu schlucken" do
      src = quelle("lib/worker/discord/nostrum_safe.ex")
      [_, body] = Regex.run(~r/def start_listen\(guild_id\) do(.*?)\n  end\n/s, src)

      assert body =~ "{:error, reason} -> {:error, reason}",
             "Die Nachbarn hier degradieren bewusst zu neutralen Werten; diese Funktion " <>
               "darf das nicht — ein Fehlschlag heisst „ab jetzt kommt kein Paket mehr\""
    end

    test "der Timer ist in @timer_keys und hat seine handle_info-Klausel" do
      # Dieselbe Disziplin, die der Wächter in voice_session_state_test.exs für
      # alle Timer erzwingt — hier für den neuen namentlich.
      assert :retry_listen_timer in VoiceSession.timer_keys()
      assert quelle("lib/worker/discord/voice_session.ex") =~ "def handle_info(:retry_listen,"
    end

    test "die neuen Zustandsfelder sind im initialen Aufbau angelegt" do
      # #1005-Lektion: ein per %{state | …} geschriebenes Feld, das init/1 nicht
      # anlegt, wirft KeyError -> transient restart -> Ansage in Endlosschleife.
      state =
        VoiceSession.initial_state(
          %{campaign_id: "c", session_id: "s", guild_id: 1, voice_channel_id: 2},
          nil,
          0,
          0
        )

      assert Map.has_key?(state, :retry_listen_timer)
      assert Map.get(state, :listen_retries) == 0
    end
  end

  describe "Session: Verhalten, nicht nur Quelltext" do
    # Diese beiden laufen den echten Callback — ohne Nostrum, das im Test nicht
    # gestartet ist. Genau deshalb sind sie aussagekräftiger als die
    # Quelltext-Wächter darüber.

    setup do
      state =
        VoiceSession.initial_state(
          %{campaign_id: "c", session_id: "s", guild_id: 1, voice_channel_id: 2},
          nil,
          0,
          0
        )

      {:ok, state: state}
    end

    test "vor dem ersten Zuhören bleibt der Zustand unangetastet", %{state: state} do
      assert {:noreply, ^state} = VoiceSession.handle_cast(:voice_ready, state)
      refute_receive :retry_listen, 50
    end

    test "läuft die Sitzung, wird ein misslungener Anlauf wiederholt statt verschluckt",
         %{state: state} do
      # Ohne laufenden Nostrum-Bot scheitert das Scharfschalten — der Fall, den
      # der alte Code verworfen hat.
      {:noreply, neu} = VoiceSession.handle_cast(:voice_ready, %{state | listening?: true})

      assert neu.listen_retries == 1, "der Fehlschlag muss gezählt werden"
      assert is_reference(neu.retry_listen_timer), "und einen zweiten Anlauf auslösen"

      assert_receive :retry_listen, 2_000
    end
  end

  describe "Session: unfreiwilliges Verlassen" do
    test "der eigene Austritt aus unserem Kanal beendet die Aufnahme definiert" do
      src = quelle("lib/worker/discord/voice_session.ex")

      assert src =~ "report_channel_lost",
             "Der Austritt muss in /admin/errors sichtbar werden"

      assert src =~ "{:stop, :normal, state}",
             "Definiertes Ende statt stillem Weiterlauf; :normal, weil " <>
               "restart: :transient sonst neu startet — in einen Kanal, in den " <>
               "der Bot gerade nicht darf"
    end

    test "der Beitritt selbst wird nicht als Abriss missverstanden" do
      src = quelle("lib/worker/discord/voice_session.ex")

      assert src =~ "ich? and state.listening? and channel_id != state.voice_channel_id",
             "Ohne die listening?-Bedingung gälte jeder Zwischenzustand während " <>
               "des Beitritts als Verlust"
    end
  end
end
