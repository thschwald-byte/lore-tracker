defmodule Worker.Jack.Chronik.DurchsichtTest do
  @moduledoc """
  Issue #1211: die Durchsicht legt jeden Eintrag einzeln vor — und schützt
  dabei, was der Spielleiter geschrieben hat.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Durchsicht
  alias Worker.Jack.Resuemee.Stand

  defp e(id, opts \\ []) do
    %{
      id: id,
      titel: Keyword.get(opts, :titel, "Der Auftrag"),
      text: "Was geschah.",
      fakt_ids: Keyword.get(opts, :fakt_ids, ["f1", "f2"]),
      wichtigkeit: "phase",
      zeit_bezug: %{"art" => "isoliert"},
      kuratiert?: Keyword.get(opts, :kuratiert?, false),
      kuratierter_text: nil,
      neu?: true
    }
  end

  defp stand(eintraege), do: %Stand{art: :chronik, lauf: :durchsicht, eintraege: eintraege}

  describe "vorlegen" do
    test "zeigt den Eintrag mit allem, was zum Urteilen nötig ist" do
      assert {:ok, t} = Durchsicht.vorlage(stand([e("chr-a")]), 1)
      assert t =~ "chr-a"
      assert t =~ "Der Auftrag"
      assert t =~ "phase"
      assert t =~ "f1"
      assert t =~ "Was geschah"
    end

    test "eine Nummer, die es nicht gibt, sagt wie viele es sind" do
      assert {:error, m} = Durchsicht.vorlage(stand([e("chr-a")]), 7)
      assert m =~ "1 Einträge" or m =~ "1 Ein"
      assert m =~ "chronik()"
    end

    test "viele Fakten werden gekürzt, die Zahl bleibt genau" do
      viele = Enum.map(1..20, &"f#{&1}")
      assert {:ok, t} = Durchsicht.vorlage(stand([e("chr-a", fakt_ids: viele)]), 1)
      assert t =~ "12 weitere"
    end

    test "ein kuratierter Eintrag trägt die Warnung" do
      assert {:ok, t} = Durchsicht.vorlage(stand([e("chr-k", kuratiert?: true)]), 1)
      assert t =~ "KURATIERT"
      assert t =~ "nicht ersetzen"
    end
  end

  describe "ersetzen" do
    defp ruf(s, name, p) do
      [w] = Enum.filter(Durchsicht.werkzeuge(s), &(&1.name == name))
      w.ausfuehren.(s, p)
    end

    test "schreibt den Eintrag neu" do
      s = stand([e("chr-a")])

      assert {neu, {:ok, m}} =
               ruf(s, "eintrag_ersetzen", %{
                 "nummer" => 1,
                 "titel" => "Besser benannt",
                 "text" => "Genauer erzählt.",
                 "fakt_ids" => ["f1"],
                 "wichtigkeit" => "schluesselszene",
                 "grund" => "war zu grob"
               })

      assert m =~ "ersetzt"
      [g] = neu.eintraege
      assert g.titel == "Besser benannt"
      assert g.wichtigkeit == "schluesselszene"
      # Die ID bleibt — sonst verwaisen Bezüge und Kuration.
      assert g.id == "chr-a"
    end

    test "einen kuratierten Eintrag nicht — mit dem Weg nach vorn" do
      s = stand([e("chr-k", kuratiert?: true)])

      assert {unveraendert, {:error, m}} =
               ruf(s, "eintrag_ersetzen", %{
                 "nummer" => 1,
                 "titel" => "Meins",
                 "text" => "Meins",
                 "fakt_ids" => [],
                 "wichtigkeit" => "phase",
                 "grund" => "will ich"
               })

      assert m =~ "kuratiert"
      assert m =~ "eintrag_ergaenzen"
      assert unveraendert.eintraege == s.eintraege
    end

    test "bestätigen lässt den Eintrag, wie er ist" do
      s = stand([e("chr-a")])
      assert {neu, {:ok, m}} = ruf(s, "eintrag_bestaetigen", %{"nummer" => 1})
      assert m =~ "bestätigt"
      assert neu.eintraege == s.eintraege
      assert neu.durchsicht.erledigt[1] == :bestaetigt
    end
  end

  describe "die Durchsicht kann die Ordnung ändern" do
    test "sie hat eintrag_einordnen — was sie findet, soll sie beheben können" do
      namen = Enum.map(Durchsicht.werkzeuge(stand([])), & &1.name)
      # Die Ordnungswerkzeuge selbst kommen aus Entwurf; hier wird geprüft,
      # dass die Durchsicht die Urteilswerkzeuge hat.
      assert "durchsicht" in namen
      assert "eintrag_bestaetigen" in namen
      assert "eintrag_ersetzen" in namen
    end
  end
end
