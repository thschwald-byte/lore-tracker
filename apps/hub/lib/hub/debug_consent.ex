defmodule Hub.DebugConsent do
  @moduledoc """
  Issue #144: ETS-backed grant-Mechanismus für Admin-Debug-Endpoints.

  Ein User aktiviert in seinen Einstellungen "Debug-Zugriff" für N Minuten —
  das setzt einen Consent-Eintrag (`{target_did, expires_at}`). Solange der
  Eintrag valid ist, darf ein Admin via `HubWeb.DebugController` LV-State +
  Permission-Matrix für diesen User abrufen.

  Implementation:
  - ETS-Tabelle `:hub_debug_consent` (named, public read, protected write).
  - GenServer hält die Tabelle + scheduled `send_after`-Wakeups pro Grant
    für Auto-Expire-Cleanup.
  - PubSub-Broadcast bei jedem Statuswechsel (`grant`/`revoke`/`expire`),
    damit die EinstellungenLive den UI-Countdown live updaten kann.

  Hub-stateless (Issue #164): bewusst RAM-only, kein Postgres-Persist.
  Restart-Verlust ist akzeptiert — bei Hub-Restart verlieren alle aktiven
  Grants ihre Gültigkeit (User aktiviert ggf. erneut).
  """

  use GenServer

  require Logger

  @table :hub_debug_consent
  @topic "debug_consent"

  # ─── Public API ──────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "PubSub-Topic für UI-Live-Updates der Consent-Anzeige."
  def topic, do: @topic

  @doc """
  Gewährt Debug-Zugriff für `target_did` für `duration_seconds`. Überschreibt
  einen bestehenden Grant.
  """
  @spec grant(String.t(), pos_integer()) :: :ok
  def grant(target_did, duration_seconds)
      when is_binary(target_did) and is_integer(duration_seconds) and duration_seconds > 0 do
    GenServer.call(__MODULE__, {:grant, target_did, duration_seconds})
  end

  @doc "Widerruft einen aktiven Grant. No-op wenn keiner aktiv ist."
  @spec revoke(String.t()) :: :ok
  def revoke(target_did) when is_binary(target_did) do
    GenServer.call(__MODULE__, {:revoke, target_did})
  end

  @doc "True wenn `target_did` aktuell einen valid Consent-Eintrag hat."
  @spec valid?(String.t()) :: boolean()
  def valid?(target_did) when is_binary(target_did) do
    case :ets.lookup(@table, target_did) do
      [{^target_did, expires_at}] -> DateTime.compare(expires_at, DateTime.utc_now()) == :gt
      [] -> false
    end
  end

  @doc """
  Status-Lookup für UI-Anzeige. Returns `nil` wenn kein Grant, sonst
  `%{granted_at, expires_at}`.
  """
  @spec status(String.t()) :: nil | %{expires_at: DateTime.t()}
  def status(target_did) when is_binary(target_did) do
    case :ets.lookup(@table, target_did) do
      [{^target_did, expires_at}] ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          %{expires_at: expires_at}
        else
          nil
        end

      [] ->
        nil
    end
  end

  # ─── GenServer callbacks ─────────────────────────────────────────

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table, timers: %{}}}
  end

  @impl true
  def handle_call({:grant, did, duration_seconds}, _from, state) do
    expires_at = DateTime.utc_now() |> DateTime.add(duration_seconds, :second)

    :ets.insert(@table, {did, expires_at})

    state = cancel_timer(state, did)
    timer_ref = Process.send_after(self(), {:expire, did}, duration_seconds * 1_000)
    state = put_in(state.timers[did], timer_ref)

    Logger.info("DebugConsent: granted did=#{did} for #{duration_seconds}s")
    broadcast({:granted, did, expires_at})

    {:reply, :ok, state}
  end

  def handle_call({:revoke, did}, _from, state) do
    :ets.delete(@table, did)
    state = cancel_timer(state, did)

    Logger.info("DebugConsent: revoked did=#{did}")
    broadcast({:revoked, did})

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:expire, did}, state) do
    :ets.delete(@table, did)
    state = update_in(state.timers, &Map.delete(&1, did))

    Logger.info("DebugConsent: expired did=#{did}")
    broadcast({:expired, did})

    {:noreply, state}
  end

  # ─── Internal ─────────────────────────────────────────────────────

  defp cancel_timer(state, did) do
    case Map.get(state.timers, did) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        update_in(state.timers, &Map.delete(&1, did))
    end
  end

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Hub.PubSub, @topic, msg)
end
