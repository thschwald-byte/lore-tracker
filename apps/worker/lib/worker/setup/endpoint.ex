defmodule Worker.Setup.Endpoint do
  @moduledoc """
  Cowboy HTTP listener bound to `localhost:<setup_port>` (loopback only).
  Only mounted while the worker is unpaired; goes away once
  `worker_state[:hub_token]` is set.
  """

  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: Worker.Setup.Router,
      options: [ip: {127, 0, 0, 1}, port: port]
    )
  end
end
