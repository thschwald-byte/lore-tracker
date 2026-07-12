defmodule HubWeb.Plugs.RateLimit do
  @moduledoc """
  Issue #629: Controller-Plug für Per-IP-Rate-Limit auf `/pair`,
  `/invite/:token`, `/auth/discord/callback`.

  ## Konfiguration

      config :hub, HubWeb.Plugs.RateLimit,
        # :direct = kein trusted Proxy davor, XFF wird IGNORIERT,
        #   conn.remote_ip wird genutzt (lokaler Dev/PR-Test-Stack).
        # {:trusted_proxies, N} = N trusted Proxies zwischen Client und App;
        #   die IP N Hops von rechts im X-Forwarded-For-Header gilt als Client-IP.
        proxy_config: :direct,
        limits: %{
          pair: {10, 60_000},
          invite: {30, 60_000},
          auth_callback: {60, 60_000}
        }

  Plug-Option ist nur `key :: atom()` — `limit`/`window_ms` kommen zur
  Request-Zeit aus `:limits`, damit Tests kleinere Limits + längere Fenster
  per Config-Overlay setzen können, ohne den Controller-Code anzufassen.

  ## Trust-Boundary (kritisch — bitte vor Änderung lesen)

  `X-Forwarded-For` wird von Proxy-Hops **appended, nicht ersetzt** (Standard
  bei nginx, ELB, GCP-LB, und — gemessen via #629 Stufe A — auch beim
  Gigalixir-LB: `XFF: <client>` mit genau einem Eintrag). Der **rightmost**
  Eintrag ist der vertrauenswürdige (vom letzten trusted Hop angehängte);
  der **leftmost** ist client-/angreifer-kontrolliert. Bei `{:trusted_proxies,
  N}` wird deshalb `Enum.at(entries, -N)` genommen, NIE der erste Eintrag —
  ein Angreifer könnte sonst mit einem gefälschten XFF-Header pro Request
  eine frische Bucket-Zelle erzeugen und das Rate-Limit vollständig umgehen.

  Ist der Header kürzer als die konfigurierten `N` Hops (LB-Konfig-Drift),
  fällt die Extraktion auf `conn.remote_ip` zurück UND schreibt einen
  gedrosselten Frühwarn-Log (`Hub.RateLimit.check/4` mit `limit: 1` als
  Dedup-Marker) — ein `N`, das größer ist als die echten Hops, würde sonst
  still eine falsche (Proxy-)IP als Bucket-Key nehmen und im schlimmsten Fall
  alle User in einen gemeinsamen Bucket zwingen (flächiger Self-DoS).

  **Bekannte Grenzen:**
  - Hinter einem LB, der einen clientgesetzten XFF-Header NICHT appended
    sondern unverändert durchreicht, kann ein Angreifer das Limit umgehen.
    Gilt für keinen der gängigen Cloud-LBs; bei einem LB-Wechsel neu bewerten.
  - Eine Uni-/Firmen-/Wohnheim-NAT teilt sich das Per-IP-Limit unter allen
    dahinter sitzenden Usern. Für die aktuelle Nutzergröße vertretbar — ein
    "Login geht nicht"-Report aus einem großen NAT ist kein Bug an sich.
  """

  import Plug.Conn

  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :key)

  @impl true
  def call(conn, key) do
    {limit, window_ms} = limits()[key] || raise "HubWeb.Plugs.RateLimit: kein Limit für #{key}"
    ip = client_ip(conn)

    case Hub.RateLimit.check(key, ip, limit, window_ms) do
      :ok ->
        conn

      {:error, :rate_limited, count} ->
        # Log-Drosselung: nur der erste Überschreiter im Fenster loggt, sonst
        # würde der Schutzmechanismus selbst zum I/O-Amplifier.
        if count == limit + 1 do
          Logger.warning("Hub.RateLimit: 429 name=#{key} ip=#{ip}")
        end

        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(:too_many_requests, "Too Many Requests")
        |> halt()
    end
  end

  defp limits, do: config()[:limits] || %{}
  defp proxy_config, do: config()[:proxy_config] || :direct
  defp config, do: Application.get_env(:hub, __MODULE__, [])

  defp client_ip(conn) do
    xff_entries =
      case get_req_header(conn, "x-forwarded-for") do
        [xff | _] -> xff |> String.split(",") |> Enum.map(&String.trim/1)
        [] -> []
      end

    case {proxy_config(), xff_entries} do
      {:direct, _} ->
        remote_ip_string(conn)

      {{:trusted_proxies, _n}, []} ->
        remote_ip_string(conn)

      {{:trusted_proxies, n}, entries} when length(entries) < n ->
        warn_xff_length_mismatch(entries, n)
        remote_ip_string(conn)

      {{:trusted_proxies, n}, entries} ->
        Enum.at(entries, -n)
    end
  end

  defp remote_ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp warn_xff_length_mismatch(entries, expected_n) do
    # Hub.RateLimit.check/4 als Einmal-pro-Fenster-Dedup-Marker zweckentfremdet
    # (limit: 1 → erster Call im Fenster ist :ok, alle weiteren :rate_limited).
    # Dedup GLOBAL (fixer "global"-Key), nicht pro-IP: das Mismatch ist ein
    # Infra-Drift-Signal (LB-Konfig geändert), kein Pro-Angreifer-Ereignis —
    # pro-IP würde bei vielen unterschiedlichen Clients trotzdem eine Zeile
    # pro Client spammen, obwohl die Ursache dieselbe LB-Fehlkonfiguration ist.
    case Hub.RateLimit.check(:xff_length_mismatch, "global", 1, 60_000) do
      :ok ->
        Logger.warning(
          "Hub.RateLimit: XFF-Länge #{length(entries)} < erwartete Hops #{expected_n} — " <>
            "fallback auf conn.remote_ip. LB-Konfig geändert?"
        )

      {:error, :rate_limited, _count} ->
        :ok
    end
  end
end
