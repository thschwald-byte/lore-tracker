defmodule Worker.Recording.AudioBuffer.Presence do
  @moduledoc """
  Streamer-Presence + Stille-Watchdog für `Worker.Recording.AudioBuffer`
  (Issues #392/#399), extrahiert aus dem AudioBuffer-God-Module (#544-Check).

  Rein funktional auf der per-Session `sess`-Map (Feld `last_chunk_at`,
  `streamers_broadcast`, `silent_streamers`) + PubSub-Seiteneffekte über den
  `HubClient` — kein GenServer-State, keine Timer. Der AudioBuffer ruft diese
  Funktionen aus `write_chunk`/`sweep_ghosts`/`drop_streamer`/`finalize`.
  """

  alias Worker.HubClient

  # Issue #392: Chunk-Recency-Liveness. Ein Streamer gilt als "weg", wenn seit
  # >@ghost_timeout_ms kein Audio-Chunk mehr kam (= 8 verpasste 500ms-Chunks).
  @ghost_timeout_ms 4_000

  @doc """
  Meldet dem Hub die aktuell in `session_id` streamenden discord_ids
  (`mic_streamers`-pipeline_status). Von open_session/finalize direkt +
  intern von `maybe_broadcast_streamers/2` genutzt.
  """
  def publish_streamers(campaign_id, session_id, discord_ids) do
    HubClient.publish_status(%{
      "kind" => "mic_streamers",
      "campaign_id" => campaign_id,
      "session_id" => session_id,
      "discord_ids" => discord_ids
    })
  end

  @doc """
  Issue #392: frische Streamer = Keys in `last_chunk_at`, deren letzter Chunk
  nicht älter als @ghost_timeout_ms ist. Sortiert für stabilen Vergleich.
  """
  def fresh_streamers(sess, now \\ nil) do
    now = now || now_ms()

    sess
    |> Map.get(:last_chunk_at, %{})
    |> Enum.filter(fn {_key, ts} -> now - ts <= @ghost_timeout_ms end)
    |> Enum.map(fn {key, _ts} -> key end)
    |> Enum.sort()
  end

  @doc """
  Berechnet den frischen Set und broadcastet NUR wenn er sich gegenüber dem
  zuletzt gebroadcasteten unterscheidet (Wachstum durch neuen Streamer,
  Shrinkage durch expirten Ghost). Idempotent — gibt die ggf. mit dem neuen
  `streamers_broadcast` aktualisierte Session zurück.
  """
  def maybe_broadcast_streamers(session_id, sess) do
    fresh = fresh_streamers(sess)

    if fresh == sess.streamers_broadcast do
      sess
    else
      publish_streamers(sess.campaign_id, session_id, fresh)
      %{sess | streamers_broadcast: fresh}
    end
  end

  @doc """
  Issue #399: Server-side Stille-Watchdog. Pro Streamer (key in `last_chunk_at`)
  prüfen, ob die Lücke seit dem letzten Chunk >= silence_threshold ist.
  Edge-Trigger:
  - frisch → über Schwelle: `streamer_silent` pipeline_status raus,
    discord_id in `silent_streamers`-Set ablegen.
  - silent-Set → wieder frisch (last_chunk_at < Schwelle): `streamer_recovered`
    raus, discord_id aus Set raus.
  Keine Wiederholung — der Set verhindert Spam bei jedem Sweep-Tick.
  """
  def check_silence(session_id, sess) do
    threshold_ms = Worker.Settings.get(:silence_alert_threshold_ms, 300_000)
    now = now_ms()
    last_at = Map.get(sess, :last_chunk_at, %{})
    silent_before = Map.get(sess, :silent_streamers, MapSet.new())

    {silent_after, _} =
      Enum.reduce(last_at, {silent_before, sess}, fn {key, ts}, {set, _} ->
        gap = now - ts
        was_silent? = MapSet.member?(set, key)
        is_silent? = gap >= threshold_ms

        cond do
          # Übergang frisch → silent
          is_silent? and not was_silent? ->
            publish_silence_status(sess.campaign_id, session_id, key, gap, :silent)
            {MapSet.put(set, key), sess}

          # Übergang silent → frisch (Recovery: nächster Chunk landet vor
          # Schwelle wieder)
          not is_silent? and was_silent? ->
            publish_silence_status(sess.campaign_id, session_id, key, gap, :recovered)
            {MapSet.delete(set, key), sess}

          true ->
            {set, sess}
        end
      end)

    %{sess | silent_streamers: silent_after}
  end

  defp publish_silence_status(campaign_id, session_id, discord_id, silent_for_ms, state)
       when state in [:silent, :recovered] do
    kind =
      case state do
        :silent -> "streamer_silent"
        :recovered -> "streamer_recovered"
      end

    HubClient.publish_status(%{
      "kind" => kind,
      "campaign_id" => campaign_id,
      "session_id" => session_id,
      "discord_id" => discord_id,
      "silent_for_ms" => silent_for_ms
    })
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
