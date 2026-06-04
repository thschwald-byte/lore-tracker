defmodule HubWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hub

  # Issue #358: http_only ist Plug.Session-Default (true); same_site Lax schützt
  # gegen CSRF. `secure` (Cookie nur über HTTPS) wird in :prod erzwungen — der
  # Gigalixir-Proxy terminiert TLS und reicht http an die App weiter, ohne das
  # Flag könnte das Session-Cookie über eine Klartext-Verbindung lecken. In
  # :dev/:test bleibt es false (lokaler http-Betrieb + PR-Test-Stacks).
  @session_options [
    store: :cookie,
    key: "_hub_key",
    signing_salt: "loretracker",
    same_site: "Lax",
    secure: Mix.env() == :prod
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  socket("/worker_socket", HubWeb.WorkerSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/",
    from: :hub,
    gzip: false,
    only: HubWeb.static_paths()
  )

  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(HubWeb.Router)
end
