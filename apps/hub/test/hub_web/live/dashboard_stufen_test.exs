defmodule HubWeb.DashboardStufenTest do
  @moduledoc """
  Issue #1122: die Dashboard-Karte leuchtet für JEDE Stufe des Laufs.

  Vorher stand im Empfangspfad eine Whitelist als Literal, der ausgerechnet
  `smooth` fehlte — die längste Stufe (im #1062-Fall über zwei Stunden). Die
  Karte sah untätig aus, während die GPU glühte. Eine fehlende Stufe erzeugt
  keinen Fehler, sondern einen Punkt, der nicht leuchtet: dieselbe stille
  Klasse wie die Permission-Listen aus #1090.
  """
  use ExUnit.Case, async: true

  alias HubWeb.DashboardLive.Cards

  defp status(stages), do: %{"c-1" => MapSet.new(stages)}

  test "die Glättung lässt den LLM-Punkt leuchten — der Regressionsfall" do
    assert Cards.llm_active?(status(["smooth"]), "c-1")
  end

  test "jede Stufe des Laufs zählt, ohne dass jemand sie hier nachtragen muss" do
    for name <- Shared.PipelineStufen.namen() do
      assert Cards.llm_active?(status([name]), "c-1"),
             "Stufe #{name} lässt den Punkt nicht leuchten"
    end
  end

  test "die Transkription bleibt der Whisper-Punkt, nicht der LLM-Punkt" do
    assert Cards.whisper_active?(status(["stage1"]), "c-1")
    refute Cards.llm_active?(status(["stage1"]), "c-1")
  end

  test "ohne Aktivität leuchtet nichts" do
    refute Cards.llm_active?(%{}, "c-1")
    refute Cards.whisper_active?(status([]), "c-1")
  end
end
