defmodule Hub.Reader do
  @moduledoc """
  Coordinates `snapshot_request`/`snapshot_response` round-trips between
  Hub-side callers (LiveViews) and connected workers.

  - `read/2` picks the most-up-to-date connected worker from
    `Hub.WorkerRegistry`, generates a request_id, hands the request to
    that worker's channel pid, and blocks until the worker pushes a
    `snapshot_response` back (or the timeout fires).
  - LiveView callers should treat `{:error, :no_worker}` as the
    "Warte auf Worker" condition.

  ## Issue #146: Worker-Iteration

  Wenn der gewählte Worker mit `%{"forbidden" => true}` oder
  `%{"not_found" => true}` antwortet (oder gar nicht in `@per_attempt_timeout`
  ms), probiert der Reader automatisch den nächsten Worker (sortiert nach
  `applied_seq` desc). Maximal `@max_attempts` Versuche. Damit kann
  Spielleiter X auch einladen wenn ihr „eigener" Worker offline ist und
  ein anderer connecter Worker die Campaign via Pull-Sync materialisiert
  hat.

  Bei single-Worker-Setup keine Verhaltens-Änderung: eine Iteration,
  gesamter Maximal-Wait `@max_attempts * @per_attempt_timeout` ms.

  ## Issue #366: deterministische Worker-Wahl pro Viewer

  Die Kandidaten-Reihenfolge ist deterministisch (`applied_seq` desc, Tie-Breaker
  `id` asc — identisch zu `Hub.Commands.pick_leader`). Damit „switcht" eine
  per-User-LiveView nicht mehr zwischen zwei Reloads zwischen verschiedenen
  Workern. Zwei Targeting-Opts steuern die Reihenfolge:

  - `worker_id:` (binary) — **Hard-Pin** auf genau diesen Worker (ein Kandidat,
    kein Fallback). Für per-Worker-lokalen State wie `/settings` (Issue #451),
    wo ein Fallback auf einen *fremden* Worker semantisch falsch wäre.
  - `prefer_discord_id:` (binary) — **prefer-own-fallback-to-rest**: die Worker
    des Viewers (`admin_discord_id`-Match) zuerst, der Rest als Fallback-Kaskade.
    Für Admin-Views (`/admin/users|spend|errors|jobs|probelauf`), die bevorzugt
    den eigenen Worker lesen, aber bei dessen Ausfall verfügbar bleiben sollen.

  Ohne beide Opts: die deterministisch sortierte Voll-Liste (unverändertes
  Default-Verhalten, nur ohne die frühere instabile Insertion-Order).
  """

  use GenServer

  require Logger

  # Issue #50: per_attempt 1500ms war zu eng wenn der Worker gerade unter
  # Ollama-Last steht (z.B. parallel laufender Pipeline auf einer anderen
  # PR-Test-Instance). 5000ms ist die neue Untergrenze.
  @max_attempts 3
  @per_attempt_timeout 5_000
  @default_timeout @max_attempts * @per_attempt_timeout

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec read(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(scope, opts \\ []) when is_map(scope) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    # Issue #366: nur die Targeting-Keys an den GenServer reichen.
    pick_opts = Keyword.take(opts, [:worker_id, :prefer_discord_id])
    GenServer.call(__MODULE__, {:read, scope, pick_opts, timeout}, timeout + 500)
  end

  @doc "Called by WorkerChannel when a snapshot_response arrives."
  def handle_response(request_id, payload) do
    GenServer.cast(__MODULE__, {:response, request_id, payload})
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_call({:read, scope, pick_opts, _timeout}, from, state) do
    case pick_workers(pick_opts) do
      [] ->
        {:reply, {:error, :no_worker}, state}

      [first | rest] ->
        request_id = new_request_id()
        send_to_worker(first, scope, request_id)
        timer = Process.send_after(self(), {:timeout, request_id}, @per_attempt_timeout)

        entry = %{
          from: from,
          remaining: rest,
          scope: scope,
          timer: timer,
          attempts_left: @max_attempts - 1
        }

        {:noreply, %{state | pending: Map.put(state.pending, request_id, entry)}}
    end
  end

  @impl true
  def handle_cast({:response, request_id, payload}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        # Late response nach Timeout / abgeschlossener Iteration — drop.
        {:noreply, state}

      {entry, pending_map} ->
        cancel_timer(entry.timer)

        if retryable?(payload) and entry.attempts_left > 0 and entry.remaining != [] do
          retry(entry, payload, %{state | pending: pending_map})
        else
          GenServer.reply(entry.from, {:ok, payload})
          {:noreply, %{state | pending: pending_map}}
        end
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        {:noreply, state}

      {entry, pending_map} ->
        if entry.attempts_left > 0 and entry.remaining != [] do
          # Bei Timeout auch den nächsten Worker probieren — vielleicht
          # ist der vorige nur gerade beschäftigt.
          retry(entry, :timeout, %{state | pending: pending_map})
        else
          GenServer.reply(entry.from, {:error, :timeout})
          {:noreply, %{state | pending: pending_map}}
        end
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────

  defp pick_workers(opts), do: order_candidates(Hub.WorkerRegistry.list(), opts)

  @doc """
  Issue #366: ordnet die Worker-Kandidaten für einen Read.

  Pure Funktion (testbar ohne `Phoenix.Tracker`). `workers` ist die Liste der
  `{worker_id, meta}`-Tupel aus `Hub.WorkerRegistry.list/0`.

  - `worker_id:` → Hard-Filter auf genau diesen Worker (Issue #451, kein Fallback).
  - `prefer_discord_id:` → eigene Worker (admin_discord_id-Match) zuerst, Rest als
    Fallback-Kaskade.
  - sonst → deterministisch sortierte Voll-Liste.

  Sortierung überall `{-applied_seq, id}` (frischester zuerst, Tie-Breaker `id`) —
  identisch zu `Hub.Commands.pick_leader`, damit dieselbe LiveView zwischen Reloads
  nicht zwischen Workern springt.
  """
  @spec order_candidates([{binary(), map()}], keyword()) :: [{binary(), map()}]
  def order_candidates(workers, opts \\ []) do
    sorted = Enum.sort_by(workers, fn {id, m} -> {-Map.get(m, :applied_seq, 0), id} end)

    cond do
      worker_id = Keyword.get(opts, :worker_id) ->
        Enum.filter(sorted, fn {id, _} -> id == worker_id end)

      did = Keyword.get(opts, :prefer_discord_id) ->
        {own, rest} = Enum.split_with(sorted, fn {_, m} -> m[:admin_discord_id] == did end)
        own ++ rest

      true ->
        sorted
    end
  end

  defp send_to_worker({_worker_id, meta}, scope, request_id) do
    send(meta.channel_pid, {:snapshot_request, scope, request_id, self()})
  end

  defp new_request_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp retryable?(%{"forbidden" => true}), do: true
  defp retryable?(%{"not_found" => true}), do: true
  defp retryable?(_), do: false

  defp retry(entry, reason, state) do
    [next | rest] = entry.remaining
    new_request_id = new_request_id()
    send_to_worker(next, entry.scope, new_request_id)
    timer = Process.send_after(self(), {:timeout, new_request_id}, @per_attempt_timeout)

    Logger.debug(
      "Hub.Reader retry: reason=#{inspect(reason)} attempts_left=#{entry.attempts_left - 1}"
    )

    new_entry = %{
      from: entry.from,
      remaining: rest,
      scope: entry.scope,
      timer: timer,
      attempts_left: entry.attempts_left - 1
    }

    {:noreply, %{state | pending: Map.put(state.pending, new_request_id, new_entry)}}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
