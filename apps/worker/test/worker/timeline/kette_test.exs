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

  describe "die Kennung ist eine UUID und überlebt jede Änderung" do
    # Maintainer, 20.09.2026: „Glied braucht uuid — und ein glied an einem
    # glied auch, zwingend." Der erste Wurf war content-adressiert; dann
    # ändert sich die Kennung, sobald eine Szene wächst, und jeder Bezug
    # darauf zeigt ins Leere.
    test "erweitern behält die Kennung — die Szene ist dieselbe, nur grösser" do
      k = Kette.neu() |> mit([["u1", "u2"], ["u3"]])
      vorher = Kette.glied_von(k, "u1").id

      {:ok, k, g} = Kette.erweitern(k, vorher, ["u9"])

      assert g.id == vorher, "ein Bezug auf dieses Glied muss gültig bleiben"
      assert Kette.glied(k, vorher).utts == ["u1", "u2", "u9"]
    end

    test "zwei Glieder mit denselben Äußerungen sind trotzdem verschieden" do
      # Die Kehrseite: Eine UUID konvergiert nicht. Zwei Worker, die dasselbe
      # Glied bilden, vergeben verschiedene — hinnehmbar, weil ein Glied in
      # EINEM Lauf entsteht und dieser Lauf sein Autor ist.
      {:ok, _, a} = Kette.anhaengen(Kette.neu(), ["u1", "u2"])
      {:ok, _, b} = Kette.anhaengen(Kette.neu(), ["u1", "u2"])

      refute a.id == b.id
      assert String.starts_with?(a.id, "g_")
    end

    test "gefunden wird ein Glied über seine Äußerungen" do
      # Maintainer: „jeder bezug in der anwendung sollte auf eine utt
      # zurückführen." Die Kennung ist die Identität, die Utterance der Weg.
      k = Kette.neu() |> mit([["u1", "u2"], ["u3"]])

      assert Kette.glied_von(k, "u2").id == Kette.glied_von(k, "u1").id
      refute Kette.glied_von(k, "u3").id == Kette.glied_von(k, "u1").id
      assert Kette.glied_von(k, "u99") == nil
    end
  end

  describe "Bäume auf dem Zeitstrahl" do
    # Maintainer, 20.09.2026: „es gibt die ebene der kette (der zeitstrahl) —
    # in die kette werden glieder eingehangen — jedem glied kann ein oder
    # mehrere glieder angehangen werden … wie bäume die auf dem zeitstrahl
    # stehen." Und: „ein glied hängt entweder am zeitstrahl oder an einem
    # glied."
    setup do
      k = Kette.neu() |> mit([["u1"], ["u2"], ["u3"]])
      %{k: k, zwei: Kette.glied_von(k, "u2").id}
    end

    test "ein Unterglied steht IN seinem Elternglied, nicht daneben", %{k: k, zwei: zwei} do
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20"], grund: "der Hinterhalt")

      assert length(k.glieder) == 3, "der Zeitstrahl hat kein viertes Wurzelglied bekommen"
      assert Kette.glied(k, zwei).kinder |> Enum.map(& &1.id) == [kind.id]
      assert folge(k) == ~w(u1 u2 u20 u3)
    end

    test "jedes Glied hat eine eigene Kennung, auf jeder Tiefe", %{k: k, zwei: zwei} do
      # Maintainer: „jedes element in der kette ist ein glied — egal in
      # welcher tiefe — jedes glied hat eine uuid."
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20"])
      {:ok, k, enkel} = Kette.unterhaengen(k, kind.id, ["u30"])

      ids = Kette.flach(k) |> Enum.map(fn {g, _} -> g.id end)

      assert length(ids) == 5
      assert ids == Enum.uniq(ids)
      assert Enum.all?(ids, &String.starts_with?(&1, "g_"))
      assert Kette.glied(k, enkel.id).utts == ["u30"]
      assert Kette.anzahl(k) == 5
    end

    test "gefunden wird ein Unterglied über seine Äußerung, wie jedes andere", %{
      k: k,
      zwei: zwei
    } do
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20", "u21"])

      assert Kette.glied_von(k, "u21").id == kind.id
    end

    test "die Glieder an einem Glied sind wieder eine Kette", %{k: k, zwei: zwei} do
      # Maintainer, 20.09.2026: „die glieder die an einem glied hängen sind
      # wieder eine kette." Dieselben Wörter, dieselbe Ordnung, eine Ebene
      # tiefer — `vor`/`nach`/`anfang` beim Einhängen wie beim Versetzen.
      {:ok, k, a} = Kette.unterhaengen(k, zwei, ["ua"])
      {:ok, k, b} = Kette.unterhaengen(k, zwei, ["ub"])
      {:ok, k, c} = Kette.unterhaengen(k, zwei, ["uc"], vor: b.id)

      assert folge(k) == ~w(u1 u2 ua uc ub u3)

      {:ok, k} = Kette.versetzen(k, c.id, {:nach, b.id})
      assert folge(k) == ~w(u1 u2 ua ub uc u3)

      {:ok, k} = Kette.versetzen(k, c.id, :anfang)
      assert folge(k) == ~w(u1 u2 uc ua ub u3)

      {:ok, k} = Kette.loeschen(k, a.id)
      assert folge(k) == ~w(u1 u2 uc ub u3)
      assert "ua" in Kette.offen(k, ~w(u1 u2 u3 ua ub uc))
    end

    test "ein Glied bewegt sich unter seinen Geschwistern, nicht aus dem Kontext heraus", %{
      k: k,
      zwei: zwei
    } do
      # „ein glied hängt entweder am zeitstrahl oder an einem glied" — wer
      # eine Szene aus ihrem Zusammenhang lösen will, nimmt sie heraus und
      # hängt sie neu ein. Das ist eine bewusste Handlung.
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20"])
      eins = Kette.glied_von(k, "u1").id

      assert {:fehler, t} = Kette.versetzen(k, kind.id, {:nach, eins})
      assert t =~ "derselben Ebene"

      assert {:fehler, t2} = Kette.versetzen(k, zwei, {:vor, kind.id})
      assert t2 =~ "derselben Ebene"
    end

    test "löschen nimmt den ganzen Unterbaum mit — und alles wird wieder offen", %{
      k: k,
      zwei: zwei
    } do
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20"])
      {:ok, k, _} = Kette.unterhaengen(k, kind.id, ["u30"])

      {:ok, k} = Kette.loeschen(k, zwei)

      assert folge(k) == ~w(u1 u3)
      assert Kette.offen(k, ~w(u1 u2 u3 u20 u30)) == ~w(u2 u20 u30)
      assert k.draussen == %{}
    end

    test "eine Äußerung liegt in höchstens einem Glied — auch über Tiefen hinweg", %{
      k: k,
      zwei: zwei
    } do
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20", "u21"])
      {:ok, k, _} = Kette.anhaengen(k, ["u21"])

      assert Kette.glied(k, kind.id).utts == ["u20"]
      assert folge(k) == ~w(u1 u2 u20 u3 u21)
    end

    test "ein Unterglied an einem Glied, das es nicht gibt", %{k: k} do
      assert {:fehler, t} = Kette.unterhaengen(k, "g_erfunden", ["u9"])
      assert t =~ "g_erfunden"
    end

    test "erst die eigenen Äußerungen, dann die Unterglieder", %{k: k, zwei: zwei} do
      # Eine Festlegung, keine Ableitung: ohne sie wäre die Folge der Blätter
      # nicht bestimmt. Wer eine andere Ordnung braucht, bildet Unterglieder.
      {:ok, k, _} = Kette.erweitern(k, zwei, ["u2b"])
      {:ok, k, _} = Kette.unterhaengen(k, zwei, ["u20"])

      assert folge(k) == ~w(u1 u2 u2b u20 u3)
    end

    test "die Invariante gilt auch im Baum", %{k: k, zwei: zwei} do
      alle = ~w(u1 u2 u3 u20 u21 u30 u40)

      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20", "u21"])
      k = unversehrt!(k, alle)

      {:ok, k, _} = Kette.unterhaengen(k, kind.id, ["u30"])
      k = unversehrt!(k, alle)

      {:ok, k} = Kette.draussen(k, ["u21", "u40"], "Tisch")
      k = unversehrt!(k, alle)

      {:ok, k, _} = Kette.erweitern(k, kind.id, ["u40"])
      k = unversehrt!(k, alle)

      {:ok, k} = Kette.loeschen(k, kind.id)
      unversehrt!(k, alle)
    end
  end

  describe "die Kette als Zeilen — und zurück" do
    # Maintainer, 20.09.2026: der Platz steht als Bezug auf die Kennung des
    # Nachbarn (`vorher`) und des Elterngliedes (`eltern`). Die Rundreise ist
    # die eigentliche Zusage: was gespeichert wird, muss vollständig
    # zurückkommen — sonst verliert jeder Lauf still einen Teil der Arbeit.
    defp rundreise(k) do
      {zurueck, befunde} = k |> Kette.zu_zeilen() |> Kette.aus_zeilen()
      assert befunde == [], "eine saubere Kette darf keine Befunde erzeugen"
      zurueck
    end

    test "ein flacher Zeitstrahl kommt unverändert zurück" do
      k = Kette.neu() |> mit([["u1", "u2"], ["u3"], ["u4"]])

      assert rundreise(k) == k
    end

    test "ein Baum kommt mit allen Tiefen zurück" do
      k = Kette.neu() |> mit([["u1"], ["u2"]])
      zwei = Kette.glied_von(k, "u2").id
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20"], grund: "der Hinterhalt")
      {:ok, k, _} = Kette.unterhaengen(k, kind.id, ["u30"])
      {:ok, k, _} = Kette.unterhaengen(k, zwei, ["u40"], grund: "die Flucht")

      zurueck = rundreise(k)

      assert zurueck == k
      assert Kette.anzahl(zurueck) == 5
      assert Kette.reihenfolge(zurueck) == ~w(u1 u2 u20 u30 u40)
      assert Kette.glied(zurueck, kind.id).grund == "der Hinterhalt"
    end

    test "das Gelöste reist mit — sonst verfällt eine Entscheidung zu „noch offen“" do
      k = Kette.neu() |> mit([["u1"]])
      {:ok, k} = Kette.draussen(k, ["u8", "u9"], "Tischgespräch")

      zurueck = rundreise(k)

      assert zurueck.draussen == %{"u8" => "Tischgespräch", "u9" => "Tischgespräch"}
      assert Kette.offen(zurueck, ~w(u1 u8 u9)) == []
    end

    test "jede Zeile nennt ihren Platz über die Kennung des Nachbarn" do
      k = Kette.neu() |> mit([["u1"], ["u2"]])
      zwei = Kette.glied_von(k, "u2").id
      eins = Kette.glied_von(k, "u1").id
      {:ok, k, kind} = Kette.unterhaengen(k, zwei, ["u20"])

      zeilen = Kette.zu_zeilen(k) |> Map.new(&{&1["glied_id"], &1})

      assert zeilen[eins]["vorher"] == nil
      assert zeilen[eins]["eltern"] == nil
      assert zeilen[zwei]["vorher"] == eins
      assert zeilen[kind.id]["eltern"] == zwei
      assert zeilen[kind.id]["vorher"] == nil, "das erste Kind hat keinen linken Nachbarn"
    end

    test "die Zeilen überstehen JSON — sie werden so gespeichert" do
      k = Kette.neu() |> mit([["u1", "u2"], ["u3"]])
      {:ok, k} = Kette.draussen(k, ["u9"], "Regelfrage")
      eins = Kette.glied_von(k, "u1").id
      {:ok, k, _} = Kette.unterhaengen(k, eins, ["u5"], grund: "Teil davon")

      {zurueck, []} =
        k |> Kette.zu_zeilen() |> Jason.encode!() |> Jason.decode!() |> Kette.aus_zeilen()

      assert zurueck == k
    end
  end

  describe "ein gerissener Bezug verliert nichts — er wird gemeldet" do
    # Der Preis der Kennung als Bezug (Maintainer-Entscheidung, 20.09.2026):
    # Sie konvergiert nicht, und wer ein Glied entfernt, muss die Zeile
    # seines rechten Nachbarn nachziehen. Geht das schief, darf die Kette
    # nicht schweigend Glieder verlieren.
    test "ein vorher, das es nicht gibt, hängt das Glied hinten an" do
      zeilen = [
        %{
          "glied_id" => "g_a",
          "art" => "glied",
          "utts" => ["u1"],
          "vorher" => nil,
          "eltern" => nil
        },
        %{
          "glied_id" => "g_b",
          "art" => "glied",
          "utts" => ["u2"],
          "vorher" => "g_weg",
          "eltern" => nil
        }
      ]

      {k, befunde} = Kette.aus_zeilen(zeilen)

      assert Kette.reihenfolge(k) == ~w(u1 u2)
      assert [text] = befunde
      assert text =~ "nicht aufgeht"
    end

    test "ein Ring von Bezügen endet, statt sich zu drehen" do
      zeilen = [
        %{
          "glied_id" => "g_a",
          "art" => "glied",
          "utts" => ["u1"],
          "vorher" => "g_b",
          "eltern" => nil
        },
        %{
          "glied_id" => "g_b",
          "art" => "glied",
          "utts" => ["u2"],
          "vorher" => "g_a",
          "eltern" => nil
        }
      ]

      {k, befunde} = Kette.aus_zeilen(zeilen)

      assert Kette.anzahl(k) == 2, "kein Glied geht verloren"
      assert length(Kette.reihenfolge(k)) == 2
      assert befunde != []
    end

    test "ein Elternglied, das es nicht gibt, stellt das Kind auf den Zeitstrahl" do
      zeilen = [
        %{
          "glied_id" => "g_a",
          "art" => "glied",
          "utts" => ["u1"],
          "vorher" => nil,
          "eltern" => nil
        },
        %{
          "glied_id" => "g_k",
          "art" => "glied",
          "utts" => ["u2"],
          "vorher" => nil,
          "eltern" => "g_weg"
        }
      ]

      {k, befunde} = Kette.aus_zeilen(zeilen)

      assert Kette.anzahl(k) == 2, "der Unterbaum verschwindet nicht mit seinem Elternteil"
      assert Enum.any?(befunde, &(&1 =~ "g_weg"))
    end

    test "aus leeren Zeilen wird eine leere Kette, kein Absturz" do
      assert {%{glieder: [], draussen: %{}}, []} = Kette.aus_zeilen([])
    end
  end
end
