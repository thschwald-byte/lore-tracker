defmodule Hub.PromptPreview do
  @moduledoc """
  Issue #313: holt die Prompt-Vorschau-Segmente einer Stage vom Worker
  (`preview_request`/`preview_response`-Round-Trip, analog `Hub.Reader`).

  Best-effort, single attempt — die Vorschau ist eine UI-Annehmlichkeit für
  den Stil-Editor, kein kritischer Pfad. Bei `{:error, _}` zeigt der LV einen
  Hinweis statt der Segmente.

  Segmente kommen als JSON-Maps zurück: `%{"kind" => "locked", "text" => ...}`
  oder `%{"kind" => "editable", "slot" => "base"|..., "text" => ...}`.
  """

  use GenServer

  require Logger

  @timeout 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec preview(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def preview(campaign_id, stage) when is_binary(campaign_id) and is_binary(stage) do
    GenServer.call(__MODULE__, {:preview, campaign_id, stage}, @timeout + 500)
  end

  @doc "Called by WorkerChannel when a preview_response arrives."
  def handle_response(request_id, segments) do
    GenServer.cast(__MODULE__, {:response, request_id, segments})
  end

  # ─── GenServer ────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_call({:preview, cid, stage}, from, state) do
    case workers_sorted() do
      [] ->
        {:reply, {:error, :no_worker}, state}

      [{_id, meta} | _] ->
        rid = new_request_id()
        send(meta.channel_pid, {:preview_request, cid, stage, rid, self()})
        timer = Process.send_after(self(), {:timeout, rid}, @timeout)
        {:noreply, %{state | pending: Map.put(state.pending, rid, %{from: from, timer: timer})}}
    end
  end

  @impl true
  def handle_cast({:response, rid, segments}, state) do
    case Map.pop(state.pending, rid) do
      {nil, _} ->
        {:noreply, state}

      {entry, rest} ->
        cancel_timer(entry.timer)
        GenServer.reply(entry.from, {:ok, segments})
        {:noreply, %{state | pending: rest}}
    end
  end

  @impl true
  def handle_info({:timeout, rid}, state) do
    case Map.pop(state.pending, rid) do
      {nil, _} ->
        {:noreply, state}

      {entry, rest} ->
        GenServer.reply(entry.from, {:error, :timeout})
        {:noreply, %{state | pending: rest}}
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────

  defp workers_sorted do
    Hub.WorkerRegistry.list()
    |> Enum.sort_by(fn {_, m} -> m.applied_seq end, :desc)
  end

  defp new_request_id do
    12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
