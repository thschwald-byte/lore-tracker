defmodule Worker.Materializer.DiscordConfigFolds do
  @moduledoc """
  Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic, Vorbereitung): der
  CampaignDiscordConfigSet-Fold — Schwester-Modul von
  `Worker.Materializer.Apply2` (dessen God-Module-Budget), dort nur eine
  Dünn-Dispatch-Klausel (Muster `FlagFolds`/`ArcFolds`).

  1 Row/Kampagne (`worker_campaign_discord_configs`), LWW via fold_meta-
  Sidecar, Voll-Snapshot-Payload — HAT NOCH KEINE FUNKTIONALE WIRKUNG, der
  Bot existiert noch nicht.

  Invariante: der Write ersetzt die GANZE Row aus EINEM Payload — konvergent
  nur, weil der einzige Producer (das Kampagnen-Formular) immer beide Felder
  zusammen sendet. Ein künftiger zweiter Producer darf NIEMALS nur ein Feld
  schreiben, sonst klobbert er das andere auf "".
  """

  require Logger

  alias Worker.Schema.Mnesia, as: S

  import Worker.Materializer

  @doc false
  def campaign_discord_config_set(payload, ts, meta) do
    id = payload["campaign_id"]
    event_id = Map.get(meta, :event_id)

    cond do
      not is_binary(id) ->
        Logger.warning("CampaignDiscordConfigSet: bad campaign_id (#{inspect(id)}) — dropping")

      not fold_supersedes?(
        S.campaign_discord_configs(),
        id,
        :campaign_discord_config_set,
        event_id
      ) ->
        :ok

      true ->
        guild_id = normalize_discord_snowflake(payload["guild_id"])
        voice_channel_id = normalize_discord_snowflake(payload["voice_channel_id"])

        :ok =
          :mnesia.write({S.campaign_discord_configs(), id, guild_id, voice_channel_id, ts})

        record_fold_winner!(
          S.campaign_discord_configs(),
          id,
          :campaign_discord_config_set,
          event_id
        )
    end
  end

  # Defensiv statt hart validiert (Calendar.from_json-Vorbild): nie crashen,
  # kein Format-Zwang (v1 hat keine funktionale Wirkung). Nur trim +
  # non-binary → "".
  defp normalize_discord_snowflake(v) when is_binary(v), do: String.trim(v)
  defp normalize_discord_snowflake(_), do: ""
end
