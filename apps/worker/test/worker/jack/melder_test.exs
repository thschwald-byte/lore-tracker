defmodule Worker.Jack.MelderTest do
  # J4 (#1207): Jacks Lesefortschritt fürs Laufband — ein Melder je Phase,
  # jeder Block, den diese Phase zum ersten Mal liest, ist eine erledigte
  # Einheit ihrer Stufe.
  use ExUnit.Case, async: true

  alias Worker.Jack.Melder

  defp melder(stufe, gesamt, durchgang, opts \\ []) do
    ich = self()
    Melder.start(fn s, e -> send(ich, {s, e}) end, stufe, gesamt, durchgang, opts)
  end

  defp stand(pid, gelesen),
    do: send(pid, {:jack_stand, %{"phase" => 2, "durchgang" => 1, "gelesen" => gelesen}})

  # Alle gemeldeten Blöcke im Postfach, in Reihenfolge.
  defp gelesen(acc \\ []) do
    receive do
      {_stufe, {:gelesen, n, _nr}} -> gelesen([n | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "meldet die Gesamtzahl und jeden neu gelesenen Block einmal" do
    m = melder("extract", 18, nil)
    assert_receive {"extract", {:zaehlung, 18, nil}}

    stand(m, [[0, 9]])
    # Derselbe Bereich noch einmal plus die übrigen Blöcke: nur die neuen.
    stand(m, [[0, 9], [0, 17]])
    Melder.stopp(m)

    # 18/18, nicht 42/54: der Melder zählt nur diese Phase.
    assert gelesen() == Enum.to_list(0..17)
  end

  test "jede Verifikation zählt neu und nennt ihren Durchgang" do
    # Die Stände zweier Verifikationen ohne Neues tragen denselben Durchgang
    # (Fortsetzung: höchstes `_iter` plus eins) — ein Melder für beide zählte
    # die zweite nicht. Je Durchgang ein Melder.
    for nr <- [1, 2] do
      m = melder("jack_verifikation", 18, nr)
      assert_receive {"jack_verifikation", {:zaehlung, 18, ^nr}}
      stand(m, [[0, 17]])
      Melder.stopp(m)
      for n <- 0..17, do: assert_received({"jack_verifikation", {:gelesen, ^n, ^nr}})
    end
  end

  test "stopp liest aus, was vorher ankam, und wartet, bis der Melder fort ist" do
    m = melder("jack_gedaechtnis", 3, nil)
    stand(m, [[0, 2]])
    :ok = Melder.stopp(m)

    refute Process.alive?(m)
    assert gelesen() == [0, 1, 2]
  end

  test "andere Nachrichten stören nicht" do
    m = melder("extract", 6, nil)
    send(m, {:etwas, :anderes})
    stand(m, [[5, 5]])
    Melder.stopp(m)
    assert gelesen() == [5]
  end

  test "reicht jeden Stand an die Laufsicht weiter" do
    ich = self()
    sicht = spawn_link(fn -> receive do: (x -> send(ich, {:bei_sicht, x})) end)
    m = melder("extract", 1, nil, weiter: sicht)
    stand(m, [[0, 0]])
    assert_receive {:bei_sicht, {:jack_stand, %{"gelesen" => [[0, 0]]}}}
    Melder.stopp(m)
  end
end
