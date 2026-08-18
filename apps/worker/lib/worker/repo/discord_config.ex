defmodule Worker.Repo.DiscordConfig do
  @moduledoc """
  Der Lesepfad der Discord-Kampagnen-Config: welche Guild und welcher
  Sprachkanal gehören zu einer Kampagne — und, seit Issue #1033, die
  Gegenrichtung.

  Herausgelöst aus `Worker.Repo.Artifacts` (Issue #1033), das mit der
  Rückwärts-Suche die 1000-Zeilen-Grenze des God-Module-Checks (#544) riss. Der
  Schnitt ist inhaltlich und nicht bloß eine Zeilen-Umverteilung: „Discord-Config
  lesen" ist eine eigene Verantwortlichkeit, während `Artifacts` die
  **generierten** Pipeline-Artefakte (Resümees, Fakten, Epos, Chronik) hält —
  die Config ist keins davon. Die beiden Richtungen teilen sich zudem die
  Normalisierungs-Regel unten, und die gehört genau einmal an genau einen Ort.

  Call-Sites bleiben `Worker.Repo.x()` (Façade-defdelegate).
  """

  alias Worker.Schema.Mnesia, as: S

  import Worker.Repo, except: [get_campaign_discord_config: 1]

  # Issue #985 Slice 1: Discord-Guild/Voice-Channel-Config (eigene Tabelle
  # @campaign_discord_configs). Normalisiert `""` UND fehlende Row auf `nil`
  # für beide Felder — sonst hat "nicht konfiguriert" zwei Repräsentationen
  # (fehlende Row vs. Row mit leeren Strings nach einem Reset), und jeder
  # künftige Konsument (der Bot-Slice, der auf "ist konfiguriert?" verzweigt)
  # müsste beide Formen kennen. String-Keys (nicht Atom) — konsistent mit dem
  # Snapshot-Transport zum Hub (JSON-Roundtrip).
  #
  # Semantik "Konfiguration entfernen": GM leert beide Felder und speichert →
  # Row wird mit ""/"" geschrieben (kein Delete-Event nötig, LWW-Write
  # reicht), dieser Reader liefert dann wieder nil/nil — das IST der
  # Reset-Pfad.
  @doc "Discord-Guild/Voice-Channel-Config der Campaign; `nil`-Felder wenn nicht gesetzt."
  @spec get_campaign_discord_config(String.t()) :: %{
          String.t() => String.t() | nil
        }
  def get_campaign_discord_config(campaign_id) when is_binary(campaign_id) do
    row =
      transaction(fn -> :mnesia.read(S.campaign_discord_configs(), campaign_id) end)

    case row do
      [{_tbl, _cid, guild_id, voice_channel_id, _updated_at}] ->
        %{
          "guild_id" => blank_to_nil(guild_id),
          "voice_channel_id" => blank_to_nil(voice_channel_id)
        }

      [] ->
        %{"guild_id" => nil, "voice_channel_id" => nil}
    end
  end

  # Issue #1033: die RÜCKWÄRTS-Richtung der Discord-Config — welche Kampagnen
  # hängen an dieser Guild? Der Web-Button kennt seine Kampagne aus der URL; ein
  # Slash-Command kennt nur die Guild, aus der er kam, und muss sie erst
  # auflösen.
  #
  # Guild -> Kampagne ist ausdrücklich 1:N (zwei Kampagnen können dieselbe Guild
  # konfiguriert haben, s. die Konflikt-Semantik in #987) — deshalb eine Liste
  # und keine Einzel-Row. Wer daraus eine Kampagne machen will, muss den
  # Mehrdeutigkeits-Fall selbst behandeln.
  #
  # Config-Rows werden nie gelöscht (Reset = ""/"" schreiben, s.o.), und eine
  # gelöschte Kampagne lässt ihre Row stehen. Beides wird hier gefiltert:
  # leere Guild-IDs matchen ohnehin nicht, verwaiste `campaign_id`s fallen über
  # `get_campaign/1 == nil` raus.
  @doc "Alle Kampagnen, die diese Discord-Guild konfiguriert haben (kann leer sein)."
  @spec campaigns_for_guild(String.t()) :: [map()]
  def campaigns_for_guild(guild_id) when is_binary(guild_id) do
    guild_id = String.trim(guild_id)

    if guild_id == "" do
      []
    else
      tbl = S.campaign_discord_configs()
      pattern = {tbl, :_, guild_id, :_, :_}

      rows = transaction(fn -> :mnesia.match_object(pattern) end)

      rows
      |> Enum.map(fn {_tbl, cid, _gid, voice_channel_id, _updated_at} ->
        {cid, blank_to_nil(voice_channel_id)}
      end)
      |> Enum.flat_map(fn {cid, voice_channel_id} ->
        case Worker.Repo.get_campaign(cid) do
          nil ->
            []

          campaign ->
            # Issue #1081: dieselben Feldnamen wie `campaigns_with_guild_for/1`.
            # Beide Listen landen in derselben Auswahl, und `configured_here?/2`
            # liest `:discord_guild_id` — fehlte es hier, könnte der Vorrang der
            # hier eingerichteten Kampagne nicht greifen.
            [
              campaign
              |> Map.put(:voice_channel_id, voice_channel_id)
              |> Map.put(:discord_guild_id, guild_id)
              |> Map.put(:discord_voice_channel_id, voice_channel_id)
            ]
        end
      end)
      |> Enum.sort_by(& &1.name)
    end
  end

  def campaigns_for_guild(_), do: []

  # Issue #1081: die Kampagnen eines Users, jeweils angereichert um die Guild,
  # an der sie hängen (`nil` = noch nicht eingerichtet). Genau diese beiden
  # Angaben braucht die Vorschlagsliste von `/lore start`: welche Kampagnen
  # kommen für den Aufrufer infrage, und welche davon gehören schon zu diesem
  # Server.
  #
  # Über die MITGLIEDSCHAFT, nicht über die Rolle (#1082) — wer die Aufnahme
  # bedienen darf, soll seine Runde auch in der Liste finden.
  @doc "Kampagnen des Users samt gebundener Guild (`:discord_guild_id`, ggf. nil)."
  @spec campaigns_with_guild_for(String.t()) :: [map()]
  def campaigns_with_guild_for(discord_id) when is_binary(discord_id) do
    discord_id
    |> Worker.Repo.list_campaigns_for()
    |> Enum.map(fn c ->
      cfg = get_campaign_discord_config(c.id)

      c
      |> Map.put(:discord_guild_id, cfg["guild_id"])
      |> Map.put(:discord_voice_channel_id, cfg["voice_channel_id"])
    end)
  end

  def campaigns_with_guild_for(_), do: []

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
