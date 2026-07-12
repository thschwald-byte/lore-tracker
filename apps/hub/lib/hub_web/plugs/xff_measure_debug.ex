defmodule HubWeb.Plugs.XffMeasureDebug do
  @moduledoc """
  Issue #629 Stufe A (Measure-First): temporärer Debug-Plug, der bei jedem
  Request den rohen `X-Forwarded-For`-Header + `conn.remote_ip` einmalig
  ins Log kippt. Zweck: die Hop-Zahl `N` zwischen Client und Hub am prod-
  Gigalixir-LB zu messen, damit der Feature-PR (Stufe B) `proxy_config:
  {:trusted_proxies, N}` mit einer echten Zahl setzen kann statt zu raten.

  **Kurzlebig** — der Revert-Commit dieses Files ist Teil des Feature-PRs.
  Das Log enthält bewusst rohe Client-IPs; nur unter :require_user
  angehängt, damit anonymer Traffic nicht ins Log kippt.

  Drossel: einmalig pro `conn.remote_ip` pro Runtime (Prozess-Dictionary im
  Endpoint-Prozess ist nicht geteilt, aber `:persistent_term` wäre Overkill;
  ETS auch. Wir loggen einmal pro Request — Tom klickt 3-5 Mal, das reicht
  für die Messung und das Log-Volumen ist trivial).
  """
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")
    remote = conn.remote_ip |> :inet.ntoa() |> to_string()

    Logger.info(
      "Hub.XffMeasureDebug: x-forwarded-for=#{inspect(xff)} remote_ip=#{remote} " <>
        "path=#{conn.request_path}"
    )

    conn
  end
end
