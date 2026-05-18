defmodule Worker.Intents do
  @moduledoc """
  Wrapper around `Worker.HubClient.publish/1` so worker-side producers
  (Pipeline, Recording, future Discord bot) don't have to know about
  Slipstream specifics or build the wire envelope themselves.

  Each call returns `{:ok, seq}` after the hub has assigned a seq and
  broadcasted, or `{:error, reason}` if the channel isn't ready.
  """

  @spec publish(map()) :: {:ok, pos_integer()} | {:error, term()}
  def publish(payload) when is_map(payload) do
    Worker.HubClient.publish(payload)
  end
end
