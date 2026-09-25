defmodule Worker.Jack.Frage.EingabeTest do
  @moduledoc """
  Issue #850: die Eingabe des Frage-Jack — kampagnenweit statt sitzungsweit.

  Die Lesebasis des Resümee-Jack ist sitzungsbezogen. Eine Frage an die
  Kampagne hat keine „diese Sitzung"; bekäme der Jack nur die Fakten der
  jüngsten, hielte er einen Bruchteil für alles und antwortete falsch, ohne es
  zu merken.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Frage.Eingabe

  defp basis do
    %{
      sitzung: %{id: "s3", nummer: 3, name: "Dritte"},
      fakten: [%{id: "S3-F1", fakt_id: "f_c"}],
      fruehere: [
        %{nummer: 1, name: "Erste", fakten: [%{id: "S1-F1", fakt_id: "f_a"}]},
        %{nummer: 2, name: "Zweite", fakten: [%{id: "S2-F1", fakt_id: "f_b"}]}
      ],
      max_woerter: 150
    }
  end

  describe "zusaetze/2" do
    test "legt die Fakten ALLER Sitzungen zusammen, früheste zuerst" do
      e = Eingabe.zusaetze(basis(), "Wer war dabei?")

      assert Enum.map(e.fakten, & &1.id) == ["S1-F1", "S2-F1", "S3-F1"]
      assert e.art == :frage
      assert e.frage == "Wer war dabei?"
    end

    test "die Resümee-Länge fällt weg — hier wird kein Resümee geschrieben" do
      refute Map.has_key?(Eingabe.zusaetze(basis(), "x"), :max_woerter)
    end

    test "die Sitzung bleibt als Anker erhalten" do
      # Die Lesebasis braucht eine: Mitschnitt, `sitzung.nummer`, `fruehere`.
      assert Eingabe.zusaetze(basis(), "x").sitzung.nummer == 3
    end
  end

  describe "frage/1" do
    test "liefert die Frage, ohne sie einen leeren Text" do
      assert Eingabe.frage(%{frage: "Wer ist da?"}) == "Wer ist da?"
      assert Eingabe.frage(%{}) == ""
      assert Eingabe.frage(%{frage: nil}) == ""
    end
  end
end
