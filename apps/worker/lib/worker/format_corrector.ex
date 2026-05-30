defmodule Worker.FormatCorrector do
  @moduledoc """
  Issue #289 Phase 3: Self-Correction Loop für Stage-Sampling-Temperatur.

  Pflegt pro Stage (2/3/4) ein Rolling-Window der letzten N `format_notes`
  (kommen aus #288: `"ok" | "think_stripped" | "fence_unwrapped" |
  "think_stripped|fence_unwrapped" | "parse_failed" | "timeout"`). Wenn
  die Non-OK-Rate im Window über einem Threshold liegt, wird die
  `temperature_stageN`-Setting um einen kleinen Schritt gesenkt (bis zu
  einem konfigurierbaren Minimum) und ein `param_adjusted`-Status-Event
  Richtung Hub gepublisht.

  Idee: nicht-ok-Output korreliert empirisch mit zu hoher Temperature
  (Anthropic/Ollama-Erkenntnisse, siehe Issue #289). Wenn das Modell
  systematisch Schrott liefert, ist Senken der Temperature der
  effektivste Hebel — automatisch und ohne User-Eingriff.

  ## Out of Scope

  - **Automatisches Erhöhen:** explizit out-of-scope per #289-Spec, nur
    Senken ist sinnvoll (zu niedrige Temperature schadet kaum, nur
    Output wird etwas eintöniger).
  - **Adjustierung anderer Parameter** (top_p, repeat_penalty): separates
    Ticket falls nötig.

  ## Settings (alle in `Worker.Settings`)

  - `:format_corrector_window_size` (Default `10`) — Anzahl der zuletzt
    beobachteten Notes pro Stage.
  - `:format_corrector_threshold` (Default `0.4`) — bei Non-OK-Rate >
    threshold wird angepasst.
  - `:format_corrector_step` (Default `0.05`) — wie stark gesenkt wird.
  - `:temperature_min_stage{2,3,4}` (Default `0.05`) — untere Grenze pro
    Stage.

  ## Skip-Filter

  Der Caller (`Worker.Recording.Pipeline.notify_status/4`) muss
  Probelauf-Eval-Campaigns vom Recording ausschließen — sonst würde ein
  laufender Probelauf-Sweep die Temperature unter sich selbst weg-
  ändern und die Mess-Ergebnisse korrumpieren.
  """

  use GenServer
  require Logger

  @stages [2, 3, 4]

  # ─── Public API ────────────────────────────────────────────────────

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Notiert eine `format_notes`-Beobachtung für eine Stage. Asynchron
  (Cast), blockiert den Pipeline-Hot-Path nicht.
  """
  @spec record(2 | 3 | 4, binary()) :: :ok
  def record(stage, notes) when stage in @stages and is_binary(notes) do
    GenServer.cast(__MODULE__, {:record, stage, notes})
  end

  def record(_, _), do: :ok

  @doc """
  Debug-Helper: aktueller Window-State.
  """
  def state, do: GenServer.call(__MODULE__, :state)

  # ─── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, Map.new(@stages, fn s -> {s, []} end)}
  end

  @impl true
  def handle_cast({:record, stage, notes}, state) do
    window_size = Worker.Settings.get(:format_corrector_window_size, 10)
    new_window = [notes | Map.get(state, stage, [])] |> Enum.take(window_size)
    state = Map.put(state, stage, new_window)

    maybe_adjust(stage, new_window, window_size)

    {:noreply, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  # ─── Adjustment-Logik ──────────────────────────────────────────────

  defp maybe_adjust(stage, window, window_size) when length(window) >= window_size do
    threshold = Worker.Settings.get(:format_corrector_threshold, 0.4)
    non_ok = Enum.count(window, fn n -> n != "ok" end)
    rate = non_ok / window_size

    if rate > threshold do
      attempt_decrement(stage, rate, window_size)
    end
  end

  defp maybe_adjust(_stage, _window, _ws), do: :ok

  defp attempt_decrement(stage, rate, window_size) do
    step = Worker.Settings.get(:format_corrector_step, 0.05)
    min_key = :"temperature_min_stage#{stage}"
    min_val = Worker.Settings.get(min_key, 0.05)
    temp_key = :"temperature_stage#{stage}"
    current = Worker.Settings.get(temp_key)

    cond do
      not is_number(current) ->
        :ok

      current <= min_val ->
        # Schon am Minimum — kein weiteres Senken möglich. Logger.info
        # damit man im Log sieht warum trotz schlechter Rate nichts mehr
        # passiert.
        Logger.info(
          "FormatCorrector: stage#{stage} an Minimum (#{current}) — non-ok #{trunc(rate * 100)}% bleibt"
        )

        :ok

      true ->
        new_val = max(Float.round(current - step, 2), min_val)

        if new_val < current do
          Worker.Settings.put(temp_key, new_val)

          Logger.info(
            "FormatCorrector: stage#{stage} temperature #{current} → #{new_val} " <>
              "(#{trunc(rate * 100)}% non-ok über #{window_size} Beobachtungen)"
          )

          publish_param_adjusted(temp_key, current, new_val, rate, window_size)
        end
    end
  end

  defp publish_param_adjusted(temp_key, old_val, new_val, rate, window_size) do
    Worker.HubClient.publish_status(%{
      "kind" => "param_adjusted",
      "param" => Atom.to_string(temp_key),
      "old_value" => old_val,
      "new_value" => new_val,
      "reason" => "format_error_rate",
      "non_ok_rate" => Float.round(rate, 3),
      "window_size" => window_size,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
