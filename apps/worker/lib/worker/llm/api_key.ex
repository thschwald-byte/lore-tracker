defmodule Worker.LLM.ApiKey do
  @moduledoc """
  Cloud-API-Key-Lookup pro Backend mit Settings-first / ENV-Fallback (Issue #510).

  Lookup-Order pro Backend:

  1. `Worker.Settings.get/1` für den Settings-Key (`:anthropic_api_key` /
     `:openai_api_key` / `:gemini_api_key`) — vom User im
     `/cloud-api`-LV gesetzt.
  2. `System.get_env/1` für die klassische Env-Var (`ANTHROPIC_API_KEY` /
     `OPENAI_API_KEY` / `GEMINI_API_KEY`) — Backward-Compat für CLI-User
     die ihren Worker-BEAM mit Env starten.

  Leerstring zählt als nicht-gesetzt (Schutz gegen `export FOO=` der
  versehentlich ein leeres FOO setzt). Returnt String oder `nil`.

  Status-Lookup (`status/1`) ist die snapshot-safe Variante — gibt nur
  zurück OB ein Key gesetzt ist, NICHT den Wert. Wird vom
  `Worker.Repo.snapshot/1` für `kind=settings` genutzt, damit das Hub-UI
  den "Key konfiguriert"-Status zeigen kann ohne dass der Key durch
  Phoenix-Channel-Frames + Hub-Reader-Cache leakt.
  """

  @backends %{
    anthropic: {:anthropic_api_key, "ANTHROPIC_API_KEY"},
    openai: {:openai_api_key, "OPENAI_API_KEY"},
    google: {:gemini_api_key, "GEMINI_API_KEY"}
  }

  @doc """
  Returnt den API-Key für den Backend (String) oder `nil` wenn weder
  Settings noch Env-Var einen non-empty Wert haben.
  """
  @spec get(:anthropic | :openai | :google) :: String.t() | nil
  def get(backend) when is_map_key(@backends, backend) do
    {setting_key, env_var} = Map.fetch!(@backends, backend)

    case Worker.Settings.get(setting_key) do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        case System.get_env(env_var) do
          key when is_binary(key) and key != "" -> key
          _ -> nil
        end
    end
  end

  @doc """
  Returnt `:set_via_settings` / `:set_via_env` / `:unset` — für die
  Snapshot-Anzeige im Hub-UI. Lässt den Wert NIE durch (Defense gegen
  Key-Leakage in Hub-PubSub).
  """
  @spec status(:anthropic | :openai | :google) ::
          :set_via_settings | :set_via_env | :unset
  def status(backend) when is_map_key(@backends, backend) do
    {setting_key, env_var} = Map.fetch!(@backends, backend)

    cond do
      binary_set?(Worker.Settings.get(setting_key)) -> :set_via_settings
      binary_set?(System.get_env(env_var)) -> :set_via_env
      true -> :unset
    end
  end

  defp binary_set?(v) when is_binary(v) and v != "", do: true
  defp binary_set?(_), do: false
end
