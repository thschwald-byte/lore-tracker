defmodule Worker.Discord.CommandRegistrar do
  @moduledoc """
  Issue #1033: meldet den `/lore`-Command-Satz bei Discord an.

  ## Warum Bulk-Overwrite und nicht `create_guild_command/3`

  Registrierte Application-Commands leben auf **Discords** Servern, nicht im
  Repo. Sie überdauern jedes Code-Entfernen — nachweislich: Commit 6f55273
  (Mai 2026) registrierte `/lore record start|stop` und `/lore status`, Issue
  #33 warf den Bot einen Tag später komplett raus, ohne abzumelden. Der
  Eintrag hing drei Monate verwaist im Server-Picker.

  `bulk_overwrite_guild_commands/2` setzt den registrierten Satz **gleich** dem
  deklarierten und entfernt dabei alles Übrige. Die Leiche verschwindet damit
  beim ersten Start von selbst, und neue können strukturell nicht entstehen.
  Mit `create_*` sammeln sie sich unbemerkt an; genau das ist hier passiert.

  ## Warum guild-scoped

  Guild-Commands sind sofort aktiv, globale brauchen bis zu einer Stunde
  Propagation. Am Spielabend ist das der Unterschied zwischen „funktioniert"
  und „funktioniert heute nicht mehr".

  ## Warum in JEDER Guild, nicht nur in konfigurierten

  Naheliegend wäre, nur dort zu registrieren, wo eine Kampagne die Guild
  eingetragen hat. Das hätte eine stille Falle: wer Discord für eine Kampagne
  frisch einrichtet, hätte den Command bis zum nächsten Worker-Neustart nicht
  — ohne Hinweis, woran es liegt.

  Deshalb wird immer registriert; ob eine Kampagne dahinter hängt, entscheidet
  sich zur **Laufzeit** gegen den aktuellen Stand (`Commands.resolve_campaign/2`).
  Ist keine konfiguriert, sagt die Antwort genau das. Der Bot ist ohnehin nur
  in Servern, in die er eingeladen wurde.

  ## Best-effort

  Ein Registrierungs-Fehler darf den Bot nie mitreißen — ohne Slash-Commands
  bleibt der Web-Button der vollwertige Weg. Der häufigste erwartbare Fehler
  ist ein fehlender OAuth-Scope `applications.commands` (HTTP 403); der steht
  dann als eigene Klasse in `/admin/errors`, statt nur im Log zu verschwinden.
  """

  require Logger

  alias Worker.Discord.Commands

  @doc """
  Registriert den Command-Satz für eine Guild. Idempotent (Bulk-Overwrite
  setzt einen Zustand, es addiert nicht).

  Wird pro `:GUILD_AVAILABLE` aufgerufen — also beim Bot-Start einmal je Guild
  und erneut nach einem Gateway-Reconnect. Ein PUT pro Guild und Reconnect ist
  gegenüber Discords Rate-Limits vernachlässigbar, und Nostrums Ratelimiter
  serialisiert die Aufrufe ohnehin.
  """
  @spec register_for_guild(integer() | String.t()) :: :ok
  def register_for_guild(guild_id) do
    case do_overwrite(guild_id) do
      {:ok, registered} ->
        Logger.info(
          "CommandRegistrar: /#{Commands.command_name()} registriert guild=#{guild_id} " <>
            "(#{length(List.wrap(registered))} Command(s))"
        )

        :ok

      {:error, reason} ->
        report_failure(guild_id, reason)
    end
  end

  defp do_overwrite(guild_id) do
    Nostrum.Api.ApplicationCommand.bulk_overwrite_guild_commands(
      normalize_guild_id(guild_id),
      Commands.declaration()
    )
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  # Nostrum erwartet die Guild-ID als Integer (Snowflake). Der Registry-Key im
  # Voice-Pfad ist ebenfalls Integer; aus der Kampagnen-Config kommt sie als
  # String. Beides wird hier angenommen, damit ein Aufrufer sich nicht merken
  # muss, aus welcher Quelle seine ID stammt.
  defp normalize_guild_id(id) when is_integer(id), do: id

  defp normalize_guild_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {int, _} -> int
      :error -> id
    end
  end

  # Sichtbar machen statt nur loggen: ein fehlender `applications.commands`-Scope
  # ist von außen nicht erkennbar — der Command taucht im Server einfach nie
  # auf, und niemand weiß warum. Das ist exakt die Silent-Failure-Klasse, gegen
  # die #1008 die übrigen Discord-Fehlerklassen eingeführt hat.
  #
  # Gemeldet wird PRO betroffener Kampagne, nicht einmal global: ein
  # `PipelineErrorLogged` ohne `campaign_id` hätte in `/admin/errors` keine
  # Zuordnung und wäre selbst wieder unsichtbar. Hängt an dieser Guild (noch)
  # keine Kampagne, gibt es auch niemanden, dem der fehlende Command schadet —
  # dann bleibt es beim Log.
  defp report_failure(guild_id, reason) do
    Logger.error(
      "CommandRegistrar: Registrierung fehlgeschlagen guild=#{guild_id}: #{inspect(reason)}"
    )

    message =
      "Slash-Commands konnten für Discord-Server #{guild_id} nicht registriert werden " <>
        "(#{inspect(reason)}). `/lore start|stop|status` fehlt dort — die Aufnahme lässt " <>
        "sich weiterhin über den Web-Knopf steuern. Häufigste Ursache: dem Bot-Invite " <>
        "fehlt der OAuth-Scope `applications.commands`, dann hilft nur ein Re-Invite."

    guild_id
    |> to_string()
    |> Worker.Repo.campaigns_for_guild()
    |> Enum.each(fn campaign ->
      Worker.Recording.Pipeline.publish_pipeline_error(
        campaign.id,
        "discord_commands",
        nil,
        :command_registration_failed,
        message
      )
    end)

    :ok
  rescue
    # Die Fehler-Meldung darf nie selbst zum Fehler werden.
    e ->
      Logger.error("CommandRegistrar: Fehler-Meldung fehlgeschlagen: #{Exception.message(e)}")
      :ok
  end
end
