defmodule Hub.Telemetry do
  @moduledoc """
  Issue #238 Phase 1: strukturierte Telemetry-Lines im Logger für prod-
  Observability.

  Hängt sich an Phoenix-Built-In-Events (`[:phoenix, :endpoint, :stop]`,
  LiveView-Mount + handle_event, Channel-Joins + Messages) und an die zwei
  Hub-eigenen Event-Quellen `Hub.EventBridge` und `Hub.WorkerRegistry`.

  Output-Format: ein Logger.info pro relevanten Event in der Form
  `[telemetry] event=<dot.notation> key1=value1 key2=value2 ...`. Damit
  lassen sich aus den gigalixir-Logs (oder einem konfigurierten Drain
  wie Papertrail) Request-Rate, Latenz-Verteilung, Bridge-Publish-
  Erfolgsrate, Worker-Reconnects per `grep | awk` ableiten — ohne Grafana
  oder Prometheus.

  ## Events

  Phoenix:
  - `[:phoenix, :endpoint, :stop]` — pro HTTP-Request: route, status, duration_ms
  - `[:phoenix, :live_view, :mount, :stop]` — LiveView-Mount: lv, duration_ms
  - `[:phoenix, :live_view, :handle_event, :stop]` — LV-handle_event: lv, event, duration_ms
  - `[:phoenix, :channel_joined]` — Channel-Join: channel, topic, status
  - `[:phoenix, :channel_handled_in]` — Channel-Message: channel, topic, event, duration_ms

  Hub-eigen:
  - `[:hub, :event_bridge, :publish]` — EventBridge: kind, campaign_id, result (ok|no_worker_online), duration_ms
  - `[:hub, :worker_registry, :changed]` — Worker-Joins/Leaves: joins, leaves
  - `[:hub, :audio, :chunk_dropped]` — Audio-Chunk verloren (Issue #468): campaign_id, session_id, reason, bytes
  """

  require Logger

  @events [
    [:phoenix, :endpoint, :stop],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :channel_joined],
    [:phoenix, :channel_handled_in],
    [:hub, :event_bridge, :publish],
    [:hub, :worker_registry, :changed],
    [:hub, :audio, :chunk_dropped]
  ]

  @doc """
  Start-Funktion für den Supervisor. Stateless — registriert nur die
  Telemetry-Handlers und gibt `:ignore` zurück (kein laufender Prozess).
  """
  @spec start_link(any()) :: :ignore
  def start_link(_opts \\ []) do
    :telemetry.attach_many(
      "hub-telemetry-logger",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    Logger.info("Hub.Telemetry: attached #{length(@events)} event handlers")
    :ignore
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :stop], %{duration: duration}, meta, _config) do
    route = meta[:conn] && meta.conn.request_path
    method = meta[:conn] && meta.conn.method
    status = meta[:conn] && meta.conn.status

    log_event("phoenix.endpoint.stop",
      method: method,
      route: route,
      status: status,
      duration_ms: us_to_ms(duration)
    )
  end

  def handle_event([:phoenix, :live_view, :mount, :stop], %{duration: duration}, meta, _config) do
    log_event("phoenix.live_view.mount.stop",
      lv: meta[:socket] && inspect(meta.socket.view),
      duration_ms: us_to_ms(duration)
    )
  end

  def handle_event(
        [:phoenix, :live_view, :handle_event, :stop],
        %{duration: duration},
        meta,
        _config
      ) do
    log_event("phoenix.live_view.handle_event.stop",
      lv: meta[:socket] && inspect(meta.socket.view),
      event: meta[:event],
      duration_ms: us_to_ms(duration)
    )
  end

  def handle_event([:phoenix, :channel_joined], _measurements, meta, _config) do
    log_event("phoenix.channel_joined",
      channel: meta[:socket] && inspect(meta.socket.channel),
      topic: meta[:socket] && meta.socket.topic,
      result: meta[:result]
    )
  end

  def handle_event(
        [:phoenix, :channel_handled_in],
        %{duration: duration},
        meta,
        _config
      ) do
    log_event("phoenix.channel_handled_in",
      channel: meta[:socket] && inspect(meta.socket.channel),
      topic: meta[:socket] && meta.socket.topic,
      event: meta[:event],
      duration_ms: us_to_ms(duration)
    )
  end

  def handle_event([:hub, :event_bridge, :publish], measurements, meta, _config) do
    log_event("hub.event_bridge.publish",
      kind: meta[:kind],
      campaign_id: meta[:campaign_id],
      result: meta[:result],
      duration_ms: us_to_ms(measurements[:duration])
    )
  end

  def handle_event([:hub, :worker_registry, :changed], _measurements, meta, _config) do
    log_event("hub.worker_registry.changed",
      joins: meta[:joins],
      leaves: meta[:leaves]
    )
  end

  # Issue #468: Audio-Chunk-Drop ist seltener als Forward (nur bei no-member-
  # Worker), aber wichtig zu loggen. Forward selbst NICHT loggen — 500ms-
  # Spam würde das Log ersticken.
  def handle_event([:hub, :audio, :chunk_dropped], measurements, meta, _config) do
    log_event("hub.audio.chunk_dropped",
      campaign_id: meta[:campaign_id],
      session_id: meta[:session_id],
      reason: meta[:reason],
      bytes: measurements[:bytes]
    )
  end

  # ─── Internal ────────────────────────────────────────────────────

  defp log_event(event_name, fields) do
    formatted =
      fields
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
      |> Enum.join(" ")

    Logger.info("[telemetry] event=#{event_name} #{formatted}")
  end

  defp format_value(v) when is_binary(v), do: maybe_quote(v)
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp format_value(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &format_value/1) <> "]"
  defp format_value(v), do: inspect(v)

  defp maybe_quote(s) do
    if String.contains?(s, " "), do: ~s("#{s}"), else: s
  end

  defp us_to_ms(nil), do: nil

  defp us_to_ms(usec) when is_integer(usec) do
    # :native time-unit conversion: Phoenix-Telemetry-Durations sind in
    # :native, NICHT in :microsecond. Convert defensiv.
    System.convert_time_unit(usec, :native, :millisecond)
  end
end
