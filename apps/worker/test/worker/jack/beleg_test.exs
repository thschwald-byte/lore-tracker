defmodule Worker.Jack.BelegTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.Beleg

  @bloecke %{
    0 => %{text: "Der Monitor   piept LAUT, und Kodex flucht."},
    1 => %{text: "Ich trinke den Kaffee aus und gehe zur Tür."},
    2 => %{text: ""}
  }

  test "norm faltet Leerraum und schreibt klein" do
    assert Beleg.norm("  Der  Monitor\n PIEPT ") == "der monitor piept"
  end

  describe "stuecke/1" do
    test "zerlegt an „…“ und verwirft Stücke unter acht Zeichen" do
      assert [%{roh: "Der Monitor piept"}, %{roh: "Kaffee aus und gehe"}] =
               Beleg.stuecke("Der Monitor piept … kurz … Kaffee aus und gehe")
    end

    test "ist alles kurz, zählt der ganze Beleg" do
      assert [%{roh: "Ja.", n: "ja."}] = Beleg.stuecke("Ja.")
      assert Beleg.stuecke("   ") == []
    end
  end

  test "trifft vergleicht normalisiert und nur in den genannten Blöcken" do
    assert Beleg.trifft("monitor piept laut", [0, 1], @bloecke) == [0]
    assert Beleg.trifft("monitor piept laut", [1, 2], @bloecke) == []
  end

  describe "pruefen/3" do
    test "trägt, wenn jedes Stück steht und jeder Block zitiert ist" do
      assert %{ok: true, teile: 2} =
               Beleg.pruefen("Der Monitor piept laut … trinke den Kaffee aus", [0, 1], @bloecke)
    end

    test "meldet Stücke ohne Treffer im Wortlaut des Agenten, gekürzt auf 60 Zeichen" do
      assert %{ok: false, ohne_treffer: ["Die Tür ist VERSCHLOSSEN"], refs_ohne_zitat: [0]} =
               Beleg.pruefen("Die Tür ist VERSCHLOSSEN", [0], @bloecke)
    end

    test "ein genannter Block ohne Zitat ist ein Fehler — source_refs sind keine Dekoration" do
      assert %{ok: false, ohne_treffer: [], refs_ohne_zitat: [1]} =
               Beleg.pruefen("Der Monitor piept laut", [0, 1], @bloecke)
    end
  end

  describe "nur_fragen?/1 — entschärfte Frageprüfung" do
    test "ein Beleg aus lauter Fragen" do
      assert Beleg.nur_fragen?("Kommt der Wagen heute noch?")
      assert Beleg.nur_fragen?("Kommt er? Und wann?")
      assert Beleg.nur_fragen?("Do we tell?")
    end

    test "steht eine Aussage daneben, trägt der Beleg" do
      refute Beleg.nur_fragen?("Kommt der Wagen heute noch? Er kommt um acht.")
      refute Beleg.nur_fragen?("Er kam an … richtig?")
      refute Beleg.nur_fragen?("Der Wagen kommt.")
      refute Beleg.nur_fragen?("")
    end
  end

  describe "fehler/3" do
    test "nil, wenn der Beleg trägt" do
      assert Beleg.fehler("Der Monitor piept laut", [0], @bloecke) == nil
    end

    test "eine reine Frage wird abgelehnt, bevor der Text geprüft wird" do
      assert [text] = Beleg.fehler("Piept der Monitor?", [0], @bloecke)
      assert text =~ "Der Beleg ist eine Frage."
    end

    test "beide Befunde mit ihren Texten" do
      assert [ohne, refs] = Beleg.fehler("Die Tür ist verschlossen", [0], @bloecke)

      assert ohne ==
               ~s(Diese Belegstücke stehen in keinem der genannten Blöcke: ["Die Tür ist verschlossen"])

      assert refs =~ "Zu diesen source_refs fehlt ein Zitat: [0]."
    end
  end

  describe "rueckbezug/2" do
    test "ein Rückbezugswort bei nur einem Block" do
      assert Beleg.rueckbezug("Kodex flucht wieder.", [0]) == "wieder"
      assert Beleg.rueckbezug("Kodex flucht.", [0]) == nil
    end

    test "bei mehreren Blöcken kein Hinweis" do
      assert Beleg.rueckbezug("Kodex flucht wieder.", [0, 1]) == nil
    end
  end

  test "woerter: nur Wörter mit mehr als drei Zeichen, Umlaute zählen" do
    assert Beleg.woerter("Der Hund läuft über die Brücke, 2080!") ==
             MapSet.new(["hund", "läuft", "über", "brücke", "2080"])
  end

  test "pos_von: die früheste Fundstelle, sonst -1" do
    assert Beleg.pos_von([12, 3, 7]) == 3
    assert Beleg.pos_von([]) == -1
    assert Beleg.pos_von(nil) == -1
  end
end
