defmodule Worker.SettingsUiDriftTest do
  @moduledoc """
  Issue #755 (Reopen): Drift-Guard UI ↔ Settings-Whitelist.

  Die Settings-Whitelist (`Rpc.on_update_settings` filtert gegen
  `Worker.Settings.known_keys()`) verwirft unbekannte Keys STILL — ein
  UI-Feld, dessen Key nicht in der Whitelist steht, ist damit ein totes
  Eingabefeld mit funktionslosem Speichern-Button (die #613-Silent-Failure-
  Klasse; real passiert mit `num_predict_stage{n}` — seit #786 für Stage 2
  tot, mit #812 unbesehen auf Stage 3/4/5 kopiert).

  Dieser Test scannt die Hub-LiveView-Quellen (Cross-App-Dateizugriff im
  Umbrella — der Hub hat keine Worker-Dep, also läuft der Guard hier, wo
  `known_keys/0` erreichbar ist) nach allen `name="settings[...]"`-Feldern
  und prüft jeden geschriebenen Key gegen die Whitelist.

  GRENZE (bewusst): der Test beweist nur Whitelist-Mitgliedschaft ("Save
  kommt im Worker-Store an"), NICHT dass ein Reader den Key konsumiert.
  Ein Key mit Whitelist-Eintrag aber ohne `Settings.get`-Callsite bleibt
  ein totes Setting (die zweite #755-Reopen-Klasse: `temperature_stage3`
  vor diesem Fix). Der Reader-Nachweis ist Handwerk pro Change — ein
  verlässlicher statischer Check dafür existiert (noch) nicht.
  """

  use ExUnit.Case, async: true

  @hub_lib Path.expand("../../../hub/lib", __DIR__)

  # Platzhalter, die in interpolierten Feldnamen vorkommen dürfen, und ihre
  # vollständige Expansion. Neue Interpolation im UI ohne Eintrag hier →
  # Test schlägt mit klarer Meldung fehl (statt still zu übersehen). Seit J6
  # (#1210) hat nur noch Stufe 4 einen Backend-Stack (Stufe 5, das
  # Render-Epos, ist entfallen); Stufe 2 (Jack) schreibt ihre Felder
  # ausgeschrieben (jack_block.ex), samt `resuemee_jack_model` und
  # `epos_jack_model`.
  @stage_ns [4]
  @backends ~w(local anthropic openai google)

  test "jedes settings[...]-Formularfeld im Hub-UI ist ein bekannter Worker.Settings-Key" do
    known = Worker.Settings.known_keys()

    unknown =
      Enum.reject(feldnamen(), fn name ->
        MapSet.member?(known, String.to_atom(name))
      end)

    assert unknown == [],
           "UI-Felder schreiben Keys außerhalb der Settings-Whitelist " <>
             "(Save wird still verworfen — totes Feld): #{inspect(unknown)}"
  end

  test "J4 (#1207): der Scan erfasst die Felder des Jack-Blocks, und keins der entfernten" do
    felder = feldnamen()

    for key <- ~w(jack_temperature jack_top_p jack_frequency_penalty jack_max_tokens ctx_jack) do
      assert key in felder, "#{key} fehlt im UI-Scan — der Jack-Block schreibt ihn nicht"
    end

    for key <-
          ~w(backend_stage2 backend_stage3 model_stage2_anthropic model_stage2_think model_stage2_local_endpoint ctx_stage2 extract_num_predict_cap num_predict_stage3) do
      refute key in felder, "#{key} steht noch als Feld im Hub-UI"
    end
  end

  # Alle Feldnamen der Hub-Formulare, interpolierte expandiert.
  defp feldnamen do
    files = Path.wildcard(Path.join(@hub_lib, "**/*.ex"))
    assert files != [], "Hub-Sourcen nicht gefunden unter #{@hub_lib}"

    field_names =
      files
      |> Enum.flat_map(fn file ->
        Regex.scan(~r/name=\{?"settings\[([^\]]+)\]"/, File.read!(file), capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&{file, &1})
      end)

    assert field_names != [], "keine settings[...]-Felder gefunden — Scan-Regex kaputt?"

    # Die live_select-Modellfelder werden programmatisch gebaut
    # (stage_stack.ex: to_form(%{"model_stage#{n}_#{backend}" => model},
    # as: "settings"); jack_block.ex: dasselbe für "model_stage2_local") — der
    # name=-Scan sieht sie nicht, daher explizit dazu.
    programmatic =
      ["model_stage2_local" | for(n <- @stage_ns, b <- @backends, do: "model_stage#{n}_#{b}")]

    field_names
    |> Enum.flat_map(fn {file, raw} -> expand(raw, file) end)
    |> Enum.concat(programmatic)
    |> Enum.uniq()
  end

  # Die `{:key, "Beschriftung", "Hilfe"}`-Tupel aus dem Wartezeiten-Block.
  defp wartezeiten_keys(file) do
    keys =
      Regex.scan(~r/\{:([a-z][a-z0-9_]*),\s*"/, File.read!(file), capture: :all_but_first)
      |> List.flatten()

    assert keys != [],
           "Wartezeiten-Keys nicht aus #{file} lesbar — der Guard prüft diesen Block sonst nicht"

    keys
  end

  defp expand(raw, file) do
    cond do
      String.contains?(raw, "\#{@n}") ->
        Enum.map(@stage_ns, &String.replace(raw, "\#{@n}", to_string(&1)))

      # Issue #1062: der Wartezeiten-Block rendert seine Felder aus EINER
      # Liste (`HubWeb.EinstellungenLive.Wartezeiten.@gruppen`) statt sie
      # einzeln hinzuschreiben — genau deshalb kann dort kein Feld vergessen
      # werden. Für diesen Scan heisst das: der Feldname ist `settings[\#{key}]`
      # und die Keys stehen in der Liste. Sie wird hier aus der Quelle gelesen;
      # der Hub hat keine Worker-Dep, ein Funktionsaufruf ginge also nicht.
      String.contains?(raw, "\#{key}") and String.ends_with?(file, "wartezeiten.ex") ->
        wartezeiten_keys(file)

      String.contains?(raw, "\#{") ->
        flunk(
          "Unbekannte Interpolation in settings-Feldname #{inspect(raw)} (#{file}) — " <>
            "expand/2 in diesem Test um den Platzhalter erweitern."
        )

      true ->
        [raw]
    end
  end
end
