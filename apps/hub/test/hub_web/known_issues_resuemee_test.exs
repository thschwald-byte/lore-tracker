defmodule HubWeb.KnownIssuesResuemeeTest do
  @moduledoc """
  J5 (#1209, B4): die Fehlerklassen des Resümee-Jack haben einen Hinweis in
  `/admin/errors` und stehen im Filter (`known_types/0`). Ohne Hinweis stünde
  der Code roh in der Liste, ohne `known_types`-Eintrag fehlte er im Filter.
  """

  use ExUnit.Case, async: true

  alias HubWeb.KnownIssues

  @klassen ~w(
    resuemee_ueberblick_ohne_abschluss
    resuemee_schreiben_ohne_abschluss
    resuemee_durchsicht_gescheitert
    no_model_configured
  )

  test "jede Klasse hat einen Hinweis und steht in known_types" do
    for k <- @klassen do
      assert %{title: _, body: body} = KnownIssues.hint(k), "#{k} ohne Hinweis"
      assert body != ""
      assert k in KnownIssues.known_types(), "#{k} fehlt in known_types/0"
    end
  end

  test "die gescheiterte Durchsicht sagt, dass trotzdem ein Resümee veröffentlicht wurde" do
    assert KnownIssues.hint("resuemee_durchsicht_gescheitert").body =~ "veröffentlicht"
  end

  test "Überblick und Schreiben ohne Abschluss sagen, dass es kein neues Resümee gibt" do
    for k <- ~w(resuemee_ueberblick_ohne_abschluss resuemee_schreiben_ohne_abschluss) do
      assert KnownIssues.hint(k).body =~ "kein neues Resümee"
    end
  end
end
