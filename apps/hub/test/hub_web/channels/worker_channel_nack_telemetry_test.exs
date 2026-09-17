defmodule HubWeb.WorkerChannelNackTelemetryTest do
  @moduledoc """
  Issue #542 (Kommentar vom 24.07.): der Wrong-Worker-Audio-Drop war das
  einzige Verlust-Ereignis ohne Telemetrie.

  Die Asymmetrie war der Befund: verwirft der Hub einen Chunk, weil kein
  Member-Worker online ist, feuert seit #468 `[:hub, :audio, :chunk_dropped]`
  — verwirft ein **Worker** den Chunk (Session ohne offenen Sink, #772),
  meldet er das per `audio_nack`, und der Verlust war nur für den
  betroffenen Sender sichtbar (NACK → Streak → Flash). In den Logs fehlte
  er, und damit in jeder nachträglichen Auswertung.
  """
  use ExUnit.Case, async: false

  describe "audio_nack" do
    test "meldet den Verlust als chunk_dropped mit Grund :wrong_worker" do
      attach_telemetry([:hub, :audio, :chunk_dropped])

      {:noreply, _socket} =
        HubWeb.WorkerChannel.handle_in(
          "audio_nack",
          %{"session_id" => "s-nack-542", "discord_id" => "did-sender-542"},
          %Phoenix.Socket{}
        )

      assert_receive {:telemetry, [:hub, :audio, :chunk_dropped], messwerte, meta}, 1_000

      assert meta.reason == :wrong_worker
      assert meta.session_id == "s-nack-542"
      # Der Sender ist hier die eigentliche Auskunft — welcher Worker
      # verworfen hat, steht ohnehin in dessen eigenem Log.
      assert meta.discord_id == "did-sender-542"
      assert messwerte.count == 1
    end

    test "der NACK erreicht weiterhin die Mikro-Ansicht des Senders" do
      # Die Telemetrie ist eine Ergänzung, kein Ersatz: der bestehende Pfad
      # aus #772 (NACK → MicLive → Streak-Warnung) muss unberührt bleiben.
      did = "did-sender-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Hub.PubSub, HubWeb.MicLive.mic_topic(did))

      {:noreply, _socket} =
        HubWeb.WorkerChannel.handle_in(
          "audio_nack",
          %{"session_id" => "s-nack-pfad", "discord_id" => did},
          %Phoenix.Socket{}
        )

      assert_receive {:audio_nack, "s-nack-pfad"}, 1_000
    end
  end

  # Schickt jedes Vorkommen des Ereignisses an den Testprozess.
  defp attach_telemetry(event_name) do
    test_pid = self()
    handler_id = "test-542-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event_name,
      fn _name, messwerte, meta, _config ->
        send(test_pid, {:telemetry, event_name, messwerte, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
