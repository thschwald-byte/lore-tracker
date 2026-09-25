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

  describe "anker_aus/2 — die jüngste Sitzung MIT Fakten" do
    # Gefunden am ersten echten Lauf (25.09.2026): Die Kampagne hatte vier
    # Sitzungen mit 208 Fakten — aber nur in 1 und 2. Der Anker fiel auf die
    # jüngste, also die leere vierte, und die Eingabe scheiterte mit
    # `:no_facts`, obwohl alles dalag. Eine angelegte, noch nicht bespielte
    # Sitzung ist der Normalfall.
    defp sessions, do: [%{id: "s1", number: 1}, %{id: "s2", number: 2}, %{id: "s4", number: 4}]

    test "überspringt leere jüngere Sitzungen" do
      assert Eingabe.anker_aus(sessions(), &(&1 in ["s1", "s2"])) == {:ok, "s2"}
    end

    test "nimmt die jüngste, wenn sie Fakten hat" do
      assert Eingabe.anker_aus(sessions(), fn _ -> true end) == {:ok, "s4"}
    end

    test "ohne Sitzung mit Fakten gibt es nichts zu fragen" do
      assert Eingabe.anker_aus(sessions(), fn _ -> false end) == {:error, :keine_sitzung}
      assert Eingabe.anker_aus([], fn _ -> true end) == {:error, :keine_sitzung}
    end

    test "die Reihenfolge der Liste entscheidet nicht, die Nummer tut es" do
      verdreht = Enum.shuffle(sessions())
      assert Eingabe.anker_aus(verdreht, &(&1 in ["s1", "s2"])) == {:ok, "s2"}
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
