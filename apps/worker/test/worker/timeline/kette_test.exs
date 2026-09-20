defmodule Worker.Timeline.KetteTest do
  @moduledoc """
  #1247: die Kette — Glieder aus mehreren Äußerungen, vier Operationen, und
  die eine Invariante, die alles trägt: **sie bleibt durchgehend**
  (Maintainer, 20.09.2026).
  """
  use ExUnit.Case, async: true

  alias Worker.Timeline.Kette

  defp utts(n), do: for(i <- 1..n, do: "u#{i}")

  defp mit(kette, gruppen) do
    Enum.reduce(gruppen, kette, fn g, k ->
      {:ok, k, _} = Kette.anhaengen(k, g)
      k
    end)
  end

  defp folge(kette), do: Kette.reihenfolge(kette)

  describe "die Kette beginnt leer" do
    test "ohne Zutun ist nichts eingereiht — und alles offen" do
      # Maintainer, 20.09.2026: „Default beim Start: Kette ist leer — jack
      # soll bewusst einsortieren." Ohne das hiesse „nicht angefasst"
      # zweierlei zugleich: „die Reihenfolge stimmt" und „ich bin noch nicht
      # hingekommen".
      k = Kette.neu()

      assert folge(k) == []
      assert Kette.offen(k, utts(5)) == utts(5)
    end

    test "was eingereiht ist, ist nicht mehr offen" do
      k = Kette.neu() |> mit([["u1", "u2"], ["u3"]])

      assert Kette.offen(k, utts(5)) == ["u4", "u5"]
    end

    test "was draussen ist, ist ebenfalls entschieden" do
      {:ok, k} = Kette.draussen(Kette.neu(), ["u4", "u5"], "Tischgespräch")
      k = mit(k, [["u1", "u2", "u3"]])

      assert Kette.offen(k, utts(5)) == []
    end
  end

  describe "ein Glied trägt mehrere Äußerungen" do
    test "eine Szene ist EIN Glied" do
      # Maintainer: „jack soll auch kettenglieder aus mehreren utts bilden
      # können." Erst dadurch wird die Kette kurz genug, um sie zu lesen.
      {:ok, k, g} = Kette.anhaengen(Kette.neu(), ["u10", "u11", "u12"])

      assert length(k.glieder) == 1
      assert g.utts == ["u10", "u11", "u12"]
      assert folge(k) == ["u10", "u11", "u12"]
    end

    test "ein Glied ohne Äußerung wird abgelehnt, nicht stillschweigend angelegt" do
      assert {:fehler, text} = Kette.anhaengen(Kette.neu(), [])
      assert text =~ "mindestens eine Zeile"
    end

    test "dieselbe Äußerung liegt in höchstens EINEM Glied" do
      # Sonst stünde sie an zwei Stellen der Zeit, und die Kette wäre keine
      # Reihenfolge mehr.
      k = Kette.neu() |> mit([["u1", "u2", "u3"]])
      {:ok, k, _} = Kette.anhaengen(k, ["u2"])

      assert folge(k) == ["u1", "u3", "u2"]
      assert length(k.glieder) == 2
    end

    test "ein Glied, dem alle Äußerungen entzogen werden, fällt weg" do
      k = Kette.neu() |> mit([["u1"], ["u2"]])
      {:ok, k, _} = Kette.anhaengen(k, ["u1", "u2"])

      assert length(k.glieder) == 1
      assert folge(k) == ["u1", "u2"]
    end
  end

  describe "die vier Operationen halten die Kette durchgehend" do
    setup do
      %{k: Kette.neu() |> mit([["u1"], ["u2"], ["u3"], ["u4"], ["u5"]])}
    end

    test "anhängen: hinten, vorn, vor und nach einem Glied", %{k: k} do
      ziel = Kette.glied_von(k, "u3").id

      {:ok, a, _} = Kette.anhaengen(k, ["u6"])
      assert folge(a) == ~w(u1 u2 u3 u4 u5 u6)

      {:ok, b, _} = Kette.anhaengen(k, ["u6"], anfang: true)
      assert folge(b) == ~w(u6 u1 u2 u3 u4 u5)

      {:ok, c, _} = Kette.anhaengen(k, ["u6"], vor: ziel)
      assert folge(c) == ~w(u1 u2 u6 u3 u4 u5)

      {:ok, d, _} = Kette.anhaengen(k, ["u6"], nach: ziel)
      assert folge(d) == ~w(u1 u2 u3 u6 u4 u5)
    end

    test "versetzen in BEIDE Richtungen", %{k: k} do
      # Maintainer: „verschiebe uuid a hinter uuid b — aber es muss auch
      # geben verschiebe uuid a vor uuid b."
      fuenf = Kette.glied_von(k, "u5").id
      zwei = Kette.glied_von(k, "u2").id

      {:ok, vor} = Kette.versetzen(k, fuenf, {:vor, zwei})
      assert folge(vor) == ~w(u1 u5 u2 u3 u4)

      {:ok, nach} = Kette.versetzen(k, fuenf, {:nach, zwei})
      assert folge(nach) == ~w(u1 u2 u5 u3 u4)

      {:ok, anfang} = Kette.versetzen(k, fuenf, :anfang)
      assert folge(anfang) == ~w(u5 u1 u2 u3 u4)
    end

    test "versetzen schliesst die alte Stelle", %{k: k} do
      drei = Kette.glied_von(k, "u3").id
      {:ok, k} = Kette.versetzen(k, drei, :anfang)

      # u2 und u4 sind jetzt Nachbarn — keine Lücke, kein Duplikat.
      assert folge(k) == ~w(u3 u1 u2 u4 u5)
      assert length(folge(k)) == 5
    end

    test "löschen schliesst die Lücke", %{k: k} do
      drei = Kette.glied_von(k, "u3").id
      {:ok, k} = Kette.loeschen(k, drei)

      assert folge(k) == ~w(u1 u2 u4 u5)
    end

    test "gelöscht ist nicht draussen — die Äußerung ist wieder offen", %{k: k} do
      # Herausnehmen ist kein Urteil über den Inhalt. Wer ein Glied falsch
      # geschnitten hat, soll es neu schneiden können, ohne dass die Zeilen
      # dabei als Tischgespräch gelten.
      drei = Kette.glied_von(k, "u3").id
      {:ok, k} = Kette.loeschen(k, drei)

      assert "u3" in Kette.offen(k, utts(5))
      refute Map.has_key?(k.draussen, "u3")
    end

    test "draussen nimmt aus der Kette heraus", %{k: k} do
      {:ok, k} = Kette.draussen(k, ["u2", "u3"], "Regelfrage")

      assert folge(k) == ~w(u1 u4 u5)
      assert k.draussen["u2"] == "Regelfrage"
    end
  end

  describe "ein Glied an ein anderes hängen" do
    setup do
      k = Kette.neu() |> mit([["u1"], ["u2", "u3"], ["u4"], ["u5"]])
      %{k: k, zwei: Kette.glied_von(k, "u2").id}
    end

    test "das Zielglied wächst und BLEIBT, wo es ist", %{k: k, zwei: zwei} do
      # Maintainer, 20.09.2026: „wenn man ein glied aus der kette nimmt und
      # nicht wieder in die kette hängt, sondern an ein glied hängt?"
      {:ok, k, g} = Kette.erweitern(k, zwei, ["u5"])

      assert g.utts == ["u2", "u3", "u5"]
      assert folge(k) == ~w(u1 u2 u3 u5 u4)
      assert length(k.glieder) == 3, "u5 hat sein altes Glied verlassen, es fällt weg"
    end

    test "über anhaengen landet dieselbe Menge am ENDE — das ist der Unterschied", %{
      k: k,
      zwei: _zwei
    } do
      {:ok, a, _} = Kette.anhaengen(k, ["u2", "u3", "u5"])

      assert folge(a) == ~w(u1 u4 u2 u3 u5)
    end

    test "erweitern nimmt auch aus draussen zurück", %{k: k, zwei: zwei} do
      {:ok, k} = Kette.draussen(k, ["u9"], "erst für Tisch gehalten")
      {:ok, k, _} = Kette.erweitern(k, zwei, ["u9"])

      refute Map.has_key?(k.draussen, "u9")
      assert "u9" in folge(k)
    end

    test "ein Glied, das es nicht gibt", %{k: k} do
      assert {:fehler, t} = Kette.erweitern(k, "g_erfunden", ["u9"])
      assert t =~ "g_erfunden"
    end
  end

  describe "die Elemente eines Gliedes sind selbst eine Kette" do
    # Maintainer, 20.09.2026: „und elemente an einem glied sind auch eine
    # kette." Dieselbe Sprache auf beiden Ebenen — `vor:`/`nach:` zeigen
    # innerhalb eines Gliedes auf eine Äußerung statt auf ein Glied.
    setup do
      k = Kette.neu() |> mit([["u10", "u11", "u12"], ["u20"]])
      %{k: k, g: Kette.glied_von(k, "u10").id}
    end

    test "ohne Angabe hinten an", %{k: k, g: g} do
      {:ok, _k, neu} = Kette.erweitern(k, g, ["u13"])
      assert neu.utts == ~w(u10 u11 u12 u13)
    end

    test "an den Anfang des Gliedes", %{k: k, g: g} do
      {:ok, _k, neu} = Kette.erweitern(k, g, ["u9"], anfang: true)
      assert neu.utts == ~w(u9 u10 u11 u12)
    end

    test "vor und nach einer Äußerung DES GLIEDES", %{k: k, g: g} do
      # Der reale Fall: Eine Szene wird in zwei Anläufen erkannt, und die
      # nachgereichte Zeile gehört mittenhinein, nicht ans Ende.
      {:ok, _k, vor} = Kette.erweitern(k, g, ["u99"], vor: "u11")
      assert vor.utts == ~w(u10 u99 u11 u12)

      {:ok, _k, nach} = Kette.erweitern(k, g, ["u99"], nach: "u11")
      assert nach.utts == ~w(u10 u11 u99 u12)
    end

    test "ein Ziel ausserhalb des Gliedes hängt an, statt die Äußerung zu verlieren", %{
      k: k,
      g: g
    } do
      {:ok, _k, neu} = Kette.erweitern(k, g, ["u99"], vor: "u20")
      assert neu.utts == ~w(u10 u11 u12 u99)
    end

    test "eine Äußerung, die schon im Glied liegt, wandert nicht", %{k: k, g: g} do
      {:ok, _k, neu} = Kette.erweitern(k, g, ["u12"], anfang: true)
      assert neu.utts == ~w(u10 u11 u12)
    end
  end

  describe "die Invariante: jede eingereihte Äußerung steht GENAU EINMAL in der Kette" do
    # Die Länge allein genügt als Prüfung nicht (Maintainer, 20.09.2026):
    # Eine Operation könnte eine Äußerung doppeln und eine andere verlieren,
    # und die Zahl bliebe gleich. Geprüft wird deshalb die Menge.
    defp unversehrt!(k, alle) do
      f = folge(k)
      assert f == Enum.uniq(f), "eine Äußerung steht doppelt in der Kette: #{inspect(f)}"

      drin = MapSet.new(f)
      raus = MapSet.new(Map.keys(k.draussen))
      offen = MapSet.new(Kette.offen(k, alle))

      assert MapSet.disjoint?(drin, raus), "eine Äußerung ist zugleich drin und draussen"
      assert MapSet.disjoint?(drin, offen), "eine eingereihte Äußerung gilt als offen"

      assert MapSet.union(drin, MapSet.union(raus, offen)) == MapSet.new(alle),
             "jede Äußerung ist genau einmal: eingereiht, draussen oder offen"

      k
    end

    test "nach jeder einzelnen Operation" do
      alle = utts(8)

      k =
        Kette.neu()
        |> unversehrt!(alle)
        |> mit([["u1", "u2"], ["u3"], ["u4", "u5"]])
        |> unversehrt!(alle)

      drei = Kette.glied_von(k, "u3").id
      eins = Kette.glied_von(k, "u1").id

      {:ok, k, _} = Kette.erweitern(k, drei, ["u6"])
      k = unversehrt!(k, alle)

      {:ok, k} = Kette.versetzen(k, Kette.glied_von(k, "u3").id, {:vor, eins})
      k = unversehrt!(k, alle)

      {:ok, k} = Kette.draussen(k, ["u7", "u2"], "Tisch")
      k = unversehrt!(k, alle)

      {:ok, k} = Kette.loeschen(k, Kette.glied_von(k, "u4").id)
      k = unversehrt!(k, alle)

      {:ok, k, _} = Kette.anhaengen(k, ["u8", "u4"], anfang: true)
      unversehrt!(k, alle)
    end

    test "auch wenn Glieder sich überlappend neu bilden" do
      alle = utts(6)

      k =
        Kette.neu()
        |> mit([["u1", "u2", "u3"], ["u4", "u5", "u6"]])
        |> unversehrt!(alle)

      # Ein Glied quer über die Grenze der beiden bestehenden.
      {:ok, k, _} = Kette.anhaengen(k, ["u3", "u4"])
      unversehrt!(k, alle)
    end
  end

  describe "Ablehnungen nennen den Grund" do
    setup do
      %{k: Kette.neu() |> mit([["u1"], ["u2"]])}
    end

    test "ein Glied, das es nicht gibt", %{k: k} do
      assert {:fehler, t} = Kette.versetzen(k, "g_erfunden", :anfang)
      assert t =~ "g_erfunden"
      assert {:fehler, t2} = Kette.loeschen(k, "g_erfunden")
      assert t2 =~ "g_erfunden"
    end

    test "ein Ziel, das es nicht gibt", %{k: k} do
      eins = Kette.glied_von(k, "u1").id
      assert {:fehler, t} = Kette.versetzen(k, eins, {:vor, "g_erfunden"})
      assert t =~ "Zielglied"
    end

    test "ein Glied kann nicht vor sich selbst stehen", %{k: k} do
      eins = Kette.glied_von(k, "u1").id
      assert {:fehler, t} = Kette.versetzen(k, eins, {:nach, eins})
      assert t =~ "vor oder hinter sich selbst"
    end
  end

  describe "die Kennung" do
    test "ist content-adressiert: dieselben Äußerungen, dieselbe Kennung" do
      {:ok, _, a} = Kette.anhaengen(Kette.neu(), ["u2", "u1"])
      {:ok, _, b} = Kette.anhaengen(Kette.neu(), ["u1", "u2"])

      assert a.id == b.id
      assert String.starts_with?(a.id, "g_")
    end

    test "verschiedene Äußerungen, verschiedene Kennung" do
      {:ok, _, a} = Kette.anhaengen(Kette.neu(), ["u1"])
      {:ok, _, b} = Kette.anhaengen(Kette.neu(), ["u1", "u2"])

      refute a.id == b.id
    end
  end
end
