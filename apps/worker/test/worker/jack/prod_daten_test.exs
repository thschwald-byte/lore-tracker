defmodule Worker.Jack.ProdDatenTest do
  @moduledoc """
  Jacks Werkzeuge gegen eine echte Prod-Sitzung (`mix lore.jack.abzug`).
  Läuft nur ausdrücklich, weil der Abzug den Mitschnitt der echten Runde
  enthält und außerhalb des Repos liegt:

      JACK_TESTDATEN=~/.local/share/lore-jack/testdaten/<name> \\
        mix test --only jack_prod test/worker/jack/prod_daten_test.exs

  Die Assertions nennen keine Inhalte aus dem Mitschnitt; eine fehlschlagende
  soll keine Zeile der Runde ins Terminal oder in eine CI-Ausgabe tragen.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.{Abzug, Beleg, Lesen, Stand}

  @moduletag :jack_prod

  setup_all do
    dir = System.get_env("JACK_TESTDATEN") || flunk("JACK_TESTDATEN ist nicht gesetzt.")

    case Abzug.laden(Path.expand(dir)) do
      {:ok, abzug} -> {:ok, abzug: abzug}
      {:error, grund} -> flunk("Abzug nicht ladbar: #{inspect(grund)}")
    end
  end

  test "alle Blöcke laden, jeder mit Sprecher als Figurenname", %{abzug: a} do
    assert length(a.bloecke) == a.meta["bloecke"]
    assert Enum.all?(a.bloecke, &(is_binary(&1.sprecher) and &1.sprecher != ""))
    refute Enum.any?(a.bloecke, &Regex.match?(~r/^\d{15,20}$/, &1.sprecher))
    assert a.bloecke |> Enum.map(& &1.block_id) |> Enum.uniq() |> length() == length(a.bloecke)
  end

  test "bloecke liest den ganzen Mitschnitt, eine Zeile je Block", %{abzug: a} do
    s = Abzug.stand(a)
    {s, {:ok, text}} = Lesen.bloecke(s, %{"von" => 0, "bis" => s.max_block})
    assert length(String.split(text, "\n")) == length(a.bloecke)
    assert s.gelesen == [{0, s.max_block}]
  end

  test "jeder Block trägt sich selbst als Beleg — Normalisierung und Stückelung halten auf echtem Text",
       %{abzug: a} do
    s = Abzug.stand(a)

    fehlschlaege =
      for {b, i} <- Enum.with_index(a.bloecke),
          Beleg.stuecke(b.text) != [],
          not Beleg.nur_fragen?(b.text),
          Beleg.fehler(b.text, [i], s.bloecke) != nil,
          do: i

    assert fehlschlaege == [],
           "#{length(fehlschlaege)} Blöcke tragen sich nicht selbst (Nummern: #{inspect(Enum.take(fehlschlaege, 20))})"
  end

  test "der Cast enthält keinen Handle", %{abzug: a} do
    refute Enum.any?(a.cast, &Regex.match?(~r/^[\p{Ll}\d._]+$/u, &1))
    assert %Stand{cast: cast} = Abzug.stand(a)
    assert cast == a.cast
  end
end
