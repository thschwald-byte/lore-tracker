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

  @typedoc """
  Ergebnis der Pre-Flight-Prüfung. Die Unterscheidung ist der Kern von Issue
  #1076: `:rejected` ist ein Dauerzustand (derselbe Token wird nie gültig),
  `{:network_error, _}` ein Momentzustand (derselbe Token kann in 10 Sekunden
  funktionieren). Beide auf ein `false` zu kollabieren hat den Discord-Pfad
  nach einem Boot ohne DNS dauerhaft stillgelegt.
  """
  @type check_result :: :ok | :no_token | :rejected | {:network_error, term()}

  @doc """
  Pre-Flight-Validierung gegen die echte Discord-REST-API.

  EMPIRISCH verifizierte Notwendigkeit (#985, echter PR-Test-Fund), nicht
  vorsorgliche Übervorsicht: ein konfigurierter, aber UNGÜLTIGER Token lässt
  `Nostrum.Shard.Supervisor` beim Start synchron mit `RuntimeError
  "Authentication rejected, invalid token"` crashen.

  **Was sich mit #1076 geändert hat:** die Prüfung ist nicht mehr der
  Boot-Torwächter, sondern die Entscheidungsgrundlage von
  `Worker.Discord.BotGate`, das sie bei Netzfehlern wiederholt. Der Crash-
  Schutz hängt seither zusätzlich daran, dass `Nostrum.Bot` unter einem
  `DynamicSupervisor` startet statt als statischer Top-Level-Child — ein
  fehlgeschlagener Start liefert dort `{:error, reason}` statt den Worker
  mitzureißen. Die Prüfung bleibt trotzdem: sie verhindert den
  Crash-Loop-Logspam und liefert den ehrlichen Status für die Anzeige.

  HTTP-Status-Abbildung, bewusst nach Dauerhaftigkeit getrennt:

  - 200 → `:ok`
  - 401/403 → `:rejected` (Token ist falsch — kein Retry, bis er sich ändert)
  - alles andere (429, 5xx) → `{:network_error, _}` (transient, Retry)
  - Transport-Fehler/Timeout/Exception → `{:network_error, _}`
  """
  @spec check() :: check_result()
  def check do
    case get() do
      nil -> :no_token
      token -> check_against_discord(token)
    end
  end

  @doc """
  Boolean-Fassade über `check/0` — `true` gdw. Discord den Token bestätigt hat.

  Bleibt bestehen, weil mehrere Aufrufer/Tests nur die Ja-Nein-Frage stellen.
  Wer zwischen „falscher Token" und „gerade kein Netz" unterscheiden muss,
  nimmt `check/0`.
  """
  @spec usable?() :: boolean()
  def usable?, do: check() == :ok

  defp check_against_discord(token) do
    classify(
      Req.get("https://discord.com/api/v10/users/@me",
        headers: [{"authorization", "Bot #{token}"}],
        receive_timeout: 5_000,
        retry: false
      )
    )
  rescue
    e -> {:network_error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:network_error, {kind, reason}}
  end

  @doc """
  Die Abbildung Req-Ergebnis → `t:check_result/0`, als eigene Funktion, damit
  sie ohne Netz testbar ist (die HTTP-Hülle drumherum ist es nicht).

  Nur 401/403 sind `:rejected`. 429 und 5xx sind ausdrücklich KEINE Ablehnung
  — sie als solche zu behandeln hieße, wegen einer Discord-Störung dauerhaft
  aufzugeben.
  """
  @spec classify({:ok, map()} | {:error, term()} | term()) :: check_result()
  def classify({:ok, %{status: 200}}), do: :ok
  def classify({:ok, %{status: status}}) when status in [401, 403], do: :rejected
  def classify({:ok, %{status: status}}), do: {:network_error, {:http_status, status}}
  def classify({:error, reason}), do: {:network_error, reason}
  def classify(other), do: {:network_error, {:unexpected, other}}
end
