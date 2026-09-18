defmodule Worker.Jack.Chronik.LesenTest do
  @moduledoc """
  Issue #1211: was Jack sieht, wenn er die Chronik liest. Der Text ist kein
  Beiwerk — er ist die Grundlage der Verfeinerung, und die ist der
  Normalbetrieb.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Lesen
  alias Worker.Jack.Resuemee.Stand

  defp e(id, titel, opts \\ []) do
    %{
      id: id,
      titel: titel,
      text: Keyword.get(opts, :text, "Was geschah."),
      fakt_ids: Keyword.get(opts, :fakt_ids, ["f1"]),
      wichtigkeit: Keyword.get(opts, :wichtigkeit, "phase"),
      zeit_bezug: Keyword.get(opts, :bezug, %{"art" => "isoliert"}),
      kuratiert?: Keyword.get(opts, :kuratiert?, false),
      kuratierter_text: nil,
      neu?: true
    }
  end

  defp stand(eintraege), do: %Stand{art: :chronik, eintraege: eintraege}

  test "die leere Chronik sagt, was zu tun ist" do
    t = Lesen.text(stand([]))
    assert t =~ "leer"
    assert t =~ "EIN Eintrag"
  end

  test "die Einträge stehen in der gerechneten Reihenfolge" do
    a = e("chr-a", "Der Auftrag")
    b = e("chr-b", "Die Anfahrt", bezug: %{"art" => "nach", "ziel" => "chr-a"})

    t = Lesen.text(stand([b, a]))
    assert String.match?(t, ~r/Der Auftrag.*Die Anfahrt/s)
  end

  test "Gleichzeitiges steht nebeneinander und ist als solches benannt" do
    a = e("chr-a", "Belagerung")
    b = e("chr-b", "Seuche", bezug: %{"art" => "gleichzeitig_mit", "ziel" => "chr-a"})

    t = Lesen.text(stand([a, b]))
    assert t =~ "gleichzeitig"
  end

  test "ein kuratierter Eintrag ist als solcher markiert — mit dem Verbot" do
    t = Lesen.text(stand([e("chr-k", "Vom Spielleiter", kuratiert?: true)]))
    assert t =~ "KURATIERT"
    assert t =~ "nicht streichen"
  end

  test "ein Widerspruch wird gemeldet, samt Weg nach vorn" do
    a = e("chr-a", "A", bezug: %{"art" => "nach", "ziel" => "chr-b"})
    b = e("chr-b", "B", bezug: %{"art" => "nach", "ziel" => "chr-a"})

    t = Lesen.text(stand([a, b]))
    assert t =~ "Widerspruch"
    assert t =~ "chr-a"
    assert t =~ "eintrag_einordnen"
    # Trotz Widerspruch sind die Einträge sichtbar — sonst könnte Jack ihn
    # nicht auflösen.
    assert t =~ "A"
    assert t =~ "B"
  end

  test "ein Bezug ins Leere wird benannt, nicht verschwiegen" do
    a = e("chr-a", "A", bezug: %{"art" => "nach", "ziel" => "weg"})
    t = Lesen.text(stand([a]))
    assert t =~ "gibt"
    assert t =~ "chr-a"
  end

  test "langer Text wird gekürzt — die Übersicht ist der Zweck" do
    lang = String.duplicate("x", 400)
    t = Lesen.text(stand([e("chr-a", "A", text: lang)]))
    assert t =~ "…"
    refute t =~ String.duplicate("x", 400)
  end

  describe "rangfolge/1 — für den Einbau" do
    test "liefert die IDs flach in der Reihenfolge" do
      a = e("chr-a", "A")
      b = e("chr-b", "B", bezug: %{"art" => "nach", "ziel" => "chr-a"})

      assert {:ok, ["chr-a", "chr-b"]} = Lesen.rangfolge([b, a])
    end

    test "meldet den Kreis weiter" do
      a = e("chr-a", "A", bezug: %{"art" => "nach", "ziel" => "chr-b"})
      b = e("chr-b", "B", bezug: %{"art" => "nach", "ziel" => "chr-a"})

      assert {:zyklus, ["chr-a", "chr-b"]} = Lesen.rangfolge([a, b])
    end
  end

  describe "offen() — die fehlenden Geschehen mit Aussage (18.09.2026)" do
    # Am ersten echten Lauf gesehen: Jack zählte sich durch die Faktenliste,
    # um zu finden, was ihm fehlt. Eine Liste von IDs allein hätte ihn
    # gezwungen, jede einzeln nachzuschlagen.
    defp fakt_voll(id, aussage, typ \\ "ereignis"),
      do: %{id: id, fakt_id: "echt-" <> id, typ: typ, aussage: aussage}

    defp schreib_stand(fakten, eintraege) do
      %Stand{
        art: :chronik,
        lauf: :schreiben,
        fakten: fakten,
        eintraege: eintraege,
        chronik: [],
        notizen: []
      }
    end

    test "nennt die offenen Geschehen mit ihrer Aussage" do
      s =
        schreib_stand(
          [
            fakt_voll("f1", "Die Gruppe trifft Romeo im Club"),
            fakt_voll("f2", "Kodex holt seine Ausrüstung ab"),
            fakt_voll("welt", "Seattle ist ein Stadtstaat", "zustand")
          ],
          [e("chr-a", "Auftrag", fakt_ids: ["echt-f1"])]
        )

      text = Lesen.offen_text(s)

      assert text =~ "1 Geschehen"
      assert text =~ "f2"
      assert text =~ "Kodex holt seine Ausrüstung ab"
      refute text =~ "f1 "
      refute text =~ "Stadtstaat", "Zustände gehören nicht in den Zeitstrahl"
    end

    test "ist nichts offen, sagt es das und nennt fertig()" do
      s =
        schreib_stand([fakt_voll("f1", "Etwas geschieht")], [
          e("chr-a", "Auftrag", fakt_ids: ["echt-f1"])
        ])

      assert Lesen.offen_text(s) =~ "fertig() rufen"
    end

    test "im Überblick zählen die Gruppen der Notizen, nicht die Einträge" do
      s = %{
        schreib_stand([fakt_voll("f1", "Etwas geschieht")], [])
        | lauf: :ueberblick,
          notizen: [
            %{abschnitt: "PHASEN", schluessel: "a", zeile: "z", fakten: ["f1"], boegen: []}
          ]
      }

      text = Lesen.offen_text(s)
      assert text =~ "in einer Gruppe"
      assert text =~ "fertig() rufen"
    end
  end
end
