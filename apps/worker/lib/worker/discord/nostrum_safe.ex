defmodule Worker.Discord.NostrumSafe do
  @moduledoc """
  Best-effort-Kapselung der Nostrum-Voice-Aufrufe, die den Aufnahme-Pfad NIE
  mitreißen dürfen (Issue #1013-Split; Muster ursprünglich `safe_ssrc_map/1`
  aus dem #941-Spike): ein Fehler in Nostrums Voice-Infrastruktur — Gateway
  down, Voice-Prozess tot, Race beim Teardown — degradiert hier zu einem
  neutralen Rückgabewert statt zu einem Crash des Session-GenServers
  (`restart: :transient` ⇒ Crash = Neu-Join = Ansage-Schleife, der
  #1002-Live-Bug).

  Alles hier ist bewusst DUMM: kein Zustand, keine Entscheidung — nur
  „Nostrum fragen und Fehler schlucken". Die eine Ausnahme vom stillen
  Schlucken ist `leave_channel/2`: dort wird der Fehler geloggt, weil ein
  zweiter Live-Test-Fund war, dass ein rescue/catch OHNE jedes Logging das
  Diagnostizieren unmöglich machte, als der Bot trotz Fix im Kanal hängen
  blieb (#987-Nacharbeit).
  """

  require Logger

  alias Nostrum.Voice

  @doc "Ist die Voice-Verbindung bereit? (false auch bei jedem Nostrum-Fehler)"
  @spec ready?(non_neg_integer()) :: boolean()
  def ready?(guild_id) do
    Voice.ready?(guild_id)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc "Wird gerade Audio abgespielt? (false auch bei jedem Nostrum-Fehler)"
  @spec playing?(non_neg_integer()) :: boolean()
  def playing?(guild_id) do
    Voice.playing?(guild_id)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc "SSRC→User-Mapping der Guild; leere Map bei jedem Fehler (nie raten)."
  @spec ssrc_map(non_neg_integer()) :: map()
  def ssrc_map(guild_id) do
    Voice.get_ssrc_map(guild_id)
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  @doc """
  Voice-Channel verlassen — best-effort, aber SICHTBAR (s. Moduledoc): Nostrums
  Voice-State pro Guild lebt unabhängig vom Session-GenServer; ohne diesen
  Aufruf bliebe der Bot nach dem Stop im Kanal hängen (#987-Live-Fund).
  """
  @spec leave_channel(non_neg_integer(), String.t()) :: :ok
  def leave_channel(guild_id, campaign_id) do
    result = Voice.leave_channel(guild_id)

    Logger.info(
      "Worker.Discord.NostrumSafe: leave_channel campaign=#{campaign_id} " <>
        "guild=#{guild_id} result=#{inspect(result)}"
    )

    :ok
  rescue
    e ->
      Logger.warning(
        "Worker.Discord.NostrumSafe: leave_channel fehlgeschlagen campaign=#{campaign_id} " <>
          "guild=#{guild_id}: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Worker.Discord.NostrumSafe: leave_channel fehlgeschlagen campaign=#{campaign_id} " <>
          "guild=#{guild_id}: #{inspect({kind, reason})}"
      )

      :ok
  end

  @doc "Discord-ID des eigenen Bot-Accounts als String; nil bei jedem Fehler."
  @spec me_did() :: String.t() | nil
  def me_did do
    case Nostrum.Cache.Me.get() do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  WAV abspielen (#989-Erst-Ansage) — Fehler als benannter Reason zurück, nie
  ein Crash. Der Rückgabewert von `Voice.play/4` wird hier bewusst NICHT auf
  busy geprüft: die Erst-Ansage ist das erste Audio der Verbindung, ein
  busy-Fall wäre ein Programmierfehler und fiele als {:error, _} auf.
  """
  @spec play_url(non_neg_integer(), Path.t(), String.t()) :: :ok | {:error, term()}
  def play_url(guild_id, wav, campaign_id) do
    Logger.info(
      "Worker.Discord.NostrumSafe: Ansage abspielen campaign=#{campaign_id} " <>
        "guild=#{guild_id} wav=#{wav}"
    )

    case Voice.play(guild_id, wav, :url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:announce_play_failed, reason}}
    end
  rescue
    e -> {:error, {:announce_play_failed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:announce_play_failed, inspect({kind, reason})}}
  end

  @doc """
  Issue #1081: die `voice_states` einer Guild — wer sitzt gerade in welchem
  Sprachkanal. Öffentliches Feld der `Nostrum.Struct.Guild` (dieselbe Quelle,
  die `VoiceSession.initial_participants/1` seit #988 nutzt), kein Zugriff auf
  Interna.

  Leere Liste, wenn Nostrum nicht läuft oder die Guild nicht im Cache ist —
  der Aufrufer behandelt das als „kein Kanal bekannt".
  """
  @spec voice_states(non_neg_integer() | String.t() | nil) :: [map()]
  def voice_states(nil), do: []

  def voice_states(guild_id) do
    id =
      case guild_id do
        i when is_integer(i) ->
          i

        s when is_binary(s) ->
          case Integer.parse(String.trim(s)) do
            {i, _} -> i
            :error -> nil
          end

        _ ->
          nil
      end

    if id do
      Nostrum.Cache.GuildCache.get!(id) |> Map.get(:voice_states) |> List.wrap()
    else
      []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end
end
