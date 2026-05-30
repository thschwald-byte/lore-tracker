defmodule HubWeb.KnownIssues do
  @moduledoc """
  Issue #68 (Phase 2): Mappt klassifizierte `error_type`-Strings aus
  `PipelineErrorLogged`-Events auf human-readable Hinweise. Wird vom
  /admin/errors-LV pro Eintrag aufgerufen und in der expandierten Reihe
  angezeigt.

  Whitelist — unbekannte Types fallen auf `nil` zurück, dann zeigt das
  UI keinen Hint-Block.

  Phase 3 (#68 Folge-PR) bringt: docs/Troubleshooting.md mit langem
  Format + Retry-Buttons. Diese Hints hier sind die Kurzform.
  """

  @type hint :: %{
          required(:icon) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t()
        }

  @doc """
  Liefert eine Hint-Map für den gegebenen `error_type`, oder `nil` wenn
  keiner gemappt ist. Context wird (bislang) nicht ausgewertet — Phase 3
  könnte z.B. den Cloud-Provider aus dem Context lesen, um konkretere
  Env-Var-Namen zu nennen.
  """
  @spec hint(String.t() | nil, map() | nil) :: hint() | nil
  def hint(error_type, context \\ %{})

  def hint("empty_chronik", _ctx) do
    %{
      icon: "⚠️",
      title: "Stage 4 lieferte keine Chronik-Einträge",
      body:
        "Das Modell hat auch nach Retry keine parsebaren Chronik-JSON-Einträge produziert. Bekannte Ursache (Issue #75): kleinere oder Thinking-Modelle (`qwen3:30b-a3b`, `qwen2.5:0.5b` bei langen Sessions) scheitern hier. Lösung: in /settings ein größeres Modell für Stage 4 wählen oder den `:http_timeout_ms` erhöhen."
    }
  end

  def hint("no_key_configured", ctx) do
    provider =
      case ctx do
        %{"provider" => p} when is_binary(p) -> String.upcase(p)
        _ -> "<PROVIDER>"
      end

    %{
      icon: "🔑",
      title: "Cloud-LLM: API-Key fehlt",
      body:
        "Der Worker hat keine `#{provider}_API_KEY` Env-Var. Setze sie im Worker-Start-Environment (`.env` neben dem Worker oder direkt vor `mix run`) und starte den Worker neu. Per Etappe 5b (#162) lebt der Key pro-Worker, nicht im Hub-Settings-UI."
    }
  end

  def hint("upstream_auth", _ctx) do
    %{
      icon: "🚫",
      title: "Cloud-LLM lehnte Auth ab (401/403)",
      body:
        "Der API-Key ist gesetzt, aber der Provider hat ihn verworfen. Prüfen: 1) Key ist nicht abgelaufen/widerrufen, 2) Key-Tier hat Zugriff auf das gewählte Modell, 3) Worker-Prozess sieht die richtige Env-Var (nicht versehentlich aus einer alten Shell-Session)."
    }
  end

  def hint("upstream_rate_limit", _ctx) do
    %{
      icon: "⏱️",
      title: "Cloud-LLM Rate-Limit erreicht (429)",
      body:
        "Der Provider drosselt. Worker macht bereits 2× exponentielles Backoff. Optionen: kurz warten + nochmal anstoßen, anderes Modell wählen, oder Per-User-Spend-Cap (#178) prüfen — bei großen Sweeps ist der Free-Tier schnell aufgebraucht."
    }
  end

  def hint("network_error", _ctx) do
    %{
      icon: "🌐",
      title: "Netzwerk-Fehler beim Cloud-LLM-Call",
      body:
        "Worker erreichte den Provider nicht (Timeout, DNS, Firewall). Lokal: Internet-Verbindung prüfen. Self-Hosted hinter Proxy: outbound HTTPS zu `api.anthropic.com` / `api.openai.com` / `generativelanguage.googleapis.com` freischalten."
    }
  end

  def hint("upstream_error", _ctx) do
    %{
      icon: "💥",
      title: "Cloud-LLM Provider 5xx",
      body:
        "Provider-seitiger Server-Fehler. Status auf der Provider-Status-Seite checken; meist transient. Worker macht bereits 2× exponentielles Backoff, ggf. später nochmal versuchen."
    }
  end

  def hint("timeout", _ctx) do
    %{
      icon: "🕐",
      title: "LLM-Call hat das HTTP-Timeout überschritten",
      body:
        "Das Modell hat zu lange für die Antwort gebraucht. Lösung: in /settings das HTTP-Timeout (`:http_timeout_ms`, Default 600s) erhöhen, ein kleineres/schnelleres Modell wählen, oder den Prompt-Kontext kürzen."
    }
  end

  def hint("no_summary", _ctx) do
    %{
      icon: "📝",
      title: "Stage 2 lieferte kein parsebares Resümee",
      body:
        "Das Resümee-Modell hat keinen verwertbaren JSON-Output produziert. Häufig bei sehr kleinen Modellen, die das Schema nicht halten. Größeres Stage-2-Modell in /settings versuchen."
    }
  end

  def hint("no_epos", _ctx) do
    %{
      icon: "📜",
      title: "Stage 3 lieferte kein Epos",
      body:
        "Stage 3 hat keinen Epos-Text geliefert. Meist Modell-Timeout (siehe `:http_timeout_ms` in /settings) oder Modell-Crash. Ein kleineres Modell oder erhöhtes Timeout versuchen."
    }
  end

  def hint("no_campaign", _ctx) do
    %{
      icon: "❓",
      title: "Kampagne nicht gefunden",
      body:
        "Die Session referenziert eine Kampagne, die im Worker-Snapshot nicht existiert. Bug, kein User-fixbarer Konfig-Fehler — bitte als Ticket öffnen (Codeberg `tomloresys/lore-tracker`) mit dem error_id."
    }
  end

  def hint("no_session", _ctx) do
    %{
      icon: "❓",
      title: "Session nicht gefunden",
      body:
        "Pipeline wurde für eine Session getriggert, die im Worker-Snapshot fehlt. Worker-Resync via Re-Pair oder `pull_since`/`pull_since_global` aus anderen Workern derselben Kampagne (siehe CLAUDE.md → Disaster-Recovery)."
    }
  end

  def hint(_unknown, _ctx), do: nil

  @doc """
  Liefert die kanonische Liste aller bekannten `error_type`-Strings.
  Die /admin/errors-LV nutzt das für das Filter-Dropdown.
  """
  @spec known_types() :: [String.t()]
  def known_types do
    [
      "empty_chronik",
      "no_key_configured",
      "upstream_auth",
      "upstream_rate_limit",
      "network_error",
      "upstream_error",
      "http_error",
      "timeout",
      "no_summary",
      "no_epos",
      "no_campaign",
      "no_session",
      "other"
    ]
  end
end
