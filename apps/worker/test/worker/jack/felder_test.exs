defmodule Worker.Jack.FelderTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.{Schema, Werkzeug}
  alias Worker.Jack.Felder

  # Quelltext-Wächter: Jacks Enums müssen die sein, mit denen die Pipeline
  # normalisiert (J4 gibt Jacks Aussagen an genau diese Stelle). Ein Wert,
  # den Parsing nicht kennt, fiele dort still auf einen Default.
  @parsing Path.expand("../../../lib/worker/recording/pipeline/parsing.ex", __DIR__)

  defp aus_parsing(attribut) do
    [_, liste] = Regex.run(~r/@#{attribut}\s+~w\(([^)]*)\)/u, File.read!(@parsing))
    String.split(liste)
  end

  test "narration_time, precision und fact_type wie in Parsing" do
    assert Felder.enums()["narration_time"] == aus_parsing("narration_times")
    assert Felder.enums()["precision"] == aus_parsing("precisions")
    assert Felder.enums()["fact_type"] == aus_parsing("fact_types")
  end

  describe "die Schemas taugen für Werkzeug.neu und werden streng" do
    defp werkzeug(schema) do
      Werkzeug.neu(
        name: "w",
        beschreibung: "w",
        parameter: schema,
        optional: Felder.optional(),
        ausfuehren: fn _ -> {:ok, ""} end
      )
    end

    test "einreichen: alle Inhaltsfelder außer time_offset und precision sind Pflicht" do
      p = werkzeug(Felder.einreichen_schema()).parameter
      assert Enum.sort(p["required"]) == Enum.sort(Felder.inhaltsfelder() -- Felder.optional())
      assert p["additionalProperties"] == false
      assert p["properties"]["claim"]["minLength"] == 1
      assert p["properties"]["cast_match"]["minLength"] == 0
    end

    test "entscheiden: dazu die vier Steuerfelder als Pflicht" do
      p = werkzeug(Felder.entscheiden_schema()).parameter
      assert Enum.all?(Felder.steuerfelder(), &(&1 in p["required"]))
    end

    test "leere source_refs und leere Enum-Werte werden von der Laufzeit abgelehnt" do
      p = werkzeug(Felder.einreichen_schema()).parameter

      args = %{
        "claim" => "c",
        "character" => "",
        "cast_match" => "",
        "narration_time" => "",
        "time_anchor" => "session",
        "in_game_date" => "",
        "fact_type" => "zustand",
        "threads" => [],
        "source_refs" => [],
        "beleg" => "b"
      }

      assert {:error, fehler} = Schema.pruefen(p, args)
      assert Enum.any?(fehler, &(&1 =~ "source_refs: mindestens 1 Einträge"))
      assert Enum.any?(fehler, &(&1 =~ "narration_time: muss einer von"))
    end
  end
end
