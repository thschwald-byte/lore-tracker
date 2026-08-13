defmodule Worker.Discord.ConsentInteraction do
  @moduledoc """
  Issue #1005: die I/O-Hülle um einen Consent-Button-Klick. Die
  *Entscheidungen* liegen in `Worker.Discord.ConsentButton` (pure) — hier steht
  nur, in welcher Reihenfolge was passiert, und warum.

  ## Reihenfolge (nicht beliebig)

    1. **Kontext holen** aus dem Registry (`VoiceSession.lookup/1`) — ohne den
       GenServer zu kontaktieren. Ein `GenServer.call` wäre hier gefährlich: eine
       Discord-Interaction verfällt nach **3 Sekunden**, und die Session kann
       zwischenzeitlich blockieren (TTS läuft synchron).
    2. **Prüfen** (pure): gehört der Klick zur laufenden Sitzung, zum aktuellen
       Wortlaut, und kommt er aus unserem Kanal?
    3. **Antworten** — bevor irgendetwas Persistierendes passiert. Sonst kostet
       eine Mnesia-Transaktion oder ein Hub-Call den Zeitpuffer.
    4. **Session informieren** (`cast`, setzt Zustand + Zeitstempel).
    5. **Persistieren** (`Intents.publish/1`: lokaler Apply + Hub-Push).

  Schritte 4 und 5 laufen im Consumer-Task (Nostrum spawnt pro Event einen),
  nicht im `VoiceSession`-Prozess — der nimmt 50 Audio-Pakete pro Sekunde und
  Sprecher an und darf nicht auf Mnesia oder den Hub warten.

  ## Warum der Kanal geprüft wird

  Pro Guild läuft höchstens eine Voice-Session (Discord-Protokoll-Limit, #987).
  Ohne Kanal-Prüfung könnte jemand über eine liegengebliebene Button-Nachricht in
  einem **anderen** Kanal in die laufende Sitzung hineinklicken.
  """

  require Logger

  alias Worker.Discord.{ConsentButton, ConsentGate, VoiceSession}

  # Discord-Flag für „nur der Klickende sieht die Antwort".
  @ephemeral 64
  @response_message 4

  @doc """
  Verarbeitet eine Interaction. Alles, was kein Consent-Button-Klick ist, ist ein
  stiller No-op (andere Features dürfen dieselbe Event-Quelle nutzen).
  """
  @spec handle(map()) :: :ok
  def handle(%{data: %{custom_id: custom_id}} = interaction) when is_binary(custom_id) do
    parsed = ConsentButton.parse_custom_id(custom_id)

    case parsed do
      {:error, :malformed} ->
        # Fremdes Feature oder Müll — nicht unser Klick, keine Antwort.
        :ok

      {:ok, _action, _version, _session} ->
        route(interaction, parsed)
    end
  end

  def handle(_interaction), do: :ok

  # ─── intern ──────────────────────────────────────────────────────

  defp route(interaction, parsed) do
    guild_id = Map.get(interaction, :guild_id)
    discord_id = user_id(interaction)

    case VoiceSession.lookup(guild_id) do
      nil ->
        # Keine laufende Session in dieser Guild → der Klick gehört zu einer
        # beendeten Aufnahme.
        respond(interaction, ConsentButton.reject_text(:stale_session))

      {pid, owner} ->
        decide(interaction, parsed, pid, owner, discord_id)
    end
  end

  defp decide(interaction, parsed, pid, owner, discord_id) do
    cond do
      not correct_channel?(interaction, owner) ->
        respond(interaction, ConsentButton.reject_text(:stale_session))

      is_nil(discord_id) ->
        # Ohne Identität keine Einwilligung — der Kern-Grund, warum es den Button
        # überhaupt gibt.
        Logger.warning("ConsentInteraction: Klick ohne user_id — verworfen")
        respond(interaction, ConsentButton.reject_text(:malformed))

      true ->
        apply_verdict(
          interaction,
          ConsentButton.verdict_for_click(parsed, ConsentGate.version(), owner.session_id),
          pid,
          owner,
          discord_id
        )
    end
  end

  defp apply_verdict(interaction, {:reject, reason}, _pid, owner, discord_id) do
    Logger.info(
      "ConsentInteraction: Klick abgelehnt (#{reason}) campaign=#{owner.campaign_id} " <>
        "did=#{discord_id}"
    )

    respond(interaction, ConsentButton.reject_text(reason))
  end

  defp apply_verdict(interaction, {:accept, action}, pid, owner, discord_id) do
    Logger.info("ConsentInteraction: #{action} campaign=#{owner.campaign_id} did=#{discord_id}")

    # 3. Antworten ZUERST (3-Sekunden-Deadline).
    respond(interaction, ConsentButton.ack_text(action))

    # 4. Session informieren (Zustand + Zeitstempel auf der Frame-Uhr).
    VoiceSession.consent_click(pid, action, discord_id)

    # 5. Persistieren (dauerhaft, gilt auch für künftige Aufnahmen).
    publish(action, discord_id)

    :ok
  end

  # `interaction.user` ist ein voller User-Struct (Nostrum füllt ihn aus
  # `member.user`, bevor gecastet wird) — die Identität kommt also ohne
  # HTTP-Call, und sie ist von Discord authentifiziert.
  defp user_id(interaction) do
    case interaction do
      %{user: %{id: id}} when is_integer(id) -> to_string(id)
      %{member: %{user_id: id}} when is_integer(id) -> to_string(id)
      _ -> nil
    end
  end

  defp correct_channel?(interaction, owner) do
    case Map.get(interaction, :channel_id) do
      nil -> false
      id -> to_string(id) == to_string(owner.voice_channel_id)
    end
  end

  defp publish(:grant, discord_id) do
    Worker.Intents.publish(%{
      "kind" => Shared.Events.audio_consent_recorded(),
      "discord_id" => discord_id,
      "version" => ConsentGate.version(),
      "accepted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp publish(:revoke, discord_id) do
    Worker.Intents.publish(%{
      "kind" => Shared.Events.audio_consent_revoked(),
      "discord_id" => discord_id,
      "version" => ConsentGate.version(),
      "revoked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # Best-effort: eine fehlgeschlagene Antwort darf den Consent-Pfad nicht
  # abbrechen (der Klick zählt trotzdem — die Persistenz ist das Verbindliche,
  # nicht die Bestätigung im Chat).
  defp respond(interaction, text) do
    Nostrum.Api.Interaction.create_response(interaction, %{
      type: @response_message,
      data: %{content: text, flags: @ephemeral}
    })

    :ok
  rescue
    e ->
      Logger.warning("ConsentInteraction: Antwort fehlgeschlagen: #{Exception.message(e)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("ConsentInteraction: Antwort fehlgeschlagen: #{inspect({kind, reason})}")
      :ok
  end
end
