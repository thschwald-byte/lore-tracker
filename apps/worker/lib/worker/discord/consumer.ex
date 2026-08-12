defmodule Worker.Discord.Consumer do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic): Nostrum-Consumer
  (main-API: `@behaviour Nostrum.Consumer` + `handle_event/1`, verifiziert am
  #941-Spike). Reicht `:VOICE_INCOMING_PACKET` an die per-Guild
  `Worker.Discord.VoiceSession` weiter (Registry-Lookup by guild_id aus dem
  `VoiceWSState`, s. `Nostrum.Struct.VoiceWSState` — trägt `guild_id` +
  `ssrc_map` direkt im dritten Tupel-Element, kein separater
  `Voice.get_ssrc_map/1`-Call pro Paket nötig). Bewusst additiv: das Fehlen
  einer Dispatch-Klausel darf nie crashen (Default-Klausel unten Pflicht,
  sonst FunctionClauseError bei jedem unmatched Gateway-Event).
  """

  @behaviour Nostrum.Consumer

  require Logger

  @impl true
  def handle_event({:READY, _data, _ws}) do
    Logger.info("Worker.Discord.Consumer: READY — Bot online.")
    :ok
  end

  # #941-Spike-Erkenntnis: erst wenn die Guild geladen ist, kennt Nostrum das
  # Guild→Shard-Mapping (join_channel schlägt auf :READY noch fehl). Bot-Start
  # liefert :GUILD_AVAILABLE, neu beigetretene Guilds :GUILD_CREATE — beide
  # nur geloggt, bis Stage D den echten Join verdrahtet.
  def handle_event({:GUILD_AVAILABLE, %{id: id}, _ws}) do
    Logger.debug("Worker.Discord.Consumer: GUILD_AVAILABLE guild_id=#{id}")
    :ok
  end

  def handle_event({:GUILD_CREATE, %{id: id}, _ws}) do
    Logger.debug("Worker.Discord.Consumer: GUILD_CREATE guild_id=#{id}")
    :ok
  end

  # {:VOICE_INCOMING_PACKET, {{seq, timestamp, ssrc}, opus}, VoiceWSState}. Das
  # `opus` ist bereits dave_decrypt'd (nostrum voice.ex, #941-Spike-
  # Verifikation). `ws.guild_id` routet an die passende VoiceSession — läuft
  # für diese Guild keine (No-op im Registry-Lookup), verwirft
  # `VoiceSession.incoming_packet/3` das Paket still.
  def handle_event(
        {:VOICE_INCOMING_PACKET, {{_seq, _ts, ssrc}, opus},
         %{guild_id: guild_id} = voice_ws_state}
      )
      when is_binary(opus) and is_integer(guild_id) do
    # Issue #988: den Sprecher gleich HIER auflösen. Die `ssrc_map` liegt im
    # mitgelieferten VoiceWSState — Nostrums Doku benennt genau das als den
    # vorgesehenen Weg („That struct contains a ssrc_map that can determine the
    # speaking user based on the SSRC"). Spart 50 `Voice.get_ssrc_map/1`-Calls
    # pro Sekunde und Sprecher gegenüber einer Auflösung in der VoiceSession.
    # `nil` (SSRC noch unbekannt) ist normal — Discord schickt das
    # :speaking-Event, das die Map füllt, nicht zwingend vor dem ersten Paket.
    speaker_id = voice_ws_state |> Map.get(:ssrc_map, %{}) |> Map.get(ssrc)
    Worker.Discord.VoiceSession.incoming_packet(guild_id, ssrc, opus, speaker_id)
  end

  # Issue #988: Anwesenheit im Voice-Channel. Öffentliches, dokumentiertes
  # Consumer-Event (bewusst NICHT der `connected_clients`-State der
  # Voice-Websocket — der hat keinen öffentlichen Accessor, das wäre eine
  # Kopplung an Nostrum-Interna). `channel_id == nil` heißt „Kanal verlassen";
  # ein Wechsel in einen ANDEREN Kanal derselben Guild kommt ebenfalls hier an
  # und wird von der VoiceSession gegen ihren eigenen Channel geprüft.
  def handle_event({:VOICE_STATE_UPDATE, %{guild_id: guild_id, user_id: user_id} = vs, _ws})
      when is_integer(guild_id) and is_integer(user_id) do
    Worker.Discord.VoiceSession.voice_state_update(guild_id, user_id, Map.get(vs, :channel_id))
  end

  # Default-Klausel (Nostrum-main verlangt sie) — jedes andere unbehandelte
  # Event ist ein bewusster No-op.
  def handle_event(_event), do: :ok
end
