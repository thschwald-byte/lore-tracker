defmodule Worker.Discord.VoiceSession do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic), Stage D: per-Kampagne
  GenServer, der den Discord-Voice-Channel-Beitritt und -Austritt hält. Erste
  dynamische Prozess-Instanz in `apps/worker` (gestartet/gestoppt über
  `Worker.Discord.BotSupervisor`, ein `DynamicSupervisor`).

  Join-Sequenz + Nostrum-API-Signaturen sind am tatsächlichen #941-Spike-Code
  verifiziert (`Voice.join_channel/4` mit `self_mute=true, self_deaf=FALSE` —
  self_deaf MUSS false sein, sonst liefert Discord keine eingehenden Pakete;
  fixe Settle-Zeit vor `start_listen_async/1` statt einer Readiness-API, weil
  der Spike-Autor die für instabil auf nostrum-main hielt).

  **Crash-Semantik ist die Silent-Failure-Achse dieser Stage** (Plan-Review
  zu #985): stirbt dieser Prozess mitten in einer Aufnahme, läuft die
  Recording-Session unbemerkt ohne Discord-Audio weiter. `restart: :transient`
  (nur bei abnormalem Exit neu gestartet, nie bei explizitem `stop_for_campaign`)
  + `terminate/2` publisht bei abnormalem Exit ein `PipelineErrorLogged`-Event
  (Stage `"discord_voice"`) — sichtbar in `/admin/errors`, dieselbe Fehler-
  Taxonomie wie die Wahrheitsbild-Pipeline (`classify_pipeline_error/1`s
  generischer Atom-Fallback).

  **Bekannte Grenzen (v1, dokumentiert statt gelöst):**
  - Kein aktiver Liveness-Check ("kommen wirklich noch Pakete an") — nur
    Prozess-Crashes werden erkannt, ein stiller Discord-seitiger Verbindungs-
    abbruch ohne BEAM-Crash bliebe unbemerkt.
  - Ein fehlgeschlagener Join selbst (falscher Channel, fehlende Rechte) wird
    von Nostrums Fire-and-Forget-`join_channel/4` nicht synchron signalisiert —
    dieser Fall ist NICHT robust erkannt, nur ein daraus resultierender
    späterer Prozess-Crash würde über `terminate/2` sichtbar.
  - Eine Discord-Gateway-Session kann pro Guild nur einem Voice-Channel
    gleichzeitig beitreten — zwei Kampagnen auf derselben Guild mit
    gleichzeitiger Aufnahme können nicht beide bedient werden.
  - RAM-only: ein Worker-Neustart mitten in der Aufnahme verliert die Session
    ohne Re-Attach (kein Sync-Mechanismus wie bei Mnesia-State).
  """

  use GenServer

  require Logger

  alias Nostrum.Voice

  @join_settle_ms 3_000

  @type cfg :: %{
          campaign_id: String.t(),
          session_id: String.t(),
          guild_id: non_neg_integer(),
          voice_channel_id: non_neg_integer()
        }

  @spec via(non_neg_integer()) :: {:via, Registry, {Worker.Discord.Registry, non_neg_integer()}}
  def via(guild_id), do: {:via, Registry, {Worker.Discord.Registry, guild_id}}

  @spec start_link(cfg()) :: GenServer.on_start()
  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: via(cfg.guild_id))

  # restart: :transient — nur bei abnormalem Exit neu gestartet (Gateway-
  # Disconnect, Decode-Crash), NIE nach einem geplanten `stop_for_campaign`
  # (das ruft GenServer.stop/1 mit `:normal`, kein Restart).
  def child_spec(cfg) do
    %{
      id: {__MODULE__, cfg.guild_id},
      start: {__MODULE__, :start_link, [cfg]},
      restart: :transient
    }
  end

  @doc "Best-effort Forward eines empfangenen (bereits dave_decrypt'd) Opus-Frames."
  @spec incoming_packet(non_neg_integer(), non_neg_integer(), binary()) :: :ok
  def incoming_packet(guild_id, ssrc, opus) do
    case Registry.lookup(Worker.Discord.Registry, guild_id) do
      [{pid, _}] ->
        GenServer.cast(pid, {:packet, ssrc, opus, System.monotonic_time(:millisecond)})

      [] ->
        :ok
    end
  end

  @impl true
  def init(cfg) do
    Logger.info(
      "Worker.Discord.VoiceSession: join campaign=#{cfg.campaign_id} " <>
        "guild=#{cfg.guild_id} channel=#{cfg.voice_channel_id}"
    )

    # self_mute=true (Bot sendet nie eigene Audio) — self_deaf=false ist
    # zwingend (#941-Spike-Erkenntnis), sonst liefert Discord keine
    # eingehenden Pakete.
    Voice.join_channel(cfg.guild_id, cfg.voice_channel_id, true, false)
    timer_ref = Process.send_after(self(), :start_listen, @join_settle_ms)

    state =
      cfg
      |> Map.put(:listening?, false)
      |> Map.put(:session_start_ms, System.monotonic_time(:millisecond))
      |> Map.put(:start_listen_timer, timer_ref)

    {:ok, state}
  end

  @impl true
  def handle_info(:start_listen, state) do
    Voice.start_listen_async(state.guild_id)
    {:noreply, %{state | listening?: true}}
  end

  @impl true
  def handle_cast({:packet, _ssrc, _opus, _arrival_ms}, state) do
    # Stage F: Frame-Bridging in AudioBuffer.append/5 (via FrameBuffer für die
    # Zeitkorrektur) — noch nicht verdrahtet.
    {:noreply, state}
  end

  # Timer-Cleanup (Credo TimerWithoutCleanup, #544 Cut 2): der :start_listen-
  # Timer aus init/1 ist ein Ein-Schuss-Timer, sein Ziel-Prozess stirbt mit
  # jedem Exit ohnehin mit — cancel_timer ist hier reine Hygiene (die Message
  # würde sonst ins Leere laufen, kein echter State-Leak), aber die
  # projektweite Faustregel gilt unabhängig von der konkreten Risikohöhe.
  defp cancel_start_listen_timer(%{start_listen_timer: ref}) when is_reference(ref),
    do: Process.cancel_timer(ref)

  defp cancel_start_listen_timer(_state), do: :ok

  @impl true
  def terminate(:normal, state) do
    cancel_start_listen_timer(state)
    :ok
  end

  def terminate(:shutdown, state) do
    cancel_start_listen_timer(state)
    :ok
  end

  def terminate({:shutdown, _}, state) do
    cancel_start_listen_timer(state)
    :ok
  end

  def terminate(reason, state) do
    cancel_start_listen_timer(state)

    Logger.error(
      "Worker.Discord.VoiceSession: abnormaler Exit campaign=#{state.campaign_id} " <>
        "guild=#{state.guild_id}: #{inspect(reason)}"
    )

    Worker.Recording.Pipeline.publish_pipeline_error(
      state.campaign_id,
      "discord_voice",
      state.session_id,
      :discord_voice_session_crashed,
      "Discord-Voice-Session abgestürzt (guild=#{state.guild_id}): #{inspect(reason)}"
    )

    :ok
  end
end
