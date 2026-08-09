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
  """

  require Logger

  @doc """
  Startet (idempotent) eine Voice-Session für die gegebene Guild — No-op,
  wenn schon eine für diese Guild läuft (z.B. Doppel-Aufruf). Fehler werden
  geloggt, nie propagiert.
  """
  @spec maybe_start_voice_session(Worker.Discord.VoiceSession.cfg()) :: :ok
  def maybe_start_voice_session(cfg) do
    case Registry.lookup(Worker.Discord.Registry, cfg.guild_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Worker.Discord.VoiceSession, cfg}) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Worker.Discord.BotSupervisor: Start fehlgeschlagen campaign=#{cfg.campaign_id} " <>
                "guild=#{cfg.guild_id}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  @doc "Stoppt (idempotent) die Voice-Session einer Guild — No-op, wenn keine läuft."
  @spec stop_voice_session(non_neg_integer()) :: :ok
  def stop_voice_session(guild_id) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end

    :ok
  end
end
