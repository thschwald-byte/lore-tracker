defmodule Worker.Discord.AutoConfig do
  @moduledoc """
  Issue #1081: eine Kampagne beim ersten `/lore start` selbst an den Server
  binden, aus dem der Befehl kam.

  ## Warum das überhaupt gebaut wird

  Die Einrichtung war bis dahin: Web-Oberfläche öffnen, im Discord-Client den
  Entwicklermodus einschalten, Guild-ID per Rechtsklick kopieren, Sprachkanal-ID
  per Rechtsklick kopieren, beides eintragen, speichern — und *dann* im Discord
  `/lore start` tippen. Für jemanden, der einfach anfangen will, ist das eine
  unangemessene Hürde.

  Beide Angaben liegen zum Zeitpunkt des Befehls ohnehin vor: die Guild steht in
  der Interaction, und der Sprachkanal ist der, in dem der Aufrufer gerade
  sitzt.

  ## Die Entscheidung ist pur, das Schreiben nicht

  `decide/3` trifft die Entscheidung ohne Nostrum und ohne Mnesia (Muster
  `ConsentGate`, `Presence`) — die `VoiceSession` ist ohne echten Bot kaum
  testbar, diese Regeln sollen es sein.

  ## Was NICHT automatisch passiert

  Hängt die Kampagne bereits an einer **anderen** Guild, wird sie nicht
  stillschweigend umgehängt. Das würde die Aufnahme in der anderen Runde
  abklemmen, ohne dass es dort jemand merkt — und zwar an einem Abend, an dem
  niemand damit rechnet. Der Fall wird gemeldet und braucht einen bewussten
  zweiten Schritt über die Web-Oberfläche.

  Ein Wechsel des **Sprachkanals innerhalb desselben Servers** ist dagegen
  harmlos (die Runde ist in einen anderen Kanal umgezogen) und wird ohne
  Rückfrage übernommen.
  """

  @type decision ::
          {:ok, :already_configured}
          | {:ok, {:configure, String.t(), String.t()}}
          | {:ok, {:move_channel, String.t(), String.t()}}
          | {:error, :not_in_voice}
          | {:error, {:bound_elsewhere, String.t()}}

  @doc """
  Was ist zu tun, damit diese Kampagne auf diesem Server aufnehmen kann?

  - `campaign` — mit `:discord_guild_id` / `:discord_voice_channel_id` (je `nil`,
    wenn nicht gesetzt)
  - `guild_id` — der Server, aus dem der Befehl kam
  - `caller_voice_channel` — der Sprachkanal, in dem der Aufrufer sitzt (`nil`,
    wenn er in keinem sitzt)
  """
  @spec decide(map(), String.t() | integer() | nil, String.t() | integer() | nil) :: decision()
  def decide(campaign, guild_id, caller_voice_channel) do
    bound_guild = norm(Map.get(campaign, :discord_guild_id))
    bound_channel = norm(Map.get(campaign, :discord_voice_channel_id))
    here = norm(guild_id)
    voice = norm(caller_voice_channel)

    cond do
      is_nil(here) ->
        {:error, :not_in_voice}

      # Fremde Guild: nie still übernehmen.
      not is_nil(bound_guild) and bound_guild != here ->
        {:error, {:bound_elsewhere, bound_guild}}

      # Vollständig und passend eingerichtet.
      bound_guild == here and not is_nil(bound_channel) and
          (is_nil(voice) or voice == bound_channel) ->
        {:ok, :already_configured}

      # Ab hier brauchen wir den Kanal des Aufrufers — ohne ihn gibt es nichts
      # zu erraten.
      is_nil(voice) ->
        {:error, :not_in_voice}

      # Gleiche Guild, anderer Kanal: die Runde ist umgezogen.
      bound_guild == here ->
        {:ok, {:move_channel, here, voice}}

      # Noch gar nicht eingerichtet.
      true ->
        {:ok, {:configure, here, voice}}
    end
  end

  @doc """
  In welchem Sprachkanal sitzt `discord_id` in dieser Guild?

  Pur — nimmt die Rohliste `voice_states` entgegen (kein Nostrum-Aufruf hier
  drin), exakt wie `Presence.initial_participants/3`. `nil`, wenn die Person in
  keinem Kanal sitzt.
  """
  @spec voice_channel_of([map()], String.t() | integer() | nil) :: String.t() | nil
  def voice_channel_of(voice_states, discord_id) when is_list(voice_states) do
    needle = norm(discord_id)

    voice_states
    |> Enum.find(fn vs -> norm(Map.get(vs, :user_id)) == needle and Map.get(vs, :channel_id) end)
    |> case do
      nil -> nil
      vs -> norm(Map.get(vs, :channel_id))
    end
  end

  def voice_channel_of(_, _), do: nil

  defp norm(nil), do: nil

  defp norm(v) do
    case v |> to_string() |> String.trim() do
      "" -> nil
      s -> s
    end
  end
end
