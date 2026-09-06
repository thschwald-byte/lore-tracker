defmodule Hub.ReaderQueueTest do
  @moduledoc """
  Issue #1149 (Epic #1146): die Warteschlange für die grossen Reads.

  **Warum die Callbacks direkt gerufen werden.** `Hub.Reader` ist ein
  GenServer, dessen Verhalten hier gerade in den Zustandsübergängen liegt —
  wer wird eingereiht, wann rückt die Schlange vor, wer bekommt welche
  Antwort. Über `read/2` wäre davon nur die Antwort sichtbar, und die
  Zwischenzustände (Position, belegter Platz) blieben ungeprüft. Dasselbe
  Muster wie `reader_pending_test.exs`.

  Der Zustand kommt aus `Reader.initial_state/0`, nie von Hand gebaut — sonst
  fehlt beim nächsten neuen Feld genau hier eins, und der Test grünt an einem
  Zustand vorbei, den es in Wirklichkeit nicht gibt.

  **Die WorkerRegistry läuft in der Testumgebung und ist leer.** Das ist kein
  Mangel, sondern nutzbar: ein Dequeue ohne verfügbaren Worker ist ein eigener
  Pfad, der sonst schwer herzustellen wäre. Wo ein echter Worker nötig ist,
  steht es am Test.
  """

  use ExUnit.Case, async: false

  alias Hub.Reader

  defp from, do: {self(), make_ref()}
  defp gross(kind \\ "campaign"), do: %{"kind" => kind, "id" => "c1"}

  defp lese_call(scope, state, opts \\ []) do
    Reader.handle_call(
      {:read, scope, [], opts[:notify], Reader.serialized?(scope)},
      opts[:from] || from(),
      state
    )
  end

  # Ein belegter Platz, ohne dass ein echter Read laufen muss.
  defp belegt(state \\ Reader.initial_state()), do: %{state | in_flight: "rid-laeuft"}

  describe "Klassifikation: was gehört in die Schlange" do
    test "die drei Kampagnen-weiten Scopes ja" do
      for kind <- ~w(campaign campaign_luecken campaign_facts) do
        assert Reader.serialized?(%{"kind" => kind}), "#{kind} muss serialisiert werden"
      end
    end

    test "alles andere nicht" do
      # Die kleinen Scopes zu serialisieren würde Wartezeit erzeugen, ohne
      # Speicher zu sparen. campaign_utterances ist der Nachlade-Scope des
      # #1087-Fensters und liefert eine feste Zahl Zeilen.
      for kind <- ~w(settings jobs errors all_users campaign_utterances campaign_nachlese) do
        refute Reader.serialized?(%{"kind" => kind}), "#{kind} darf NICHT serialisiert werden"
      end
    end

    test "ein Scope ohne kind fällt nicht auf die Nase" do
      refute Reader.serialized?(%{})
    end
  end

  describe "Wartefrist: gerechnet, nicht gegriffen" do
    test "wer nichts vor sich hat, bekommt zwei Zuschläge" do
      # Der laufende Read plus der eigene, je @per_attempt_timeout (5 s).
      assert Reader.queue_deadline_ms(0) == 10_000
    end

    test "jeder Wartende vor mir kostet einen weiteren Zuschlag" do
      assert Reader.queue_deadline_ms(1) == 15_000
      assert Reader.queue_deadline_ms(5) == 35_000
    end

    test "gedeckelt, damit ein Herd niemanden ewig hängen lässt" do
      assert Reader.queue_deadline_ms(100) == 60_000
      assert Reader.queue_deadline_ms(10_000) == 60_000
    end

    test "monoton — mehr Wartende sind nie eine kürzere Frist" do
      fristen = Enum.map(0..30, &Reader.queue_deadline_ms/1)
      assert fristen == Enum.sort(fristen)
    end
  end

  describe "Einreihen" do
    test "ein grosser Read bei belegtem Platz wartet, statt zu starten" do
      {:noreply, state} = lese_call(gross(), belegt())

      assert length(state.queue) == 1
      assert state.in_flight == "rid-laeuft", "der laufende Read darf nicht verdrängt werden"
      # Kein Worker angesprochen — genau das ist der Zweck.
      refute_receive {:snapshot_request, _, _, _}, 50
    end

    test "ein kleiner Read läuft an der Schlange vorbei" do
      # Ohne Worker endet er in :no_worker — entscheidend ist, dass er
      # ANTWORTET statt zu warten.
      {:reply, {:error, :no_worker}, state} = lese_call(%{"kind" => "settings"}, belegt())
      assert state.queue == []
    end

    test "bei freiem Platz wird sofort gestartet, nicht eingereiht" do
      {:reply, {:error, :no_worker}, state} = lese_call(gross(), Reader.initial_state())
      assert state.queue == []
    end

    test "die Reihenfolge ist die Ankunftsreihenfolge" do
      {:noreply, s1} = lese_call(gross("campaign"), belegt())
      {:noreply, s2} = lese_call(gross("campaign_luecken"), s1)
      {:noreply, s3} = lese_call(gross("campaign_facts"), s2)

      assert Enum.map(s3.queue, & &1.scope["kind"]) ==
               ~w(campaign campaign_luecken campaign_facts)
    end
  end

  describe "Rückmeldungen an die Anzeige" do
    test "beim Einreihen kommt die Position" do
      {:noreply, _} = lese_call(gross(), belegt(), notify: self())
      assert_receive {:reader_queued, "campaign", 1}
    end

    test "der zweite Wartende erfährt Position 2" do
      {:noreply, s1} = lese_call(gross(), belegt(), notify: self())
      assert_receive {:reader_queued, "campaign", 1}

      {:noreply, _} = lese_call(gross("campaign_facts"), s1, notify: self())
      assert_receive {:reader_queued, "campaign_facts", 2}
    end

    test "ohne notify verhält sich alles wie zuvor — keine Nachrichten" do
      {:noreply, state} = lese_call(gross(), belegt())
      assert length(state.queue) == 1
      refute_receive {:reader_queued, _, _}, 50
    end
  end

  describe "Der Platz wird an JEDEM Ausgang frei" do
    setup do
      # Ein laufender, serialisierter Read mit einem Wartenden dahinter.
      wartender = from()
      {:noreply, state} = lese_call(gross("campaign_facts"), belegt(), from: wartender)

      pending = %{
        "rid-laeuft" => %{
          from: from(),
          remaining: [],
          scope: gross(),
          timer: nil,
          attempts_left: 0,
          worker_id: "w1",
          serialized?: true,
          notify: nil
        }
      }

      %{state: %{state | pending: pending}, wartender: wartender}
    end

    test "Antwort: der Wartende rückt vor", %{state: state} do
      {:noreply, s, :hibernate} =
        Reader.handle_cast({:response, "rid-laeuft", %{"ok" => true}}, state)

      assert s.queue == [], "die Schlange muss vorgerückt sein"
      # Ohne Worker in der Registry bekommt der Wartende :no_worker — der
      # Punkt ist, dass er ÜBERHAUPT bedient wird statt hängen zu bleiben.
      assert s.in_flight == nil
    end

    test "Antwort: der Wartende bekommt eine Antwort, keine Stille", %{
      state: state,
      wartender: {_pid, ref}
    } do
      {:noreply, _, :hibernate} =
        Reader.handle_cast({:response, "rid-laeuft", %{"ok" => true}}, state)

      assert_receive {^ref, {:error, :no_worker}}
    end

    test "Timeout: der Platz wird ebenso frei", %{state: state} do
      {:noreply, s, :hibernate} = Reader.handle_info({:timeout, "rid-laeuft"}, state)
      assert s.queue == []
      assert s.in_flight == nil
    end

    test "Worker meldet sich ab: der laufende Read fällt, die Schlange rückt", %{state: state} do
      # Ohne das stünde die Schlange genau im Reconnect-Fall still — dem Fall,
      # für den sie gebaut ist.
      {:noreply, s} =
        Reader.handle_info({:workers_changed, [], [{"w1", %{}}]}, state)

      assert s.pending == %{}, "der Read am abgemeldeten Worker muss weg sein"
      assert s.queue == []
      assert s.in_flight == nil
    end

    test "ein fremder Worker meldet sich ab: nichts passiert", %{state: state} do
      {:noreply, s} = Reader.handle_info({:workers_changed, [], [{"w-fremd", %{}}]}, state)

      assert Map.has_key?(s.pending, "rid-laeuft"), "unbeteiligter Read darf nicht sterben"
      assert length(s.queue) == 1
    end
  end

  describe "Wartefrist läuft ab" do
    test "der Wartende bekommt einen Fehler und KEINEN stillen Neuversuch" do
      # Ein Timer-Retry würde den Kill-Kreislauf, den diese Schlange bricht,
      # durch einen Timeout-Kreislauf ersetzen.
      {_pid, ref} = wartender = from()
      {:noreply, state} = lese_call(gross(), belegt(), from: wartender)
      [%{queue_ref: qref}] = state.queue

      {:noreply, s} = Reader.handle_info({:queue_timeout, qref}, state)

      assert_receive {^ref, {:error, :queue_timeout}}
      assert s.queue == []
      assert s.in_flight == "rid-laeuft", "der laufende Read bleibt unberührt"
      refute_receive {:snapshot_request, _, _, _}, 50
    end

    test "eine unbekannte Frist ist ein No-op" do
      {:noreply, state} = lese_call(gross(), belegt())
      {:noreply, s} = Reader.handle_info({:queue_timeout, make_ref()}, state)
      assert length(s.queue) == 1
    end

    test "die Übrigen erfahren ihre neue Position" do
      {:noreply, s1} = lese_call(gross(), belegt(), notify: self())
      {:noreply, s2} = lese_call(gross("campaign_facts"), s1, notify: self())
      [%{queue_ref: erste_ref} | _] = s2.queue

      {:noreply, _} = Reader.handle_info({:queue_timeout, erste_ref}, s2)

      # Der Zweite ist jetzt der Erste.
      assert_receive {:reader_queued, "campaign_facts", 1}
    end
  end

  describe "Unbekannte Nachrichten" do
    test "bringen den Reader nicht um" do
      # Der Reader abonniert seit #1149 die Registry und bekommt damit
      # Nachrichten, die er nicht alle kennt.
      state = Reader.initial_state()
      assert {:noreply, ^state} = Reader.handle_info(:voellig_unerwartet, state)
    end
  end
end
