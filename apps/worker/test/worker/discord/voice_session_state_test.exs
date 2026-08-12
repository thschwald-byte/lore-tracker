defmodule Worker.Discord.VoiceSessionStateTest do
  @moduledoc """
  Regressions-Wächter für einen echten Prod-Crash-Loop (#1002-Hotfix).

  **Was passiert war:** `begin_listening/1` schrieb `%{state | consent_timer: ref}`,
  aber `init/1` legte das Feld nie an. Map-Update-Syntax wirft bei fehlendem Key
  ein `KeyError` → der GenServer starb → `restart: :transient` startete ihn neu →
  `init` joint erneut und spielt die Ansage → nächster Crash. Ergebnis im echten
  Voice-Kanal: **die Ansage lief endlos in Schleife.**

  Die bestehenden Tests konnten das nicht fangen, weil sie die pure Logik prüfen
  (`ConsentPhrase`, `ConsentGate`, `ConsentCheck`) und die `VoiceSession` ohne
  echten Nostrum-Bot nicht startbar ist. Deshalb ist der State-Aufbau jetzt eine
  pure Funktion (`initial_state/3`) — und dieser Test prüft die Invariante, die
  verletzt war:

  > Jedes Feld, das irgendeine Klausel per `%{state | …}` schreibt, muss von
  > `initial_state/3` angelegt werden.

  Der zweite Test liest dazu den Quelltext und vergleicht die Key-Mengen. Das
  fängt auch **künftige** Felder, an die niemand mehr denkt — der Grund, warum
  hier nicht bloß `consent_timer` festgenagelt wird.
  """

  use ExUnit.Case, async: true

  alias Worker.Discord.VoiceSession

  @cfg %{
    campaign_id: "camp-1002",
    session_id: "sess-1002",
    guild_id: 111,
    voice_channel_id: 222
  }

  defp state, do: VoiceSession.initial_state(@cfg, nil, 0)

  test "initial_state legt alle Consent-/Ansage-Felder an" do
    s = state()

    for key <- [
          :listening?,
          :session_start_ms,
          :start_listen_timer,
          :frames,
          :announce_wav,
          :announce_deadline,
          :announce_timer,
          :phase,
          :consent_frames,
          :consents,
          :consent_timer
        ] do
      assert Map.has_key?(s, key), "initial_state/3 legt #{inspect(key)} nicht an"
    end
  end

  test "die cfg-Felder bleiben erhalten" do
    s = state()
    assert s.campaign_id == "camp-1002"
    assert s.session_id == "sess-1002"
    assert s.guild_id == 111
    assert s.voice_channel_id == 222
  end

  test "Startwerte: Consent-Phase zuerst, nichts gesammelt, keine Zustimmung bekannt" do
    s = state()
    assert s.phase == :consent
    assert s.frames == []
    assert s.consent_frames == []
    assert s.consents == %{}
    refute s.listening?
  end

  test "JEDER per %{state | …} geschriebene Key wird von initial_state angelegt" do
    source = File.read!("lib/worker/discord/voice_session.ex")

    used =
      Regex.scan(~r/%\{state \|([^}]*)\}/, source)
      |> Enum.flat_map(fn [_, body] ->
        Regex.scan(~r/([a-z_]+\??):/, body) |> Enum.map(fn [_, k] -> String.to_atom(k) end)
      end)
      |> MapSet.new()

    provided = state() |> Map.keys() |> MapSet.new()
    missing = MapSet.difference(used, provided)

    assert MapSet.size(used) > 0, "Regex fand keine Map-Updates — Test wäre wirkungslos"

    assert MapSet.equal?(missing, MapSet.new()),
           "Diese Felder werden per %{state | …} geschrieben, aber von initial_state/3 NICHT " <>
             "angelegt → KeyError → Crash-Loop: #{inspect(MapSet.to_list(missing))}"
  end
end
