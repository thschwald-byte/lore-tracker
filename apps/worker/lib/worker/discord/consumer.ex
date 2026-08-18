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
    # Issue #1076: das ist das EINZIGE ehrliche „die Verbindung steht"-Signal.
    # Ein gestarteter Bot-Prozess ist noch keine Gateway-Session — genau diese
    # Verwechslung hätte den Vorfall vom 2026-08-18 verschleiert.
    Worker.Discord.BotGate.gateway_ready()
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
    # Issue #1013: das `member`-Objekt trägt `nick` + `user.global_name` — Namen
    # OHNE HTTP-Call und OHNE den privilegierten `:guild_members`-Intent. Bis
    # hierher wurde es verworfen; jetzt reist der Anzeigename mit, damit die
    # Beitritts-Ansagen einen Namen haben. Discord garantiert das Feld nicht
    # (`nil` ist zulässig und häufig bei Cache-Misses) — der Namens-Cache in der
    # Session behält dann den letzten bekannten Namen.
    Worker.Discord.VoiceSession.voice_state_update(
      guild_id,
      user_id,
      Map.get(vs, :channel_id),
      display_name(Map.get(vs, :member))
    )
  end

  # Issue #1005: Klick auf einen Consent-Button. INTERACTION_CREATE braucht
  # KEINEN Intent (steht in keiner Intent-Gruppe) — läuft also mit unseren
  # bestehenden `[:guilds, :guild_voice_states]`.
  #
  # Reihenfolge ist Absicht und nicht beliebig:
  #   1. parsen + prüfen (pure, `ConsentButton`),
  #   2. ANTWORTEN — Discord verwirft eine Interaction nach 3 Sekunden; die
  #      Antwort darf also nie hinter einer Mnesia-Transaktion oder einem
  #      Hub-Call warten,
  #   3. dann die Session informieren (Zustand + Zeitstempel),
  #   4. dann persistieren (`Intents.publish` → lokaler Apply + Hub-Push).
  #
  # Schritt 3+4 laufen hier im Consumer-Task (Nostrum spawnt pro Event einen),
  # nicht im VoiceSession-GenServer — `Intents.publish/1` macht eine
  # Mnesia-Transaktion plus `GenServer.call` an den HubClient, und beides gehört
  # nicht in den Prozess, der 50 Audio-Pakete pro Sekunde und Sprecher annimmt.
  def handle_event({:INTERACTION_CREATE, interaction, _ws}) do
    Worker.Discord.ConsentInteraction.handle(interaction)
  end

  # Default-Klausel (Nostrum-main verlangt sie) — jedes andere unbehandelte
  # Event ist ein bewusster No-op.
  def handle_event(_event), do: :ok

  # Issue #1013: Anzeigename aus dem member-Objekt — Server-Nick vor globalem
  # Anzeigenamen vor Login-Namen (dieselbe Rangfolge, in der Discord selbst
  # anzeigt). Defensiv gegen Structs UND rohe Maps: das Event kommt je nach
  # Cache-Zustand unterschiedlich gecastet an, und ein Namens-Fehler darf den
  # Consumer-Task nie kosten (dann fehlt nur der Name, nicht das Event).
  defp display_name(%{nick: nick} = member) when is_binary(nick) and nick != "",
    do: String.trim(nick) |> non_empty() || display_name(Map.delete(member, :nick))

  defp display_name(%{user: %{} = user}) do
    non_empty_string(Map.get(user, :global_name)) || non_empty_string(Map.get(user, :username))
  end

  defp display_name(_), do: nil

  defp non_empty_string(v) when is_binary(v), do: non_empty(String.trim(v))
  defp non_empty_string(_), do: nil

  defp non_empty(""), do: nil
  defp non_empty(s), do: s
end
