defmodule Worker.Recording.Recorder do
  @moduledoc """
  Per-campaign recording state tracker.

  Tracks at most one active recording per campaign:
  `%{session_id, campaign_id, campaign_name, owner_discord_id, started_at}`.
  The Hub UI REC button (via `HubClient`) calls into here. Starting emits
  `SessionScheduled` + `SessionStarted`; stopping triggers
  `Worker.Recording.AudioBuffer.finalize/1`, which transcribes per-player
  audio and then emits `SessionEnded` (so the pipeline only runs once all
  utterances are in the event log).

  Audio capture is browser-mic based (M10-BMP): each player streams their
  own mic from the Hub browser UI. This module is purely session
  bookkeeping — no audio plumbing.

  Issue #987 (Nachtrag zu #985): der Discord-Bot-Join ist KEIN automatischer
  Session-Start-Effekt mehr, sondern eine explizite, EINMALIGE Session-Wahl
  (`choose_capture_mode/3`, ausgelöst über die 3 Start-Buttons Discord/
  Single/Multi im Hub) — Discord schließt Browser-Mikro für die ganze
  Session aus und umgekehrt. `maybe_start_discord_bot/2` bleibt best-effort:
  Fehler dort sperren nur den Discord-Pfad selbst, nie den Kern-Recording.
  """

  use GenServer

  require Logger

  alias Worker.{Intents, Recording.AudioBuffer}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # ─── API (Hub UI path) ────────────────────────────────────────────

  @doc """
  Begin recording. Returns:
  - `{:ok, %{campaign_id, campaign_name, session_id, owner_discord_id, started_at}}`
  - `{:error, :already_recording, existing}`
  - `{:error, :campaign_not_found}`
  - `{:error, :not_authorized}` — caller ist nicht `:spielleiter` der Kampagne (per-Campaign-Membership, nicht abgeleitetes `owner_discord_id`)
  """
  def start_for_owner(discord_id, campaign_id, mode \\ :default) do
    GenServer.call(__MODULE__, {:start, discord_id, campaign_id, mode}, 10_000)
  end

  @doc "Stop the active recording for `campaign_id`. Returns `{:ok, info}` or `{:error, :not_recording}`."
  def stop_for_campaign(campaign_id) do
    GenServer.call(__MODULE__, {:stop, campaign_id}, 10_000)
  end

  @doc """
  Issue #987: setzt EINMAL pro Session den Aufnahme-Modus (`:discord` oder
  `:browser`) — die 3 Start-Buttons (Discord/Single/Multi) im Hub feuern das
  bei Klick. Discord schließt Browser-Mikro (single+multi) für die ganze
  Session aus, und umgekehrt (echtes Discord-Protokoll-Limit + Vermeidung
  kollidierender Audio-Quellen).

  Returns:
  - `{:ok, mode}` — Modus neu gesetzt ODER erneuter Klick auf denselben
    Modus (idempotent).
  - `{:error, :already_chosen, existing_mode}` — ein ANDERER Modus läuft
    schon.
  - `{:error, :not_recording}` — keine aktive Session für diese Kampagne.
  - `{:error, :discord_unavailable}` — `:discord` gewählt, aber der
    Bot-Join scheiterte (kein Token/Config/Nostrum.Bot, oder Guild-Konflikt
    mit einer anderen Kampagne, s. `BotSupervisor`) — dann bleibt KEIN
    Modus gesetzt, die Buttons bleiben für einen erneuten Versuch offen.
  """
  def choose_capture_mode(discord_id, campaign_id, mode) when mode in [:discord, :browser] do
    GenServer.call(__MODULE__, {:choose_capture_mode, discord_id, campaign_id, mode}, 10_000)
  end

  @doc "All currently-active recordings, keyed by campaign_id."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Get the active entry for a campaign, or nil."
  def get(campaign_id), do: GenServer.call(__MODULE__, {:get, campaign_id})

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{by_campaign: %{}}}

  @impl true
  def handle_call({:start, caller_discord_id, campaign_id, mode}, _from, state) do
    if Map.has_key?(state.by_campaign, campaign_id) do
      {:reply, {:error, :already_recording, state.by_campaign[campaign_id]}, state}
    else
      with {:ok, campaign} <- resolve_campaign(campaign_id, caller_discord_id),
           {:ok, session_id} <- create_and_start_session(campaign) do
        entry = %{
          campaign_id: campaign.id,
          campaign_name: campaign.name,
          session_id: session_id,
          owner_discord_id: caller_discord_id,
          started_at: DateTime.utc_now()
        }

        case AudioBuffer.open_session(session_id, campaign.id, mode) do
          :ok ->
            Logger.info(
              "Recorder: started session=#{session_id} campaign=#{campaign.id} owner=#{caller_discord_id}"
            )

            # Issue #987: kein automatischer Discord-Bot-Join mehr beim Session-
            # Start — der Aufnahme-Modus (Discord | Browser) ist jetzt eine
            # explizite Wahl über die 3 Start-Buttons (s. choose_capture_mode/3).
            # `discord_guild_id` bleibt bis dahin nil.
            entry = Map.put(entry, :discord_guild_id, nil)

            {:reply, {:ok, entry},
             %{state | by_campaign: Map.put(state.by_campaign, campaign_id, entry)}}

          {:error, reason} = err ->
            Logger.error(
              "Recorder: AudioBuffer.open_session refused session=#{session_id} (#{inspect(reason)})"
            )

            {:reply, err, state}
        end
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:stop, campaign_id}, _from, state) do
    case Map.pop(state.by_campaign, campaign_id) do
      {nil, _} ->
        {:reply, {:error, :not_recording}, state}

      {entry, rest} ->
        # finalize/1 is async: it closes writers, runs whisper-cli per file,
        # emits UtteranceAppended events, and finally emits SessionEnded.
        :ok = AudioBuffer.finalize(entry.session_id)
        maybe_stop_discord_bot(entry[:discord_guild_id], entry.campaign_id)

        Logger.info(
          "Recorder: stopped session=#{entry.session_id} campaign=#{campaign_id} (transcription pending)"
        )

        {:reply, {:ok, entry}, %{state | by_campaign: rest}}
    end
  end

  def handle_call({:choose_capture_mode, discord_id, campaign_id, mode}, _from, state) do
    case Map.get(state.by_campaign, campaign_id) do
      nil ->
        {:reply, {:error, :not_recording}, state}

      entry ->
        wire_mode = Atom.to_string(mode)

        case Worker.Repo.get_session_capture_mode(entry.session_id) do
          nil -> apply_capture_mode(state, entry, discord_id, campaign_id, mode)
          ^wire_mode -> {:reply, {:ok, mode}, state}
          existing -> {:reply, {:error, :already_chosen, existing}, state}
        end
    end
  end

  def handle_call(:list, _from, state), do: {:reply, state.by_campaign, state}

  def handle_call({:get, campaign_id}, _from, state),
    do: {:reply, Map.get(state.by_campaign, campaign_id), state}

  # ─── Helpers ──────────────────────────────────────────────────────

  # Issue #987: "browser" braucht keinen Verbindungsversuch — nur publishen.
  # "discord" versucht ERST den Bot-Join; scheitert der, wird NICHTS publisht
  # (der Modus bleibt offen, die Buttons stehen für einen erneuten Versuch).
  defp apply_capture_mode(state, entry, discord_id, campaign_id, :browser) do
    publish_capture_mode!(entry, discord_id, campaign_id, "browser")
    {:reply, {:ok, :browser}, state}
  end

  defp apply_capture_mode(state, entry, discord_id, campaign_id, :discord) do
    case maybe_start_discord_bot(campaign_id, entry.session_id) do
      nil ->
        # Issue #987: der GM hat Discord GEZIELT gewählt (kein automatischer
        # Best-Effort-Versuch mehr, s. #985) — ein stiller Fehlschlag hier
        # wäre für den GM nicht von "Bot joint gleich" zu unterscheiden.
        # Anders als BotSupervisors :conflict-Fall (der schon publisht) ist
        # dieser Zweig (kein Token/keine Config/Bot nicht verbunden) bisher
        # NIRGENDS sichtbar (Stage-D-Moduledoc-Lücke) — hier erstmalig
        # geschlossen, mit der wahrscheinlichsten Ursache in der Message.
        publish_discord_unavailable_error(entry, campaign_id)
        {:reply, {:error, :discord_unavailable}, state}

      guild_id ->
        publish_capture_mode!(entry, discord_id, campaign_id, "discord")
        updated_entry = Map.put(entry, :discord_guild_id, guild_id)

        {:reply, {:ok, :discord},
         %{state | by_campaign: Map.put(state.by_campaign, campaign_id, updated_entry)}}
    end
  end

  defp publish_discord_unavailable_error(entry, campaign_id) do
    reason =
      cond do
        Worker.Discord.BotToken.status() == :unset ->
          "kein Discord-Bot-Token konfiguriert (Worker-Settings → Discord-Bot)"

        match?(%{"guild_id" => nil}, Worker.Repo.get_campaign_discord_config(campaign_id)) ->
          "keine Discord-Guild/Voice-Channel-Config für diese Kampagne hinterlegt"

        true ->
          "Discord-Bot-Prozess nicht verbunden (Token evtl. erst nach dem letzten " <>
            "Worker-Neustart gesetzt) — Worker-Log prüfen"
      end

    Worker.Recording.Pipeline.publish_pipeline_error(
      campaign_id,
      "discord_voice",
      entry.session_id,
      :discord_unavailable,
      "Discord-Bot-Beitritt fehlgeschlagen: #{reason}."
    )
  end

  defp publish_capture_mode!(entry, discord_id, campaign_id, mode) do
    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_capture_mode_set(),
        "session_id" => entry.session_id,
        "campaign_id" => campaign_id,
        "mode" => mode,
        "set_by" => discord_id
      })

    :ok
  end

  defp resolve_campaign(campaign_id, caller_discord_id) when is_binary(campaign_id) do
    case Worker.Repo.get_campaign(campaign_id) do
      nil ->
        {:error, :campaign_not_found}

      c ->
        case Worker.Repo.campaign_role(campaign_id, caller_discord_id) do
          :spielleiter -> {:ok, c}
          _ -> {:error, :not_authorized}
        end
    end
  end

  # Issue #985 Slice 1 (Stage E): best-effort Bot-Voice-Join, analog
  # `best_effort_artifact/5` der Wahrheitsbild-Pipeline — ein Fehler hier darf
  # den Kern-Recording-Start nie blockieren (Browser-Mic bleibt der primäre,
  # unabhängige Aufnahme-Pfad). No-op, wenn kein Discord-Config gesetzt ODER
  # kein Bot-Token konfiguriert ist — rein additive Funktionalität. Liefert
  # die Guild-ID (Integer) NUR zurück, wenn diese Kampagne die Session
  # TATSÄCHLICH besitzt (Issue #987 — vorher wurde die Guild-ID auch bei
  # einem `:conflict`/`:error` unbedingt zurückgegeben, wodurch der spätere
  # Stop eine FREMDE Kampagnen-Session hätte killen können). `nil` für den
  # symmetrischen Stop-Teardown, wenn kein eigener Bot lief.
  # `def` statt `defp` (mit `@doc false`) — direkt testbar ohne vollen
  # Recording-Start (Muster `Worker.Application.migrate_stage2_to_stage34_if_unset!/0`).
  @doc false
  def maybe_start_discord_bot(campaign_id, session_id) do
    with {:unset, false} <- {:unset, Worker.Discord.BotToken.status() == :unset},
         %{"guild_id" => guild_id, "voice_channel_id" => voice_channel_id}
         when is_binary(guild_id) and is_binary(voice_channel_id) <-
           Worker.Repo.get_campaign_discord_config(campaign_id),
         {guild_id_int, ""} <- Integer.parse(guild_id),
         {voice_channel_id_int, ""} <- Integer.parse(voice_channel_id) do
      case Worker.Discord.BotSupervisor.maybe_start_voice_session(%{
             campaign_id: campaign_id,
             session_id: session_id,
             guild_id: guild_id_int,
             voice_channel_id: voice_channel_id_int
           }) do
        {:ok, guild_id_int} -> guild_id_int
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp maybe_stop_discord_bot(nil, _campaign_id), do: :ok

  defp maybe_stop_discord_bot(guild_id, campaign_id),
    do: Worker.Discord.BotSupervisor.stop_voice_session(guild_id, campaign_id)

  defp create_and_start_session(campaign) do
    session_id = UUIDv7.generate()
    number = Worker.Repo.next_session_number(campaign.id)

    {:ok, _} =
      Intents.publish(%{
        "kind" => Shared.Events.session_scheduled(),
        "id" => session_id,
        "campaign_id" => campaign.id,
        "number" => number,
        "name" => "Session #{number}",
        "scheduled_for" => nil
      })

    {:ok, _} =
      Intents.publish(%{"kind" => Shared.Events.session_started(), "id" => session_id})

    {:ok, session_id}
  end
end
