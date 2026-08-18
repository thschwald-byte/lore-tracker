defmodule Worker.Discord.Commands do
  @moduledoc """
  Issue #1033: die *Entscheidungen* hinter `/lore start|stop|status` — pure,
  ohne Nostrum und ohne Mnesia. Die I/O-Hülle ist
  `Worker.Discord.CommandInteraction`, die Registrierung bei Discord
  `Worker.Discord.CommandRegistrar`.

  ## Warum `/lore` und nicht `/lorespy`

  Der Name war offen (Ticket-Titel sagte `/lorespy`, der Usecase-Text
  `/loretracker`). Entschieden hat es ein Fund: `/lore` ist bei Discord **seit
  Mai 2026 registriert** — aus Commit 6f55273 (M10b), dessen Code einen Tag
  später mit Issue #33 entfernt wurde, ohne die Commands bei Discord
  abzumelden. Registrierte Application-Commands leben auf Discords Servern,
  nicht im Repo; sie überdauern jedes Code-Entfernen. Der Eintrag hing drei
  Monate verwaist im Server-Picker und quittierte einen Klick mit „Die
  Anwendung reagiert nicht".

  `/lore` ist damit die Form, die im Muscle Memory steht — und der Namensraum
  gehört ohnehin uns.

  ## Flach statt `/lore record start`

  Die Mai-Registrierung hatte eine Zwischenebene (`/lore record start`). Die
  ist hier bewusst weg: `record` trägt keine Information, solange es nichts
  anderes zu starten gibt, und am Spielabend zählt jeder Tastendruck. Der
  Bulk-Overwrite (s. `CommandRegistrar`) räumt die alte Form mit ab.

  ## Die Kampagnen-Option

  Guild → Kampagne ist 1:N (#987). Der Regelfall ist eine Kampagne pro Server;
  dann wird die Option ignoriert. Erst bei mehreren wird sie nötig, und dann
  nennt die Fehlermeldung die zur Wahl stehenden Namen.

  Bewusst ein **freier String ohne Choices**: Choices müssten zur
  Registrierungszeit feststehen und wären ab der nächsten Kampagnen-Anlage
  stale, ohne dass jemand es merkt. Ein Freitext-Feld wird stattdessen zur
  Laufzeit gegen den aktuellen Stand aufgelöst.
  """

  # Discord-Option-Typen (application-command-object-application-command-option-type)
  @type_sub_command 1
  @type_string 3

  @command_name "lore"

  @doc "Der Command-Name, unter dem die Subcommands hängen."
  @spec command_name() :: String.t()
  def command_name, do: @command_name

  @doc """
  Der vollständige Command-Satz für `bulk_overwrite_guild_commands/2`.

  Was hier NICHT drinsteht, wird bei Discord abgemeldet — das ist der
  Aufräum-Mechanismus für die Mai-Leiche und die Garantie, dass sich nie
  wieder Altlasten ansammeln.
  """
  @spec declaration() :: [map()]
  def declaration do
    [
      %{
        name: @command_name,
        description: "LoreTracker: Aufnahme steuern",
        options: [
          sub("start", "Aufnahme starten und den Bot in den Sprachkanal holen"),
          sub("stop", "Aufnahme beenden"),
          sub("status", "Läuft gerade eine Aufnahme?")
        ]
      }
    ]
  end

  defp sub(name, description) do
    %{
      type: @type_sub_command,
      name: name,
      description: description,
      options: [
        %{
          type: @type_string,
          name: "kampagne",
          description: "Nur nötig, wenn dieser Server mehrere Kampagnen hat",
          required: false
        }
      ]
    }
  end

  @doc """
  Interaction-Daten → `{:ok, subcommand, campaign_query}`.

  `campaign_query` ist `nil`, wenn die Option nicht gesetzt wurde.

  Defensiv gegen Structs UND rohe Maps: je nach Cache-Zustand kommt das Event
  unterschiedlich gecastet an (dieselbe Vorsicht wie `Consumer.display_name/1`).
  Alles, was kein `/lore`-Subcommand ist, ergibt `:error` — andere Features
  dürfen dieselbe Event-Quelle nutzen.
  """
  @spec parse(map()) :: {:ok, :start | :stop | :status, String.t() | nil} | :error
  def parse(%{name: @command_name} = data) do
    case first_option(data) do
      %{name: name} = opt when name in ["start", "stop", "status"] ->
        {:ok, String.to_existing_atom(name), campaign_query(opt)}

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  defp first_option(data) do
    case Map.get(data, :options) do
      [opt | _] when is_map(opt) -> opt
      _ -> nil
    end
  end

  defp campaign_query(opt) do
    opt
    |> Map.get(:options)
    |> List.wrap()
    |> Enum.find_value(fn
      %{name: "kampagne", value: v} when is_binary(v) -> non_empty(String.trim(v))
      _ -> nil
    end)
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  @doc """
  Wählt aus den Kampagnen dieser Guild die gemeinte aus.

  - genau eine → die, egal was in der Option steht (der Regelfall; eine
    Fehleingabe soll den Spielabend nicht aufhalten)
  - mehrere ohne Option → `{:error, {:ambiguous, namen}}`
  - mehrere mit Option → Name (case-insensitiv, Teilstring) oder ID-Präfix

  Erwartet Maps mit `:id` und `:name`.
  """
  @spec resolve_campaign([map()], String.t() | nil) ::
          {:ok, map()}
          | {:error, :none}
          | {:error, {:ambiguous, [String.t()]}}
          | {:error, {:no_match, String.t(), [String.t()]}}
  def resolve_campaign([], _query), do: {:error, :none}
  def resolve_campaign([only], _query), do: {:ok, only}

  def resolve_campaign(campaigns, nil), do: {:error, {:ambiguous, names(campaigns)}}

  def resolve_campaign(campaigns, query) when is_binary(query) do
    needle = String.downcase(String.trim(query))

    case Enum.filter(campaigns, &matches?(&1, needle)) do
      [one] -> {:ok, one}
      [] -> {:error, {:no_match, query, names(campaigns)}}
      # Mehrere Treffer sind wieder mehrdeutig — lieber nachfragen als raten.
      many -> {:error, {:ambiguous, names(many)}}
    end
  end

  defp matches?(campaign, needle) do
    name = campaign |> Map.get(:name, "") |> to_string() |> String.downcase()
    id = campaign |> Map.get(:id, "") |> to_string() |> String.downcase()

    String.contains?(name, needle) or String.starts_with?(id, needle)
  end

  defp names(campaigns), do: Enum.map(campaigns, &to_string(Map.get(&1, :name, "?")))

  # ─── Antwort-Texte ───────────────────────────────────────────────

  @doc "Text zu einem Auflösungs-Fehler."
  @spec resolve_error_text(
          :none
          | {:ambiguous, [String.t()]}
          | {:no_match, String.t(), [String.t()]}
        ) :: String.t()
  def resolve_error_text(:none) do
    "Für diesen Server ist keine Kampagne konfiguriert. " <>
      "Trag Guild und Sprachkanal in den Kampagnen-Einstellungen im Hub ein."
  end

  def resolve_error_text({:ambiguous, names}) do
    "Mehrere Kampagnen hängen an diesem Server: #{list(names)}. " <>
      "Gib an, welche gemeint ist: `/lore start kampagne:<Name>`"
  end

  def resolve_error_text({:no_match, query, names}) do
    "Keine Kampagne passt zu „#{query}\". Zur Wahl stehen: #{list(names)}."
  end

  @doc """
  Text zur Ablehnung eines nicht berechtigten Aufrufs.

  Issue #1082: die Schranke verläuft an der MITGLIEDSCHAFT, nicht mehr an der
  Spielleiter-Rolle. Der Text nennt deshalb den Weg hinein (eine Einladung),
  statt auf eine Rolle zu verweisen, die niemand von sich aus bekommt.
  """
  @spec not_authorized_text(String.t()) :: String.t()
  def not_authorized_text(campaign_name) do
    "Du bist kein Mitglied von „#{campaign_name}\". Lass dich von jemandem aus " <>
      "der Runde einladen, dann kannst du die Aufnahme mitsteuern."
  end

  defp list([]), do: "—"
  defp list([one]), do: "„#{one}\""

  defp list(names) do
    names |> Enum.map(&"„#{&1}\"") |> Enum.join(", ")
  end

  @doc """
  Laufzeit als `H:MM` bzw. `MM:SS` — für die Status-Antwort.

  Negative Werte (Uhr-Sprung) werden auf 0 geklemmt, statt eine sinnlose Zahl
  anzuzeigen.
  """
  @spec format_duration(integer()) :: String.t()
  def format_duration(seconds) when is_integer(seconds) do
    s = max(seconds, 0)
    h = div(s, 3600)
    m = s |> rem(3600) |> div(60)
    sec = rem(s, 60)

    if h > 0 do
      "#{h}:#{pad(m)}:#{pad(sec)}"
    else
      "#{pad(m)}:#{pad(sec)}"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
