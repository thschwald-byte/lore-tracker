defmodule HubWeb.Wire.ResuemeeLaengeTest do
  @moduledoc """
  J5 (#1209): Standard und Wertebereich der Resümee-Länge
  (`Shared.ResuemeeLaenge`). In der Hub-Suite, weil `shared` keinen eigenen
  Test-Schritt hat (s. `shared_events_drift_test.exs`); Hub und Worker lesen
  dieselben Zahlen.
  """
  use ExUnit.Case, async: true

  alias Shared.ResuemeeLaenge

  test "Standard 150, erlaubt 30 bis 1000" do
    assert ResuemeeLaenge.standard() == 150
    assert ResuemeeLaenge.untergrenze() == 30
    assert ResuemeeLaenge.obergrenze() == 1000
  end

  # Maintainer, 13.09.2026: der gesetzte Wert ist das Ziel, das Resümee darf
  # bis zum Doppelten wachsen, wenn der Weg der Gruppe es braucht.
  test "hoechstens/1: das Doppelte des wirksamen Ziels" do
    assert ResuemeeLaenge.hoechstens(150) == 300
    assert ResuemeeLaenge.hoechstens(75) == 150
    assert ResuemeeLaenge.hoechstens("120") == 240
    assert ResuemeeLaenge.hoechstens(nil) == 300
    assert ResuemeeLaenge.hoechstens(5) == 300
  end

  test "pruefen/1: ganze Zahlen im Bereich, auch als Text; leer heißt Standard" do
    assert ResuemeeLaenge.pruefen(30) == {:ok, 30}
    assert ResuemeeLaenge.pruefen(1000) == {:ok, 1000}
    assert ResuemeeLaenge.pruefen(" 120 ") == {:ok, 120}
    assert ResuemeeLaenge.pruefen(nil) == :leer
    assert ResuemeeLaenge.pruefen("  ") == :leer

    for x <- [29, 1001, 0, -5, "12a", "7.5", 75.0, %{}, [75]] do
      assert ResuemeeLaenge.pruefen(x) == {:error, :ungueltig}, inspect(x)
    end
  end

  test "wirksam/1: der gültige Wert, sonst der Standard" do
    assert ResuemeeLaenge.wirksam(120) == 120
    assert ResuemeeLaenge.wirksam("300") == 300
    assert ResuemeeLaenge.wirksam(nil) == 150
    assert ResuemeeLaenge.wirksam(5) == 150
    assert ResuemeeLaenge.wirksam("viel") == 150
  end
end
