defmodule HubWeb.CampaignLiveStatusKindsTest do
  @moduledoc """
  Issue #1122-Nachtrag: die Whitelist in `CampaignLive` und die Klauseln in
  `Mic.on_pipeline_status/2` sind zwei Listen an zwei Orten.

  Beim Laufband ist genau das schiefgegangen: der Empfangszweig für
  `pipeline_fortschritt` stand im Mic-Modul, in der Whitelist fehlte er — und
  der Guard verwarf jede Fortschrittsmeldung still. Kein Fehler, kein Log, nur
  eine Anzeige, die auf dem Stand des Seitenaufrufs stehenblieb (`0/8`, während
  die Pipeline bei Chunk 2 war).

  Der Test liest beide Seiten aus dem Quelltext und hält sie gegeneinander.
  """
  use ExUnit.Case, async: true

  @live File.read!("lib/hub_web/live/campaign_live.ex")
  @mic File.read!("lib/hub_web/live/campaign_live/mic.ex")

  defp whitelist do
    [_, block] = Regex.run(~r/@mic_status_kinds ~w\(([^)]+)\)/s, @live)
    block |> String.split(~r/\s+/, trim: true) |> MapSet.new()
  end

  defp behandelte_kinds do
    ~r/def on_pipeline_status\(\s*socket,\s*%\{\s*"kind" => "([a-z_]+)"/
    |> Regex.scan(@mic)
    |> Enum.map(fn [_, k] -> k end)
    |> MapSet.new()
  end

  test "jedes von Mic behandelte kind steht in der Whitelist" do
    fehlend = MapSet.difference(behandelte_kinds(), whitelist())

    assert MapSet.size(fehlend) == 0,
           "Mic behandelt #{inspect(MapSet.to_list(fehlend))}, aber der Guard in " <>
             "campaign_live.ex lässt es nicht durch — die Meldung wird still verworfen."
  end

  test "pipeline_fortschritt ist dabei — der Regressionsfall" do
    assert "pipeline_fortschritt" in whitelist()
    assert "pipeline_fortschritt" in behandelte_kinds()
  end

  test "der Test findet die Listen überhaupt (sonst prüft er Leeres gegen Leeres)" do
    assert MapSet.size(whitelist()) >= 5
    assert MapSet.size(behandelte_kinds()) >= 2
  end
end
