defmodule Hub.Storage.EventLog do
  @moduledoc """
  Behaviour for the append-only event log. Two adapters ship today:

  - `Hub.Storage.EventLog.Mnesia` — default in dev; file-backed Mnesia, no
    external DB needed. Used as long as the dev/test host has a writable
    filesystem (i.e. always in this project's dev shell).
  - `Hub.Storage.EventLog.Postgres` — production-only adapter for Gigalixir
    (or any other PaaS where Mnesia files don't survive deploys).

  The adapter is picked at runtime via `Application.get_env(:hub, :storage_backend)`
  (`:mnesia` | `:postgres`). The public façade `Hub.EventLog` dispatches here.
  """

  @type event :: %{
          seq: pos_integer(),
          event_id: String.t() | nil,
          payload: term(),
          author_worker_id: String.t() | nil,
          ts: DateTime.t()
        }

  @callback bootstrap!() :: :ok
  @callback append(
              event_id :: String.t() | nil,
              payload :: term(),
              author_worker_id :: String.t() | nil,
              ts :: DateTime.t()
            ) :: {:ok, pos_integer()}
  @callback head() :: non_neg_integer()
  @callback stream(after_seq :: non_neg_integer()) :: [event()]
end
