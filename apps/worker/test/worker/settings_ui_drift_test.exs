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
  # Test schlägt mit klarer Meldung fehl (statt still zu übersehen).
  @stage_ns 2..5
  @backends ~w(local anthropic openai google)

  test "jedes settings[...]-Formularfeld im Hub-UI ist ein bekannter Worker.Settings-Key" do
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

    known = Worker.Settings.known_keys()

    # Das live_select-Modellfeld wird programmatisch gebaut
    # (stage_stack.ex: to_form(%{"model_stage#{n}_#{backend}" => model},
    # as: "settings")) — der name=-Scan sieht es nicht, daher explizit dazu.
    programmatic =
      for n <- @stage_ns, b <- @backends, do: "model_stage#{n}_#{b}"

    expanded =
      field_names
      |> Enum.flat_map(fn {file, raw} -> expand(raw, file) end)
      |> Enum.concat(programmatic)
      |> Enum.uniq()

    unknown =
      Enum.reject(expanded, fn name ->
        MapSet.member?(known, String.to_atom(name))
      end)

    assert unknown == [],
           "UI-Felder schreiben Keys außerhalb der Settings-Whitelist " <>
             "(Save wird still verworfen — totes Feld): #{inspect(unknown)}"
  end

  defp expand(raw, file) do
    cond do
      String.contains?(raw, "\#{@n}") ->
        Enum.map(@stage_ns, &String.replace(raw, "\#{@n}", to_string(&1)))

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
