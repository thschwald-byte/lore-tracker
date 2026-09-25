defmodule Worker.Jack.Zeit.EinordnungAusKetteTest do
  @moduledoc """
  #1247: **die Einordnung kommt aus der geladenen Kette** — sonst ist die
  Persistenz halb.

  Maintainer, 25.09.2026: „ich will den ersten Lauf nicht noch mal machen
  müssen, bevor wir den Lauf mit Kette testen." Genau das wäre nötig gewesen:
  Die Glieder überlebten in der Datenbank, die Einordnung nicht. Ein zweiter
  Lauf startete mit vollständiger Kette und leerer `einordnung` — und weil
  `ohne_einordnung/1` genau die prüft, verlangte `fertig()` eine Entscheidung
  für jede der 2168 Zeilen, die längst in einem Glied liegen. Eine Stunde
  Arbeit, um zu einem Zustand zurückzukehren, der schon da war.

  Abgeleitet, nicht erfunden: Eine Zeile in einem Glied ist `:ingame`, eine in
  `draussen` ist `:tisch`. Beides steht in der Kette.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Zeit.Stand
  alias Worker.Timeline.Kette

  defp zeile(nr),
    do: %{
      nr: nr,
      utterance_id: "u#{nr}",
      sprecher: "SL",
      text: "Zeile #{nr}",
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp mitschnitt, do: Enum.map(1..6, &zeile/1)

  # Ein Bestand, wie ihn ein erster Lauf hinterlässt: zwei Glieder (eines mit
  # Unterglied), eine gelöste Zeile — und zwei Zeilen, die niemand angefasst
  # hat.
  defp bestand do
    {:ok, k, a} = Kette.anhaengen(Kette.neu(), ["u1"], grund: "die Anreise")
    {:ok, k, _} = Kette.unterhaengen(k, a.id, ["u2"], grund: "der Aufbruch")
    {:ok, k, _} = Kette.anhaengen(k, ["u3"], grund: "der Überfall")
    {:ok, k} = Kette.draussen(k, ["u6"], "Tischgespräch")
    k
  end

  describe "ein Lauf mit Bestand" do
    test "sieht die Zeilen der Kette als eingeordnet" do
      s = Stand.neu(:einsortieren, mitschnitt(), kette: bestand())

      assert Stand.ohne_einordnung(s).anzahl == 2, "nur u4 und u5 sind wirklich offen"
      assert Stand.ohne_einordnung(s).zeilen |> Enum.map(& &1.utterance_id) == ~w(u4 u5)
    end

    test "und unterscheidet Glied von draussen" do
      s = Stand.neu(:einsortieren, mitschnitt(), kette: bestand())

      assert s.einordnung["u1"] == :ingame
      assert s.einordnung["u2"] == :ingame, "auch ein Unterglied zählt"
      assert s.einordnung["u6"] == :tisch
      refute Map.has_key?(s.einordnung, "u4")
    end

    test "offene_zeilen und ohne_einordnung sagen dasselbe" do
      # Beide sind Teil der Abschlussbedingung. Liefen sie auseinander, wäre
      # `fertig()` entweder unerreichbar oder zu leicht.
      s = Stand.neu(:einsortieren, mitschnitt(), kette: bestand())
      assert Stand.offene_zeilen(s).anzahl == Stand.ohne_einordnung(s).anzahl
    end
  end

  describe "die Grenzen der Ableitung" do
    test "ohne Kette ist nichts eingeordnet — für eine frische Kampagne richtig" do
      s = Stand.neu(:einsortieren, mitschnitt())
      assert Stand.ohne_einordnung(s).anzahl == 6
      assert s.einordnung == %{}
    end

    test "ein ausdrücklich übergebenes einordnung gewinnt" do
      # Der Prüf-Lauf erbt sie samt Zweifeln, und `:zweifel` ist aus der Kette
      # allein NICHT ableitbar: Eine unklare Zeile liegt darin wie eine
      # sichere. Würde die Ableitung das Erbe überschreiben, verlöre der
      # Prüf-Lauf jeden Zweifel des Einsortier-Laufs.
      geerbt = %{"u1" => :zweifel}
      s = Stand.neu(:pruefen, mitschnitt(), kette: bestand(), einordnung: geerbt)

      assert s.einordnung == geerbt
    end

    test "eine Zeile, die nicht im Mitschnitt steht, stört nicht" do
      # Die Kette der KAMPAGNE trägt auch Glieder anderer Sitzungen; ihre
      # Äußerungen kommen im Mitschnitt dieser Sitzung nicht vor.
      {:ok, fremd, _} = Kette.anhaengen(bestand(), ["v1", "v2"], grund: "andere Sitzung")
      s = Stand.neu(:einsortieren, mitschnitt(), kette: fremd)

      assert Stand.ohne_einordnung(s).anzahl == 2, "die fremden Zeilen ändern nichts"
      assert s.einordnung["v1"] == :ingame
    end
  end
end
