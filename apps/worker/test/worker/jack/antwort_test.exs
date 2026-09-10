defmodule Worker.Jack.AntwortTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Antwort, Stand}

  @verifiziert "   → Damit ist sie verifiziert — genau dafür ist dieser Durchgang da. " <>
                 "Reich deine nicht noch einmal ein und mach mit der nächsten weiter. Das gilt " <>
                 "auch, wenn sich nur die Formulierung unterscheidet."

  test "im ersten Durchgang heißt Weg 1: schon im Bestand" do
    for n <- [1, 3] do
      text = Antwort.verifikations_hinweis(Stand.neu([]), n)
      assert text =~ "   → Deine ist damit schon im Bestand — reich sie nicht noch einmal ein"
      refute text =~ "Damit ist sie verifiziert"
    end
  end

  test "ab dem zweiten Durchgang ist Weg 1 das Ergebnis, der Rest bleibt" do
    for n <- [1, 3] do
      erster = Antwort.verifikations_hinweis(Stand.neu([]), n) |> String.split("\n")
      zweiter = Antwort.verifikations_hinweis(Stand.neu(durchgang: 2), n) |> String.split("\n")

      assert [{alt, @verifiziert}] =
               erster |> Enum.zip(zweiter) |> Enum.reject(fn {a, b} -> a == b end)

      assert String.starts_with?(alt, "   → Deine ist damit schon im Bestand")
    end
  end

  test "der Kopf ersetzt die erste Zeile, auch im Folgedurchgang" do
    text = Antwort.verifikations_hinweis(Stand.neu(durchgang: 3), 2, "KOPF")
    assert ["KOPF", "" | _] = String.split(text, "\n")
    assert text =~ @verifiziert
  end
end
