defmodule Worker.SyncWatermark do
  @moduledoc """
  Issue #693: persistente Sync-Wasserlinie pro Pull-Scope.

  Ein Scope ist `"global"` (der `worker_events_global`-Strom) oder eine
  campaign_id (der per-Campaign-Strom). Die Wasserlinie eines Scopes ist die
  höchste event_id (UUIDv7, lexikographisch zeit-geordnet), bis zu der dieser
  Worker **nachweislich per Pull von einem Peer** synchronisiert hat.

  Kernregel gegen das Cursor-Poisoning (#693): **nur Pull-Batches schieben die
  Wasserlinie vor — Live-`event_appended`-Applies nie.** Der frühere Cursor
  (Tabellen-MAX via `last_global_event_id`) wurde von Live-Events an die Spitze
  geschoben, bevor der Backfill die Historie geholt hatte → `pull_since(MAX)`
  übersprang die gesamte Historie dauerhaft (real: Worker hing bei 23/15134
  Events). Die Wasserlinie startet bei `nil` (= volle Historie pullen) und
  wächst ausschließlich mit tatsächlich empfangenen Pull-Batches.

  Es gibt bewusst kein finales „done": der periodische Sync-Tick
  (`Worker.HubClient`, Setting `:sync_tick_ms`) pullt jeden Scope immer wieder
  ab Wasserlinie — verlorene Live-Events (PubSub ist best-effort) werden so
  automatisch regeneriert; Duplikate skippt die event_id-Idempotenz des
  Materializers.

  Storage: ein `worker_state`-Key `:sync_watermarks` mit einer Map
  `%{scope => event_id}`. Einziger Schreiber ist der HubClient-/Slipstream-
  Prozess (alle `on_pull_batch*` laufen dort) → kein Race auf dem
  Read-Modify-Write.
  """

  alias Worker.Repo

  @state_key :sync_watermarks
  @global_scope "global"

  @doc "Scope-Name des globalen Event-Stroms."
  @spec global_scope() :: String.t()
  def global_scope, do: @global_scope

  @doc """
  Wasserlinie eines Scopes — `nil` wenn der Scope noch nie gepullt hat
  (= Backfill ab Anfang der Historie).
  """
  @spec get(String.t()) :: String.t() | nil
  def get(scope) when is_binary(scope) do
    Map.get(all(), scope)
  end

  @doc """
  Wasserlinie monoton vorschieben: schreibt nur, wenn `event_id` über der
  aktuellen Wasserlinie liegt (UUIDv7 → String-Vergleich ist Zeit-Vergleich).
  Monotonie macht parallele/duplizierte Pull-Loops harmlos.
  """
  @spec advance(String.t(), String.t()) :: :ok
  def advance(scope, event_id) when is_binary(scope) and is_binary(event_id) do
    watermarks = all()

    case Map.get(watermarks, scope) do
      cur when is_nil(cur) or event_id > cur ->
        :ok = Repo.put_state(@state_key, Map.put(watermarks, scope, event_id))

      _already_ahead ->
        :ok
    end
  end

  @doc "Die komplette Wasserlinien-Map (fehlender Key = nie gepullt)."
  @spec all() :: %{String.t() => String.t()}
  def all do
    case Repo.get_state(@state_key) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Pull-Schritt-Entscheidung für einen empfangenen Batch (pur, testbar):

    * nicht-leerer Batch → `{:advance, letzte_event_id}` — Wasserlinie
      vorschieben und den nächsten Pull ab dort schicken (Loop läuft weiter).
      Batches kommen aufsteigend (`events_since` walkt `:mnesia.next` auf dem
      ordered_set), das letzte Element ist also das Maximum.
    * leerer Batch → `:caught_up` — Loop endet, der nächste Sync-Tick prüft
      wieder.
  """
  @spec sync_step([%{optional(String.t()) => term()}]) ::
          {:advance, String.t()} | :caught_up
  def sync_step([]), do: :caught_up

  def sync_step(events) when is_list(events) do
    case List.last(events) do
      %{"event_id" => event_id} when is_binary(event_id) -> {:advance, event_id}
      _ -> :caught_up
    end
  end
end
