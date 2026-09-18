defmodule Worker.Jack.HilfeTest do
  @moduledoc """
  Das Werkzeug `hilfe` (Maintainer, 18.09.2026): „jedes tool braucht einen
  help aufruf / das es das gibt muss in den prompt".

  Die Werkzeugbeschreibungen tragen die Regeln, stehen aber nur einmal im
  Gespräch — nach einer Kompaktierung ist der Wortlaut weg. Fragen muss dann
  billiger sein als ein Probeaufruf, den die Wiederholungssperre mitzählt.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Resuemee.Werkzeuge, as: Gemeinsam

  defp definitionen do
    [
      %{
        name: "notiz",
        beschreibung:
          "Deine Notizen zur Chronik. Sie überleben den Kontext. Abschnitte: PHASEN …",
        parameter: %{
          "type" => "object",
          "properties" => %{
            "eintraege" => %{"type" => "array", "description" => "die Einträge"},
            "grund" => %{"type" => "string"}
          },
          "required" => ["eintraege"]
        },
        optional: ["grund"],
        ausfuehren: fn s, _p -> {s, {:ok, "ok"}} end
      },
      %{
        name: "fertig",
        beschreibung: "Meldet die Arbeit als abgeschlossen.",
        parameter: %{"type" => "object", "properties" => %{}},
        ausfuehren: fn s, _p -> {s, {:halt, "fertig"}} end
      }
    ]
  end

  defp hilfe, do: Gemeinsam.hilfe(definitionen())

  defp ruf(args), do: hilfe().ausfuehren.(args)

  describe "ohne Angabe" do
    test "nennt alle Werkzeuge mit ihrem ersten Satz" do
      {:ok, antwort} = ruf(%{})
      text = Jason.encode!(antwort)

      assert text =~ "notiz — Deine Notizen zur Chronik."
      assert text =~ "fertig — Meldet die Arbeit als abgeschlossen."
      refute text =~ "Abschnitte: PHASEN", "der erste Satz genügt in der Übersicht"
      assert text =~ "hilfe(werkzeug:"
    end
  end

  describe "mit Namen" do
    test "gibt die vollständige Beschreibung und die Felder" do
      {:ok, antwort} = ruf(%{"werkzeug" => "notiz"})
      text = Jason.encode!(antwort)

      assert text =~ "Abschnitte: PHASEN"
      assert text =~ "die Einträge"
      assert text =~ "eintraege"
    end

    test "nennt Pflicht und Optional getrennt" do
      {:ok, antwort} = ruf(%{"werkzeug" => "notiz"})

      assert %{"pflicht" => %{"pflicht" => ["eintraege"], "optional" => ["grund"]}} =
               Jason.decode!(Jason.encode!(antwort))
    end

    test "ein unbekanntes Werkzeug wird benannt, mit der Liste dazu" do
      {:ok, antwort} = ruf(%{"werkzeug" => "gibtsnicht"})
      text = Jason.encode!(antwort)

      assert text =~ "gibt es in diesem Lauf nicht"
      assert text =~ "notiz"
    end

    test "Leerraum im Namen stört nicht" do
      {:ok, antwort} = ruf(%{"werkzeug" => "  fertig  "})
      assert Jason.encode!(antwort) =~ "Meldet die Arbeit"
    end
  end

  describe "Eigenschaften" do
    test "zählt nie als Wiederholung und ändert nichts" do
      w = hilfe()

      assert w.wiederholung == :frei
      refute w.aendert_bestand
    end

    test "die Beschreibung nennt die verfügbaren Werkzeuge" do
      assert hilfe().beschreibung =~ "Verfügbar: notiz, fertig."
    end
  end
end
