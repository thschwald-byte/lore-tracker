defmodule Worker.Jack.FortsetzungTest do
  use ExUnit.Case, async: true

  alias Worker.Jack.{Abbild, Fortsetzung, Stand}

  @bloecke for i <- 0..20, do: %{text: "Satz #{i}.", sprecher: "X"}

  defp abgelegter_stand do
    s =
      Stand.neu(bloecke: @bloecke, phase: 2, beppo: true, beppo_pos: 7)
      |> Stand.eintragen(%{
        "nummer" => 1,
        "claim" => "A",
        "source_refs" => [3],
        "threads" => ["Die Werkstatt"],
        "_iter" => 1
      })
      |> Stand.eintragen(%{
        "nummer" => 2,
        "claim" => "B",
        "source_refs" => [9],
        "_iter" => 1,
        "_verworfen" => true
      })

    %{
      s
      | lfd: 2,
        kollisionen: %{1 => 3},
        register: [
          %{abschnitt: "FIGUREN", schluessel: "Kodex", zeile: "Decker", bloecke: [3]},
          %{abschnitt: "ABLAUF", schluessel: "0-20", zeile: "alles", bloecke: []},
          %{abschnitt: "ABLAUF", schluessel: "Fortschritt", zeile: "fertig", bloecke: []}
        ]
    }
  end

  @tag :tmp_dir
  test "ein Durchgang setzt fort, was der vorige abgelegt hat", %{tmp_dir: dir} do
    :ok = Abbild.schreiben(dir, abgelegter_stand())

    {:ok, n} = Fortsetzung.laden(dir, bloecke: @bloecke, phase: 2, beppo: true)

    assert {n.lfd, n.durchgang} == {2, 2}
    assert Enum.map(n.eingetragen, & &1.nr) == [1, 2]
    assert Stand.bestand_von(n, 2)["_verworfen"]
    assert n.themen == ["Die Werkstatt"]
    assert MapSet.equal?(n.belegte_bloecke, MapSet.new([3, 9]))
    assert n.kollisionen == %{1 => 3}
    assert n.beppo_pos == 7

    # die Selbstauskunft unter ABLAUF kommt nicht mit
    assert Enum.map(n.register, & &1.schluessel) == ["Kodex", "0-20"]
  end

  @tag :tmp_dir
  test "eine Ablage aus der Zeit mit Phase 3 lädt, ihr Ordnungsteil wird übergangen", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "aussagen.jsonl"), ~s({"nummer": 1, "claim": "A", "_iter": 3}\n))

    File.write!(
      Path.join(dir, "fortsetzung.json"),
      ~s({"register": [], "ordnung": {"verlauf": [{"id": "r1"}], "gesehen": ["0-20"]}})
    )

    {:ok, s} = Fortsetzung.laden(dir, bloecke: @bloecke, phase: 2)
    assert {s.lfd, s.durchgang} == {1, 4}
    refute Map.has_key?(Fortsetzung.daten(s), "ordnung")
  end

  test "eine Phase 3 gibt es nicht mehr" do
    assert_raise ArgumentError, ~r/phase: 1 oder 2/, fn -> Stand.neu(phase: 3) end
  end

  @tag :tmp_dir
  test "ohne Ablage im Verzeichnis ist es der erste Durchgang", %{tmp_dir: dir} do
    {:ok, s} = Fortsetzung.laden(dir, bloecke: @bloecke)
    assert {s.lfd, s.durchgang, s.eingetragen, s.register} == {0, 1, [], []}
  end

  @tag :tmp_dir
  test "ein Bestand ohne _iter war trotzdem ein Durchgang", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "aussagen.jsonl"), ~s({"nummer": 4, "claim": "alt"}\n))
    {:ok, s} = Fortsetzung.laden(dir, bloecke: @bloecke)
    assert {s.lfd, s.durchgang} == {4, 2}
  end

  @tag :tmp_dir
  test "eine kaputte Zeile ist ein Fehler, keine Lücke", %{tmp_dir: dir} do
    pfad = Path.join(dir, "aussagen.jsonl")
    File.write!(pfad, ~s({"nummer": 1}\n{kaputt\n))
    assert {:error, {:kaputte_zeile, ^pfad, 2}} = Fortsetzung.laden(dir, bloecke: @bloecke)

    File.write!(pfad, "")
    File.write!(Path.join(dir, "fortsetzung.json"), "{halb")
    assert {:error, {:kaputte_datei, _}} = Fortsetzung.laden(dir, bloecke: @bloecke)
  end

  test "ein fehlendes Verzeichnis ist ein Fehler" do
    assert {:error, {:keine_ablage, "/gibt/es/nicht"}} = Fortsetzung.laden("/gibt/es/nicht", [])
  end
end
