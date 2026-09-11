defmodule Worker.Jack.MelderTest do
  # J4 (#1207): Jacks Lesefortschritt fürs Laufband — jeder Block, den eine
  # Phase zum ersten Mal liest, ist eine erledigte Einheit.
  use ExUnit.Case, async: true

  alias Worker.Jack.Melder

  defp melder(gesamt) do
    ich = self()
    Melder.start(%{session_id: "s1"}, gesamt, &send(ich, &1))
  end

  defp stand(pid, phase, durchgang, gelesen),
    do:
      send(
        pid,
        {:jack_stand, %{"phase" => phase, "durchgang" => durchgang, "gelesen" => gelesen}}
      )

  test "meldet die Gesamtzahl und jeden neu gelesenen Block einmal je Phase" do
    m = melder(30)
    assert_receive {:gesamt, %{session_id: "s1"}, 30}

    stand(m, 1, 1, [[0, 2]])
    for n <- 0..2, do: assert_receive({:fertig, _, {{1, 1}, ^n}})

    # Derselbe Bereich noch einmal plus zwei neue Blöcke: nur die neuen.
    stand(m, 1, 1, [[0, 2], [0, 4]])
    for n <- 3..4, do: assert_receive({:fertig, _, {{1, 1}, ^n}})
    refute_receive {:fertig, _, {{1, 1}, 0}}, 50

    # Phase 2 liest dieselben Blöcke neu — das sind neue Einheiten.
    stand(m, 2, 1, [[0, 1]])
    for n <- 0..1, do: assert_receive({:fertig, _, {{2, 1}, ^n}})

    Melder.stopp(m)
  end

  test "andere Nachrichten stören nicht" do
    m = melder(1)
    assert_receive {:gesamt, _, 1}
    send(m, {:etwas, :anderes})
    stand(m, 2, 2, [[5, 5]])
    assert_receive {:fertig, _, {{2, 2}, 5}}
    Melder.stopp(m)
  end
end
