defmodule Worker.Discord.BotToken do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic): Bot-Token-Lookup mit
  Settings-first / ENV-Fallback — Muster `Worker.LLM.ApiKey`, aber nur EIN
  Backend (kein Map-Dispatch nötig).

  Der Bot-Token ist eine Deployment-Eigenschaft des Workers (nicht pro
  Kampagne) — anders als Guild-ID/Voice-Channel-ID, die pro Kampagne
  variieren und als Campaign-Config leben (siehe
  `Worker.Repo.get_campaign_discord_config/1`).

  Lookup-Order:

  1. `Worker.Settings.get(:discord_bot_token)` — vom User in `/settings` gesetzt.
  2. `System.get_env("DISCORD_BOT_TOKEN")` — Backward-Compat für CLI-User.

  Leerstring zählt als nicht-gesetzt. `status/0` ist die snapshot-safe
  Variante (nie den Wert selbst zurückgeben — Defense gegen Token-Leakage via
  Hub-Reader-Cache + Phoenix-Channel-Frames).
  """

  @setting_key :discord_bot_token
  @env_var "DISCORD_BOT_TOKEN"

  @doc "Token-String oder `nil` wenn weder Settings noch Env-Var gesetzt sind."
  @spec get() :: String.t() | nil
  def get do
    case Worker.Settings.get(@setting_key) do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        case System.get_env(@env_var) do
          token when is_binary(token) and token != "" -> token
          _ -> nil
        end
    end
  end

  @doc "`:set_via_settings` / `:set_via_env` / `:unset` — für die Snapshot-Anzeige."
  @spec status() :: :set_via_settings | :set_via_env | :unset
  def status do
    cond do
      binary_set?(Worker.Settings.get(@setting_key)) -> :set_via_settings
      binary_set?(System.get_env(@env_var)) -> :set_via_env
      true -> :unset
    end
  end

  defp binary_set?(v) when is_binary(v) and v != "", do: true
  defp binary_set?(_), do: false

  @doc """
  Pre-Flight-Validierung gegen die echte Discord-REST-API — EMPIRISCH am
  echten PR-Test verifizierte Notwendigkeit, nicht vorsorgliche Übervorsicht:
  ein konfigurierter, aber UNGÜLTIGER Token lässt `Nostrum.Shard.Supervisor`
  beim Boot synchron mit `RuntimeError "Authentication rejected, invalid
  token"` crashen — und weil `Nostrum.Bot` ein STATISCHER Top-Level-Child von
  `Worker.Application` ist (kein `DynamicSupervisor`-Kind wie `VoiceSession`),
  reißt das den GESAMTEN Worker-Boot mit, nicht nur die Discord-Funktion.

  `Worker.Application.discord_bot_child/0` startet `Nostrum.Bot` nur, wenn
  DIESE Funktion `true` liefert — nicht `status/0` (das prüft nur „ist
  irgendein String gesetzt", nicht „ist er gültig"). Netzwerkfehler/Timeout
  zählen als NICHT nutzbar (fail-closed: lieber der Bot startet gar nicht,
  als dass ein Boot-Zeitpunkt-Netzwerk-Blip den ganzen Worker crasht).
  """
  @spec usable?() :: boolean()
  def usable? do
    case get() do
      nil -> false
      token -> valid_against_discord?(token)
    end
  end

  defp valid_against_discord?(token) do
    case Req.get("https://discord.com/api/v10/users/@me",
           headers: [{"authorization", "Bot #{token}"}],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
