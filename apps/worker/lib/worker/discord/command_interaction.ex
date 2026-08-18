defmodule Worker.Discord.CommandInteraction do
  @moduledoc """
  Issue #1033: die I/O-Hülle um einen `/lore`-Slash-Command. Die
  *Entscheidungen* liegen in `Worker.Discord.Commands` (pure) — hier steht nur,
  in welcher Reihenfolge was passiert, und warum.

  ## Warum aufgeschoben geantwortet wird

  `Worker.Discord.ConsentInteraction` antwortet sofort (Typ 4), weil ein
  Consent-Klick nichts Langsames auslöst. Hier ist es umgekehrt: `stop` hat ein
  Timeout-Budget von 60 Sekunden (der Schluss-Flush schreibt Audio, #1011),
  `start` holt den Bot in den Sprachkanal, und selbst `status` fragt den
  Recorder, der während eines laufenden Stops blockiert ist.

  Discord verwirft eine Interaction nach **3 Sekunden**. Deshalb zuerst die
  aufgeschobene Antwort (Typ 5, „denkt nach…"), die den Puffer auf 15 Minuten
  hebt, und danach die eigentliche Arbeit mit `edit_response/2`. Sofort zu
  antworten und die Arbeit hinterherzuschieben wäre hier falsch: dann stünde im
  Chat „Aufnahme beendet", bevor feststeht, ob sie beendet werden konnte.

  Alle Antworten sind **ephemer** — nur der Aufrufende sieht sie. Der Chat einer
  Spielrunde ist kein Ort für Werkzeug-Quittungen.

  ## Warum die Berechtigung hier geprüft wird

  Der Web-Weg ist doppelt geschützt: `HubWeb.Permissions` gatet den Knopf, und
  `Recorder.start_for_owner/3` prüft noch einmal selbst. Ein Slash-Command
  kommt am Hub **vorbei** — und `Recorder.stop_for_campaign/1` hat gar keine
  eigene Schranke, weil sie im Web-Pfad nie nötig war. Ohne die Prüfung hier
  könnte jeder Server-Teilnehmer eine fremde Aufnahme beenden.

  Geprüft wird dieselbe Schranke wie beim Start: per-Campaign-Rolle
  `:spielleiter` (`Worker.Repo.campaign_role/2`). Bewusst **ohne**
  Admin-Sonderweg — der Recorder kennt auch keinen, und zwei Schranken mit
  unterschiedlichem Umfang wären eine Einladung zur Drift.

  `status` ist davon ausgenommen: wer im Sprachkanal sitzt, darf wissen, ob
  aufgezeichnet wird. Das ist keine Bequemlichkeit, sondern die
  Transparenz-Seite der Einwilligung.
  """

  require Logger

  alias Worker.Discord.{AutoConfig, Commands, NostrumSafe, VoiceSession}
  alias Worker.Recording.Recorder

  # Discord-Antwort-Typen (interaction-response-object-interaction-callback-type)
  @deferred_message 5
  @autocomplete_result 8
  @ephemeral 64

  @doc """
  Verarbeitet eine Interaction. Alles, was kein `/lore`-Subcommand ist, ist ein
  stiller No-op (Consent-Klicks kommen über dieselbe Event-Quelle).
  """
  @spec handle(map()) :: :ok
  def handle(interaction) do
    case Commands.parse(Map.get(interaction, :data) || %{}) do
      :error -> :ok
      {:ok, sub, query} -> route(interaction, sub, query)
    end
  end

  @doc """
  Issue #1081: Vorschläge für die `kampagne`-Option.

  Discord räumt dafür **3 Sekunden** ein und erlaubt kein Aufschieben — anders
  als bei einem Befehl gibt es hier kein „denkt nach…". Deshalb ausschließlich
  Mnesia-Lesen, kein Recorder-Aufruf, kein Netz.

  Angeboten werden die Kampagnen, in denen der Aufrufer **Mitglied** ist (#1082)
  — auch die, die noch an keinen Server gebunden sind: die lassen sich beim
  Start in einem Aufwasch einrichten, und ohne sie in der Liste wäre genau der
  Weg unsichtbar, der die Einrichtung überflüssig macht.
  """
  @spec handle_autocomplete(map()) :: :ok
  def handle_autocomplete(interaction) do
    with {:ok, _sub, typed} <- Commands.parse(Map.get(interaction, :data) || %{}),
         discord_id when is_binary(discord_id) <- user_id(interaction) do
      choices =
        discord_id
        |> Worker.Repo.campaigns_with_guild_for()
        |> Commands.autocomplete_choices(Map.get(interaction, :guild_id), typed)

      respond_choices(interaction, choices)
    else
      _ -> respond_choices(interaction, [])
    end
  rescue
    e ->
      Logger.warning("CommandInteraction: Autocomplete fehlgeschlagen: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning(
        "CommandInteraction: Autocomplete fehlgeschlagen: #{inspect({kind, reason})}"
      )

      :ok
  end

  # ─── intern ──────────────────────────────────────────────────────

  defp route(interaction, sub, query) do
    guild_id = Map.get(interaction, :guild_id)
    discord_id = user_id(interaction)

    cond do
      is_nil(guild_id) ->
        # Direktnachricht: es gibt keine Guild, aus der eine Kampagne
        # abzuleiten wäre.
        defer_and_reply(interaction, fn ->
          "Das geht nur in einem Server-Kanal, nicht per Direktnachricht."
        end)

      is_nil(discord_id) ->
        Logger.warning("CommandInteraction: /lore #{sub} ohne user_id — verworfen")

        defer_and_reply(interaction, fn ->
          "Ich konnte nicht erkennen, wer den Befehl abgesetzt hat."
        end)

      true ->
        defer_and_reply(interaction, fn ->
          execute(guild_id, discord_id, sub, query)
        end)
    end
  end

  # Zuerst aufschieben, dann arbeiten, dann die Antwort nachreichen. Der
  # Rückgabewert von `work` ist der Text; ein Fehler darin darf den Aufrufenden
  # nie ohne Antwort stehen lassen.
  defp defer_and_reply(interaction, work) do
    defer(interaction)

    text =
      try do
        work.()
      rescue
        e ->
          Logger.error("CommandInteraction: #{Exception.message(e)}")
          "Da ist etwas schiefgegangen. Details stehen im Worker-Log."
      catch
        kind, reason ->
          Logger.error("CommandInteraction: #{inspect({kind, reason})}")
          "Da ist etwas schiefgegangen. Details stehen im Worker-Log."
      end

    reply(interaction, text)
  end

  @doc """
  Der Kern: Guild + Aufrufer + Subcommand → der Antworttext.

  `def` statt `defp` (mit `@doc false`), weil hier die Autorisierungs-Schranke
  sitzt und die ohne Discord-Verbindung prüfbar sein muss — `handle/1` gibt nur
  `:ok` zurück, der Text ginge im Test verloren (Muster:
  `Recorder.maybe_start_discord_bot/2`).
  """
  @spec execute(integer() | String.t(), String.t(), :start | :stop | :status, String.t() | nil) ::
          String.t()
  def execute(guild_id, discord_id, sub, query) do
    case Commands.resolve_campaign(candidates(guild_id, discord_id), query, guild_id) do
      {:error, reason} ->
        Commands.resolve_error_text(reason)

      {:ok, campaign} ->
        run(campaign, guild_id, discord_id, sub)
    end
  end

  # Issue #1081: ZWEI Quellen, bewusst.
  #
  #   * die Kampagnen DIESER Guild — auch fremde. Ohne sie bekäme jemand, der
  #     hier zwar mitliest, aber nicht Mitglied ist, ein irreführendes „für
  #     diesen Server ist keine Kampagne konfiguriert" statt der wahren Auskunft
  #     „du bist kein Mitglied".
  #   * die eigenen Kampagnen — auch die, die noch an keinen Server gebunden
  #     sind. Sie sind der ganze Punkt der Autokonfiguration; ohne sie ließe
  #     sich eine neue Runde per Befehl nie einrichten.
  #
  # Reihenfolge: die Guild-Kampagnen zuerst, damit bei gleichem Namen die
  # hiesige gewinnt. `uniq_by/2` behält den ersten Treffer.
  defp candidates(guild_id, discord_id) do
    (Worker.Repo.campaigns_for_guild(to_string(guild_id)) ++
       Worker.Repo.campaigns_with_guild_for(discord_id))
    |> Enum.uniq_by(& &1.id)
  end

  defp run(campaign, guild_id, _discord_id, :status) do
    status_text(campaign, guild_id)
  end

  defp run(campaign, guild_id, discord_id, sub) do
    # Issue #1082: Mitgliedschaft genügt — dieselbe Schranke, die auch
    # `Recorder.start_for_owner/3` prüft. Zwei Prüfungen mit
    # unterschiedlichem Umfang wären eine Einladung zur Drift.
    if Worker.Repo.campaign_role(campaign.id, discord_id) do
      do_run(campaign, guild_id, discord_id, sub)
    else
      Commands.not_authorized_text(campaign.name)
    end
  end

  # ─── start ───────────────────────────────────────────────────────

  # Der Modus wird auch dann gesetzt, wenn bereits eine Session läuft: der
  # praktisch häufigste Fall ist „Session im Browser gestartet, Modus noch
  # nicht gewählt". `/lore start` soll dann den Bot holen, statt sich über die
  # laufende Session zu beschweren.
  defp do_run(campaign, guild_id, discord_id, :start) do
    case ensure_configured(campaign, guild_id, discord_id) do
      {:error, text} -> text
      {:ok, prefix} -> prefix <> do_start(campaign, discord_id)
    end
  end

  defp do_run(campaign, _guild_id, _discord_id, :stop) do
    case safe(fn -> Recorder.stop_for_campaign(campaign.id) end) do
      # Der Stop läuft in ein Timeout, wenn der Schluss-Flush lange schreibt
      # (#1011). Wichtig ist, was DANN im Chat steht: der Recorder arbeitet den
      # Stop trotzdem vollständig ab, nur die Antwort geht ins Leere — das
      # Audio ist heil. „Da ist etwas schiefgegangen" wäre an dieser Stelle
      # eine Falschaussage, die am Spielabend Panik auslöst.
      {:unavailable, :timeout} ->
        "Der Abschluss dauert länger als erwartet — die Aufnahme wird gerade " <>
          "weggeschrieben. Das Material geht dabei nicht verloren; schau in ein " <>
          "paar Minuten im Hub nach."

      {:unavailable, reason} ->
        Logger.error("CommandInteraction: Recorder nicht erreichbar: #{inspect(reason)}")
        "Der Worker antwortet gerade nicht. Läuft er noch?"

      result ->
        stop_result_text(campaign, result)
    end
  end

  # Issue #1081: die Kampagne an diesen Server binden, wenn sie es noch nicht
  # ist. Die Entscheidung ist pur (`AutoConfig.decide/3`), hier steht nur das
  # Schreiben — und was der Aufrufende darüber erfährt. Eine Einrichtung, die
  # stillschweigend passiert, wäre eine Überraschung: er wollte aufnehmen, nicht
  # konfigurieren.
  defp ensure_configured(campaign, guild_id, discord_id) do
    case AutoConfig.decide(campaign, guild_id, caller_voice_channel(guild_id, discord_id)) do
      {:ok, :already_configured} ->
        {:ok, ""}

      {:ok, {:configure, guild, channel}} ->
        publish_discord_config(campaign, guild, channel)
        {:ok, "Diesen Server als Aufnahme-Ort für „#{campaign.name}\" eingetragen. "}

      {:ok, {:move_channel, guild, channel}} ->
        publish_discord_config(campaign, guild, channel)
        {:ok, "Aufnahme-Kanal auf deinen aktuellen umgestellt. "}

      {:error, :not_in_voice} ->
        {:error,
         "„#{campaign.name}\" ist für diesen Server noch nicht eingerichtet, und ich " <>
           "kann den Sprachkanal nicht erraten. Geh in den Kanal, in dem ihr spielt, und " <>
           "ruf den Befehl dort noch einmal auf."}

      {:error, {:bound_elsewhere, other}} ->
        {:error,
         "„#{campaign.name}\" hängt bereits an einem anderen Discord-Server (#{other}). " <>
           "Ich hänge sie nicht von allein um — das würde die Aufnahme dort abklemmen, " <>
           "ohne dass es jemand merkt. Wenn der Umzug gewollt ist, trag den Server im Hub um."}
    end
  end

  defp do_start(campaign, discord_id) do
    started =
      case safe(fn -> Recorder.start_for_owner(discord_id, campaign.id) end) do
        {:ok, _info} -> :started
        {:error, :already_recording, _existing} -> :already_running
        {:unavailable, reason} -> {:error, {:recorder_unavailable, reason}}
        {:error, reason} -> {:error, reason}
      end

    case started do
      {:error, reason} ->
        start_error_text(reason)

      outcome ->
        choose_discord_mode(campaign, discord_id, outcome)
    end
  end

  defp stop_result_text(campaign, result) do
    case result do
      {:ok, info} ->
        "Aufnahme für „#{campaign.name}\" beendet. Die Transkription läuft jetzt — " <>
          "das Protokoll erscheint im Hub, sobald sie durch ist. (Sitzung #{short(info.session_id)})"

      {:error, :not_recording} ->
        # Kein Recorder-Eintrag heißt nicht zwingend „nichts zu tun": der
        # Worker kann zwischendurch neu gestartet worden sein. Die
        # Unterscheidung (und der Fallback) lebt seit #233 im Hub-Pfad und wird
        # hier geteilt, statt sie ein zweites Mal zu schreiben.
        case Worker.HubClient.Mic.handle_no_recorder_entry(campaign.id) do
          :transcribing ->
            "Die Aufnahme wird bereits abgeschlossen — die Transkription läuft."

          :fallback_published ->
            "Es lief keine Aufnahme mehr (Worker zwischendurch neu gestartet?). " <>
              "Die Sitzung ist jetzt sauber geschlossen."

          :no_session ->
            "Für „#{campaign.name}\" läuft gerade keine Aufnahme."
        end

      {:error, reason} ->
        Logger.warning("CommandInteraction: stop fehlgeschlagen: #{inspect(reason)}")
        "Die Aufnahme konnte nicht beendet werden (#{inspect(reason)})."
    end
  end

  defp choose_discord_mode(campaign, discord_id, outcome) do
    case safe(fn -> Recorder.choose_capture_mode(discord_id, campaign.id, :discord) end) do
      {:unavailable, reason} ->
        Logger.error("CommandInteraction: Recorder nicht erreichbar: #{inspect(reason)}")
        prefix(outcome) <> "Der Aufnahme-Modus konnte nicht gesetzt werden."

      {:ok, :discord} ->
        prefix(outcome) <>
          "Ich bin im Sprachkanal und zeichne auf. Wer noch nicht zugestimmt hat, " <>
          "wird gleich gefragt — bis dahin wird seine Tonspur verworfen."

      {:error, :already_chosen, :browser} ->
        prefix(outcome) <>
          "Diese Sitzung nimmt über die Browser-Mikrofone auf. Beides zugleich geht nicht — " <>
          "für den Discord-Weg muss die Sitzung beendet und neu gestartet werden."

      {:error, :already_chosen, other} ->
        prefix(outcome) <> "Diese Sitzung läuft bereits im Modus #{other}."

      {:error, :discord_unavailable} ->
        prefix(outcome) <>
          "Der Bot kommt nicht in den Sprachkanal. Häufigste Ursachen: der Sprachkanal ist " <>
          "in den Kampagnen-Einstellungen nicht (mehr) eingetragen, oder eine andere " <>
          "Kampagne belegt diesen Server bereits. Der Aufnahme-Modus ist NICHT gesetzt — " <>
          "der Browser-Weg im Hub steht weiter offen."

      {:error, :not_recording} ->
        "Die Sitzung ist nicht mehr offen. Versuch es noch einmal."

      {:error, reason} ->
        Logger.warning("CommandInteraction: choose_capture_mode: #{inspect(reason)}")
        prefix(outcome) <> "Der Aufnahme-Modus konnte nicht gesetzt werden (#{inspect(reason)})."
    end
  end

  defp prefix(:started), do: "Sitzung gestartet. "
  defp prefix(:already_running), do: "Es lief schon eine Sitzung. "

  defp start_error_text(:campaign_not_found),
    do: "Diese Kampagne gibt es auf diesem Worker nicht (mehr)."

  defp start_error_text(:not_authorized),
    do: "Nur die Spielleitung kann die Aufnahme starten."

  defp start_error_text({:recorder_unavailable, _reason}),
    do: "Der Worker antwortet gerade nicht. Läuft er noch?"

  defp start_error_text(reason) do
    Logger.warning("CommandInteraction: start fehlgeschlagen: #{inspect(reason)}")
    "Die Aufnahme konnte nicht gestartet werden (#{inspect(reason)})."
  end

  # Der Sprachkanal des Aufrufers, aus dem `voice_states`-Feld der Guild (#988
  # nutzt dieselbe Quelle für die Anfangs-Präsenz). Best-effort: ohne Nostrum
  # oder bei einem Cache-Miss gibt es eben keinen Kanal, und die Einrichtung
  # sagt das, statt zu raten.
  defp caller_voice_channel(guild_id, discord_id) do
    guild_id
    |> NostrumSafe.voice_states()
    |> AutoConfig.voice_channel_of(discord_id)
  end

  defp publish_discord_config(campaign, guild_id, voice_channel_id) do
    result =
      Worker.Intents.publish(%{
        "kind" => Shared.Events.campaign_discord_config_set(),
        "campaign_id" => campaign.id,
        "guild_id" => to_string(guild_id),
        "voice_channel_id" => to_string(voice_channel_id)
      })

    case result do
      {:ok, :pending} ->
        # Lokal appliziert, aber nicht beim Hub angekommen: die Aufnahme läuft
        # hier trotzdem, in der Weboberfläche erscheint die Einrichtung aber
        # erst mit der nächsten Verbindung. Kein Grund abzubrechen — aber auch
        # nichts, das lautlos verschwinden darf.
        Logger.warning(
          "CommandInteraction: Discord-Config für campaign=#{campaign.id} nur lokal " <>
            "gesetzt (Hub nicht erreichbar) — im Hub erst nach Reconnect sichtbar"
        )

      {:ok, _seq} ->
        Logger.info(
          "CommandInteraction: Discord-Config gesetzt campaign=#{campaign.id} " <>
            "guild=#{guild_id} channel=#{voice_channel_id}"
        )
    end

    :ok
  end

  # ─── status ──────────────────────────────────────────────────────

  defp status_text(campaign, guild_id) do
    case safe(fn -> Recorder.get(campaign.id) end) do
      {:unavailable, _reason} ->
        "Der Worker antwortet gerade nicht — ich kann den Aufnahme-Zustand nicht ablesen."

      nil ->
        "Für „#{campaign.name}\" läuft gerade keine Aufnahme."

      entry ->
        [
          "„#{campaign.name}\": Aufnahme läuft seit #{elapsed(entry)}.",
          mode_line(entry),
          voice_line(guild_id)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
    end
  end

  defp elapsed(%{started_at: %DateTime{} = started}) do
    DateTime.utc_now()
    |> DateTime.diff(started, :second)
    |> Commands.format_duration()
  end

  defp elapsed(_), do: "unbekannt"

  defp mode_line(%{session_id: sid}) do
    case Worker.Repo.get_session_capture_mode(sid) do
      "discord" -> "Aufnahme-Weg: Discord-Sprachkanal."
      "browser" -> "Aufnahme-Weg: Browser-Mikrofone."
      _ -> "Es ist noch kein Aufnahme-Weg gewählt — es wird gerade nichts aufgezeichnet."
    end
  end

  defp mode_line(_), do: nil

  # Die Sprecher-Zahlen leben nur im RAM der VoiceSession. Bleibt die Antwort
  # aus (der Prozess kann während einer Ansage blockieren), fehlt hier eine
  # Zeile — das ist besser als eine erfundene Zahl.
  defp voice_line(guild_id) do
    with {pid, _owner} <- VoiceSession.lookup(normalize_guild_id(guild_id)),
         %{present: present, covered: covered} <- VoiceSession.capture_stats(pid) do
      "Im Sprachkanal: #{present}, davon aufgezeichnet: #{covered}."
    else
      _ -> nil
    end
  end

  defp normalize_guild_id(id) when is_integer(id), do: id

  defp normalize_guild_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {int, _} -> int
      :error -> id
    end
  end

  defp normalize_guild_id(id), do: id

  # ─── Discord-I/O ─────────────────────────────────────────────────

  defp defer(interaction) do
    Nostrum.Api.Interaction.create_response(interaction, %{
      type: @deferred_message,
      data: %{flags: @ephemeral}
    })

    :ok
  rescue
    e ->
      Logger.warning("CommandInteraction: defer fehlgeschlagen: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("CommandInteraction: defer fehlgeschlagen: #{inspect({kind, reason})}")
      :ok
  end

  # Eine leere Liste ist eine gültige Antwort („keine Vorschläge") — im
  # Gegensatz zu gar keiner Antwort, die den Client hängen lässt.
  defp respond_choices(interaction, choices) do
    Nostrum.Api.Interaction.create_response(interaction, %{
      type: @autocomplete_result,
      data: %{choices: choices}
    })

    :ok
  rescue
    e ->
      Logger.warning("CommandInteraction: Vorschläge nicht gesendet: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("CommandInteraction: Vorschläge nicht gesendet: #{inspect({kind, reason})}")
      :ok
  end

  defp reply(interaction, text) do
    Nostrum.Api.Interaction.edit_response(interaction, %{content: text})
    :ok
  rescue
    e ->
      Logger.warning("CommandInteraction: Antwort fehlgeschlagen: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("CommandInteraction: Antwort fehlgeschlagen: #{inspect({kind, reason})}")
      :ok
  end

  # `interaction.user` ist ein voller User-Struct, `member.user_id` die Form aus
  # einem Guild-Kontext. Beides wird von Discord authentifiziert — genau der
  # Grund, warum Slash-Commands eine tragfähige Autorisierungs-Grundlage sind
  # (anders als der akustische Weg, s. #1005).
  defp user_id(interaction) do
    case interaction do
      %{user: %{id: id}} when is_integer(id) -> to_string(id)
      %{member: %{user_id: id}} when is_integer(id) -> to_string(id)
      %{member: %{user: %{id: id}}} when is_integer(id) -> to_string(id)
      _ -> nil
    end
  end

  # Jeder Recorder-Aufruf ist ein `GenServer.call` an einen benannten Prozess.
  # Zwei reale Ausgänge sind KEIN Programmfehler und dürfen deshalb nicht im
  # generischen „etwas ist schiefgegangen" landen: ein Timeout (der Stop hat ein
  # 60-Sekunden-Budget, #1011) und ein nicht laufender Prozess (Neustart nach
  # Crash). Beide brauchen eine eigene, wahre Aussage.
  defp safe(fun) do
    fun.()
  catch
    :exit, {:timeout, _} -> {:unavailable, :timeout}
    :exit, reason -> {:unavailable, reason}
  end

  defp short(session_id) when is_binary(session_id), do: String.slice(session_id, 0, 8)
  defp short(_), do: "?"
end
