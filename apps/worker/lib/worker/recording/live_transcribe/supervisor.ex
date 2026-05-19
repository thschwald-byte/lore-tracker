defmodule Worker.Recording.LiveTranscribe.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-(session_id, discord_id) `LiveTranscribe`
  GenServers. One child per speaker per session. Restart strategy is
  `:transient` — if a transcriber crashes, the session keeps going
  (audio is still being written to the `.webm` file by AudioBuffer, so
  live partials may be lost but the final batch pass will pick everything
  up at session-end).
  """

  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_child(args) do
    spec = %{
      id: Worker.Recording.LiveTranscribe,
      start: {Worker.Recording.LiveTranscribe, :start_link, [args]},
      restart: :transient
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
