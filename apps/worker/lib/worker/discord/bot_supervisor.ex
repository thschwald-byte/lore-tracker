defmodule Worker.Discord.BotSupervisor do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage D: dünner
  Wrapper um den `DynamicSupervisor` (`Worker.Discord.BotSupervisor`, im
  `Worker.Application`-Baum) für per-Kampagne `Worker.Discord.VoiceSession`-
  Prozesse. Best-effort — ein Fehler hier darf den Kern-Recording-Start/-Stop
  (Stage E, `Worker.Recording.Recorder`) nie blockieren, analog dem
  `best_effort_artifact/5`-Muster der Wahrheitsbild-Pipeline.

  **Verifizierte Fehler-Sichtbarkeits-Lücke:** `Nostrum.Voice.join_channel/4`
  ruft synchron `Nostrum.Bot.fetch_bot_pid/0` — läuft kein `Nostrum.Bot`
  (z.B. weil ein GM den Bot-Token erst NACH dem letzten Worker-Boot in
  `/settings` gesetzt hat, s. Stage-C-Grenze "Token-Änderung erst nach
  Neustart wirksam"), wirft das ein `RuntimeError` bereits in
  `VoiceSession.init/1` — bevor der Prozess überhaupt lebt. Empirisch
  verifiziert: `DynamicSupervisor.start_child/2` fängt das sauber als
  `{:error, {exception, stacktrace}}` ab (kein Crash des Supervisors, kein
  Zombie-Prozess), aber `VoiceSession.terminate/2` (und damit der
  `/admin/errors`-Pfad) wird NIE erreicht — dieser Fehler landet nur im
  Worker-Log (`Logger.error` unten), nicht in der `/admin/errors`-Fehler-
  Taxonomie. Nur ein erfolgreich gestarteter Prozess, der SPÄTER abstürzt,
  bekommt den vollen Error-Pipeline-Eintrag.

  **Issue #987 (echter Live-Test-Fund, kritisch):** die Registry war
  ursprünglich NUR nach `guild_id` geschlüsselt, ohne zu tracken, WELCHE
  Kampagne die laufende Session besitzt. Zwei Kampagnen auf demselben
  Discord-Server (unterschiedliche Voice-Channels) konnten sich dadurch
  gegenseitig die Bot-Session stehlen bzw. killen: Kampagne B startet ihre
  Aufnahme, sieht "Guild X schon belegt" (durch Kampagne A) und tut nichts —
  aber `Recorder` merkte sich trotzdem einen `discord_guild_id` für B. Stoppt
  B danach seine Aufnahme, hätte das A's AKTIVE Session gekillt, obwohl B nie
  wirklich einen Bot hatte. Fix: der Registry-WERT ist jetzt die besitzende
  Kampagne + der belegte Voice-Channel (s. `VoiceSession.via/2`/`owner/0`) —
  ein Konflikt zwischen zwei Kampagnen wird jetzt LAUT UND PRÄZISE gemacht
  (Logger.error + `PipelineErrorLogged` nennen die belegende Kampagne UND
  den belegten Channel, nicht nur "Guild belegt") statt stillschweigend
  übernommen, und `stop_voice_session/2` terminiert NUR die eigene Session,
  nie eine fremde. **Ehrliche Grenze:** dieser Konflikt ist keine Design-
  Wahl, sondern ein echtes Discord-Protokoll-Limit — Nostrums Voice-API
  (`join_channel/leave_channel/get_ssrc_map`) ist selbst guild-skaliert, ein
  Bot-Account kann pro Guild nur in einem Voice-Channel gleichzeitig sein.
  """

  require Logger

  @doc """
  Startet (idempotent) eine Voice-Session für die gegebene Kampagne/Guild.

  - `{:ok, guild_id}` — Session läuft (neu gestartet ODER bereits von
    DERSELBEN Kampagne gehalten, z.B. Doppel-Aufruf).
  - `:conflict` — die Guild ist bereits von einer ANDEREN Kampagne belegt
    (Discord-Protokoll-Limit: ein Bot kann pro Guild nur in einem
    Voice-Channel gleichzeitig sein). Laut geloggt + `/admin/errors`.
  - `:error` — Start fehlgeschlagen (z.B. kein `Nostrum.Bot` verbunden).
    Laut geloggt, nie propagiert.
  """
  @spec maybe_start_voice_session(Worker.Discord.VoiceSession.cfg()) ::
          {:ok, non_neg_integer()} | :conflict | :error
  def maybe_start_voice_session(cfg) do
    case Registry.lookup(Worker.Discord.Registry, cfg.guild_id) do
      [{_pid, %{campaign_id: campaign_id}}] when campaign_id == cfg.campaign_id ->
        {:ok, cfg.guild_id}

      [{_pid, %{campaign_id: other_campaign_id, voice_channel_id: other_channel_id}}] ->
        Logger.error(
          "Worker.Discord.BotSupervisor: Guild #{cfg.guild_id} ist bereits mit Channel " <>
            "#{other_channel_id} belegt (Kampagne #{other_campaign_id}) — Kampagne " <>
            "#{cfg.campaign_id} bekommt KEINEN Bot (ein Discord-Bot kann pro Guild nur " <>
            "einem Voice-Channel gleichzeitig beitreten)."
        )

        Worker.Recording.Pipeline.publish_pipeline_error(
          cfg.campaign_id,
          "discord_voice",
          cfg.session_id,
          :discord_guild_busy,
          "Discord-Guild #{cfg.guild_id} ist bereits mit Voice-Channel #{other_channel_id} " <>
            "belegt (Kampagne #{other_campaign_id})."
        )

        :conflict

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Worker.Discord.VoiceSession, cfg}) do
          {:ok, _pid} ->
            {:ok, cfg.guild_id}

          {:error, reason} ->
            Logger.error(
              "Worker.Discord.BotSupervisor: Start fehlgeschlagen campaign=#{cfg.campaign_id} " <>
                "guild=#{cfg.guild_id}: #{inspect(reason)}"
            )

            :error
        end
    end
  end

  @doc """
  Stoppt (idempotent) die Voice-Session einer Guild — NUR wenn `campaign_id`
  tatsächlich der Besitzer ist (Issue #987). Gehört die laufende Session
  einer ANDEREN Kampagne, wird sie NICHT angefasst — No-op, kein Kill einer
  fremden Session. No-op auch wenn keine Session läuft.
  """
  @spec stop_voice_session(non_neg_integer(), String.t()) :: :ok
  def stop_voice_session(guild_id, campaign_id) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, %{campaign_id: ^campaign_id}}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [{_pid, %{campaign_id: _other}}] -> :ok
      [] -> :ok
    end

    :ok
  end
end
