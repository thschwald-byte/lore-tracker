defmodule HubWeb.KnownIssuesEposTest do
  @moduledoc """
  J6 (#1210, E4): die Fehlerklassen des Epos-Jack haben einen Hinweis in
  `/admin/errors` und stehen im Filter (`known_types/0`). Ohne Hinweis stünde
  der Code roh in der Liste, ohne `known_types`-Eintrag fehlte er im Filter.
  """

  use ExUnit.Case, async: true

  alias HubWeb.KnownIssues

  @klassen ~w(
    epos_ueberblick_ohne_abschluss
    epos_schreiben_ohne_abschluss
    epos_durchsicht_gescheitert
  )

  test "jede Klasse hat einen Hinweis und steht in known_types" do
    for k <- @klassen do
      assert %{title: _, body: body} = KnownIssues.hint(k), "#{k} ohne Hinweis"
      assert body != ""
      assert k in KnownIssues.known_types(), "#{k} fehlt in known_types/0"
    end
  end

  test "die gescheiterte Durchsicht sagt, dass trotzdem ein Kapitel veröffentlicht wurde" do
    assert KnownIssues.hint("epos_durchsicht_gescheitert").body =~ "veröffentlicht"
  end

  test "Überblick und Schreiben ohne Abschluss: kein neues Kapitel, das bisherige bleibt, der Lauf ging weiter" do
    for k <- ~w(epos_ueberblick_ohne_abschluss epos_schreiben_ohne_abschluss) do
      body = KnownIssues.hint(k).body
      assert body =~ "kein neues Kapitel"
      assert body =~ "das bisherige bleibt stehen"
      assert body =~ "der Lauf ging weiter"
      assert body =~ "epos_jack_model"
    end
  end

  test "ein fehlendes Modell nennt auch das Modell des Epos-Jack" do
    assert KnownIssues.hint("no_model_configured").body =~ "epos_jack_model"
  end
end
