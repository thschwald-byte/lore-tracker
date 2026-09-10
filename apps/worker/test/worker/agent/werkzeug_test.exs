defmodule Worker.Agent.WerkzeugTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.{Schema, Werkzeug}

  @schema %{
    "type" => "object",
    "properties" => %{
      "claim" => %{"type" => "string"},
      "art" => %{"type" => "string", "enum" => ["a", "b"]},
      "refs" => %{"type" => "array", "items" => %{"type" => "integer"}},
      "notiz" => %{"type" => "string"},
      "eintraege" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "zeile" => %{"type" => ["string", "null"]},
            "text" => %{"type" => "string"}
          }
        }
      }
    }
  }

  defp neu(parameter, opts \\ []) do
    [name: "w", beschreibung: "w", parameter: parameter, ausfuehren: fn _ -> {:ok, ""} end]
    |> Keyword.merge(opts)
    |> Werkzeug.neu()
  end

  describe "streng per Default" do
    test "jedes Feld wird Pflicht, auch in Listen von Objekten" do
      p = neu(@schema).parameter
      assert p["required"] == ["art", "claim", "eintraege", "notiz", "refs"]
      assert p["properties"]["eintraege"]["items"]["required"] == ["text", "zeile"]
    end

    test "additionalProperties false auf jeder Objekt-Ebene, ausdrückliches true bleibt" do
      p = neu(@schema).parameter
      assert p["additionalProperties"] == false
      assert p["properties"]["eintraege"]["items"]["additionalProperties"] == false
      assert neu(Map.put(@schema, "additionalProperties", true)).parameter["additionalProperties"]
    end

    test "Pflicht-Text ohne enum bekommt minLength 1; enum, nullable und ausdrückliches minLength bleiben" do
      props = neu(@schema).parameter["properties"]
      assert props["claim"]["minLength"] == 1
      refute Map.has_key?(props["art"], "minLength")
      refute Map.has_key?(props["eintraege"]["items"]["properties"]["zeile"], "minLength")

      locker = put_in(@schema, ["properties", "claim", "minLength"], 0)
      assert neu(locker).parameter["properties"]["claim"]["minLength"] == 0
    end

    test "optional nimmt Felder aus der Pflicht, auch verschachtelt" do
      p = neu(@schema, optional: ["notiz", "eintraege.zeile"]).parameter
      refute "notiz" in p["required"]
      refute Map.has_key?(p["properties"]["notiz"], "minLength")
      assert p["properties"]["eintraege"]["items"]["required"] == ["text"]
    end

    test "ein ausdrückliches required bleibt vorn und wird nicht doppelt" do
      p = neu(Map.put(@schema, "required", ["refs"])).parameter
      assert p["required"] == ["refs", "art", "claim", "eintraege", "notiz"]
    end

    test "optional mit einem Feld, das es nicht gibt, ist ein Fehler" do
      assert_raise ArgumentError, ~r/optional nennt Felder, die es nicht gibt: notitz/, fn ->
        neu(@schema, optional: ["notitz"])
      end
    end

    test "optional gegen ausdrückliches required ist ein Fehler" do
      assert_raise ArgumentError, ~r/optional widerspricht required: claim/, fn ->
        neu(Map.put(@schema, "required", ["claim"]), optional: ["claim"])
      end
    end
  end

  describe "Wirkung auf die Prüfung" do
    test "leere Texte und fremde Felder werden abgelehnt" do
      p = neu(@schema, optional: ["notiz"]).parameter
      args = %{"claim" => "", "art" => "a", "refs" => [], "eintraege" => [], "x" => 1}

      assert {:error, fehler} = Schema.pruefen(p, args)
      assert "claim: mindestens 1 Zeichen, erhalten 0" in fehler
      assert Enum.any?(fehler, &(&1 =~ "x: unbekanntes Feld"))
    end

    test "ein leerer Enum-Wert fällt durch das Enum" do
      p = neu(@schema).parameter
      args = %{"claim" => "c", "art" => "", "refs" => [], "notiz" => "n", "eintraege" => []}

      assert {:error, [meldung]} = Schema.pruefen(p, args)
      assert meldung == ~s(art: muss einer von "a", "b" sein, erhalten "")
    end

    test "fehlende Pflichtfelder werden alle auf einmal genannt" do
      assert {:error, fehler} = Schema.pruefen(neu(@schema).parameter, %{})
      assert length(fehler) == 5
    end
  end
end
