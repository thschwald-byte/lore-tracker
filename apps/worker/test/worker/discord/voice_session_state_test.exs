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
          :consents,
          :consent_history
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

  test "Startwerte: ein Puffer, keine Zustimmung bekannt, noch nicht zuhörend" do
    s = state()
    # Issue #1005: `phase`/`consent_frames` sind weg — es gibt nur EINEN Puffer,
    # und was daraus gespeichert werden darf, entscheidet die Zeitachse beim
    # Flush (ConsentState), nicht eine Weiche im Hot-Path.
    refute Map.has_key?(s, :phase)
    refute Map.has_key?(s, :consent_frames)
    assert s.frames == []
    assert s.consents == %{}
    assert s.consent_history == %{}
    refute s.listening?
  end

  # Die Quelltext-Wächter prüfen CODE, nicht Prosa: Kommentarzeilen werden
  # entfernt, sonst schlägt ein Beispiel im Moduledoc als echter Fund an (genau
  # das passierte beim Schreiben des Timer-Wächters — `:x` aus einem Kommentar).
  defp code_only(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  test "JEDER per %{state | …} geschriebene Key wird von initial_state angelegt" do
    # Issue #1013: der Announcer schreibt den Session-State per Delegation mit —
    # seine Map-Updates unterliegen derselben Crash-Loop-Invariante.
    source =
      code_only("lib/worker/discord/voice_session.ex") <>
        code_only("lib/worker/discord/announcer.ex")

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

  # ─── Issue #1005: zwei weitere Wächter derselben Bauart ─────────────
  #
  # Beide fangen dieselbe Fehlerklasse wie der Test oben: etwas wird ergänzt,
  # das Aufräumen/Abfangen wird vergessen, und weil der Prozess
  # `restart: :transient` hat, endet das in einer Crash-Schleife statt in einem
  # sichtbaren Fehler.

  test "JEDER send_after-Timer hat ein Feld in @timer_keys UND eine handle_info-Klausel" do
    # Issue #1013: der Announcer setzt Timer IM Session-Prozess (Delegation,
    # kein eigener Prozess) — seine send_afters gehören mit bewacht, die
    # handle_info-Klauseln bleiben in der VoiceSession (dort wird gescannt).
    timer_sources =
      code_only("lib/worker/discord/voice_session.ex") <>
        code_only("lib/worker/discord/announcer.ex")

    source = code_only("lib/worker/discord/voice_session.ex")

    # Ziel-Atome aller Selbst-Timer, z.B. `Process.send_after(self(), :presence_tick, …)`
    targets =
      Regex.scan(~r/Process\.send_after\(self\(\),\s*:([a-z_]+)/, timer_sources)
      |> Enum.map(fn [_, t] -> t end)
      |> Enum.uniq()

    assert targets != [], "Regex fand keine Selbst-Timer — Test wäre wirkungslos"
    assert "queue_next" in targets, "Announcer-Timer nicht mehr im Scan — Wächter verlor Abdeckung"

    keys = VoiceSession.timer_keys() |> Enum.map(&Atom.to_string/1) |> MapSet.new()

    for target <- targets do
      # Konvention: Timer-Ziel `:announce_try` wird im Feld `:announce_timer`
      # gehalten — der Präfix bis zum ersten Unterstrich-Wort muss passen.
      has_field =
        Enum.any?(keys, fn key -> String.starts_with?(key, hd(String.split(target, "_"))) end)

      assert has_field,
             "Timer-Ziel :#{target} hat kein passendes Feld in @timer_keys " <>
               "(#{inspect(MapSet.to_list(keys))}) → cancel_timers/1 räumt ihn nie auf"

      assert source =~ "def handle_info(:#{target}",
             "Timer-Ziel :#{target} hat keine handle_info-Klausel → Catch-all schluckt ihn still"
    end
  end

  test "eine Catch-all-handle_info-Klausel existiert (gegen Crash-Loop)" do
    source = code_only("lib/worker/discord/voice_session.ex")

    assert source =~ ~r/def handle_info\((?:msg|_msg|_)\b/,
           "Ohne Catch-all-handle_info ist jede unerwartete Nachricht ein FunctionClauseError — " <>
             "bei restart: :transient also Crash → Neu-Join → Ansage → Crash (der #1002-Live-Bug)"
  end
end
