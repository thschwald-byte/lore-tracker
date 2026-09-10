defmodule Worker.Agent.SchemaTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Schema

  @schema %{
    "type" => "object",
    "properties" => %{
      "text" => %{"type" => "string", "minLength" => 1},
      "anzahl" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
      "faktor" => %{"type" => "number"},
      "schnell" => %{"type" => "boolean"},
      "art" => %{"type" => "string", "enum" => ["a", "b"]},
      "ids" => %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 2},
      "notiz" => %{"type" => ["string", "null"]}
    },
    "required" => ["text"],
    "additionalProperties" => false
  }

  describe "pruefen/2" do
    test "gültige Argumente kommen unverändert zurück" do
      args = %{"text" => "x", "anzahl" => 3, "ids" => ["a"], "art" => "b"}
      assert Schema.pruefen(@schema, args) == {:ok, args}
    end

    test "Pflichtfeld fehlt" do
      assert {:error, ["text: fehlt"]} = Schema.pruefen(@schema, %{})
    end

    test "falscher Typ nennt Pfad, Erwartung und Erhaltenes in Schema-Typnamen" do
      assert {:error, ["text: erwartet string, erhalten integer"]} =
               Schema.pruefen(@schema, %{"text" => 5})
    end

    test "unbekanntes Feld bei additionalProperties false, mit der Liste der erlaubten" do
      assert {:error, [meldung]} = Schema.pruefen(@schema, %{"text" => "x", "foo" => 1})
      assert meldung =~ "foo: unbekanntes Feld"
      assert meldung =~ "anzahl, art, faktor, ids, notiz, schnell, text"
    end

    test "enum" do
      assert {:error, [~s(art: muss einer von "a", "b" sein, erhalten "c")]} =
               Schema.pruefen(@schema, %{"text" => "x", "art" => "c"})
    end

    test "Grenzen für Zahlen, Texte und Listen" do
      assert {:error, ["anzahl: höchstens 10, erhalten 11"]} =
               Schema.pruefen(@schema, %{"text" => "x", "anzahl" => 11})

      assert {:error, ["text: mindestens 1 Zeichen, erhalten 0"]} =
               Schema.pruefen(@schema, %{"text" => ""})

      assert {:error, ["ids: höchstens 2 Einträge, erhalten 3"]} =
               Schema.pruefen(@schema, %{"text" => "x", "ids" => ["a", "b", "c"]})
    end

    test "Listeneinträge werden mit Index geprüft" do
      assert {:error, ["ids.1: erwartet string, erhalten integer"]} =
               Schema.pruefen(@schema, %{"text" => "x", "ids" => ["a", 2]})
    end

    test "alle Verstöße auf einmal, nicht nur der erste" do
      assert {:error, fehler} = Schema.pruefen(@schema, %{"anzahl" => 0, "art" => "z"})
      assert length(fehler) == 3
    end

    test "nicht-Objekt auf oberster Ebene" do
      assert {:error, ["Argumente: erwartet object, erhalten array"]} =
               Schema.pruefen(@schema, [1])
    end
  end

  describe "pruefen/2 gleicht an, was lokale Modelle falsch schicken" do
    test "Zahlen und Wahrheitswerte als Text" do
      assert {:ok, %{"anzahl" => 5, "faktor" => 2.5, "schnell" => true}} =
               Schema.pruefen(@schema, %{
                 "text" => "x",
                 "anzahl" => "5",
                 "faktor" => "2.5",
                 "schnell" => "true"
               })
               |> then(fn {:ok, m} -> {:ok, Map.delete(m, "text")} end)
    end

    test "5.0 für integer wird 5" do
      assert {:ok, %{"anzahl" => 5}} = Schema.pruefen(@schema, %{"text" => "x", "anzahl" => 5.0})
    end

    test "kein Angleichen, wo der Text keine Zahl ist" do
      assert {:error, ["anzahl: erwartet integer, erhalten string"]} =
               Schema.pruefen(@schema, %{"text" => "x", "anzahl" => "fünf"})
    end

    test "null für ein optionales Feld fällt weg" do
      assert {:ok, args} = Schema.pruefen(@schema, %{"text" => "x", "anzahl" => nil})
      refute Map.has_key?(args, "anzahl")
    end

    test "null bleibt, wo das Schema null erlaubt" do
      assert {:ok, %{"notiz" => nil}} = Schema.pruefen(@schema, %{"text" => "x", "notiz" => nil})
    end

    test "null für ein Pflichtfeld ist ein Verstoß" do
      assert {:error, ["text: erwartet string, erhalten null"]} =
               Schema.pruefen(@schema, %{"text" => nil})
    end
  end

  describe "unbekannte/1" do
    test "leer für ein Schema aus unterstützten Schlüsseln" do
      assert Schema.unbekannte(@schema) == []
    end

    test "findet nicht unterstützte Schlüssel auch verschachtelt" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "string", "pattern" => "^x"},
          "b" => %{"type" => "array", "items" => %{"type" => "string", "default" => "y"}}
        }
      }

      assert Schema.unbekannte(schema) == ["a.pattern", "b.items.default"]
    end

    test "findet unbekannte Typnamen und additionalProperties als Schema" do
      schema = %{
        "type" => "object",
        "additionalProperties" => %{"type" => "string"},
        "properties" => %{"a" => %{"type" => "str"}}
      }

      assert Schema.unbekannte(schema) == [
               "additionalProperties (nur true/false)",
               ~s|a.type ("str")|
             ]
    end
  end

  test "normalisieren/1 macht Atom-Schlüssel und -Werte zu Text" do
    assert Schema.normalisieren(%{
             type: :object,
             properties: %{a: %{type: :string}},
             required: [:a]
           }) ==
             %{
               "type" => "object",
               "properties" => %{"a" => %{"type" => "string"}},
               "required" => ["a"]
             }
  end
end
