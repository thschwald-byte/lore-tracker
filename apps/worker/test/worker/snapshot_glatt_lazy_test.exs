defmodule Worker.SnapshotGlattLazyTest do
  @moduledoc """
  Issue #1151 (Epic #1146, C4): der `campaign`-Snapshot lässt die geglätteten
  Blöcke weg, wenn der Hub `"glatt" => "lazy"` mitschickt.

  **Der wichtigste Test ist der erste: ohne Flag unverändert.** Darauf beruht
  die ganze Verhandlung — ein Alt-Hub sendet das Flag nicht und muss weiterhin
  alles bekommen. Bricht das, merkt es niemand am neuen Hub (der schickt das
  Flag ja), sondern nur der, der noch die alte Version fährt.

  **Und der Key wird WEGGELASSEN, nicht auf `[]` gesetzt.** Nur so kann der Hub
  „nicht geliefert" von „leer" unterscheiden — er braucht das, um zu erkennen,
  ob der Worker das Flag überhaupt versteht.
  """

  use ExUnit.Case, async: false

  alias Worker.Repo.Luecken

  describe "mit_glatt/3 — die Verhandlung" do
    test "ohne Flag reist smoothed mit" do
      # Der Alt-Hub-Fall. Bricht er, fällt die Geglättet-Spalte bei jedem
      # Betrachter aus, der noch die alte Hub-Version lädt.
      map = Luecken.mit_glatt(%{"campaign" => %{}}, %{"kind" => "campaign"}, "gibt-es-nicht")
      assert Map.has_key?(map, "smoothed")
    end

    test "mit Flag fehlt der Key GANZ" do
      map =
        Luecken.mit_glatt(
          %{"campaign" => %{}},
          %{"kind" => "campaign", "glatt" => "lazy"},
          "gibt-es-nicht"
        )

      refute Map.has_key?(map, "smoothed"),
             "der Key muss FEHLEN, nicht leer sein — sonst kann der Hub " <>
               "'nicht geliefert' nicht von 'leer' unterscheiden"
    end

    test "ein unbekannter Flag-Wert liefert voll aus" do
      # Fail-safe: was der Worker nicht kennt, behandelt er wie 'kein Flag'.
      # Ein Tippfehler im Hub darf keine leere Spalte erzeugen.
      for wert <- ["voll", "", "true", "lazyy"] do
        map = Luecken.mit_glatt(%{}, %{"kind" => "campaign", "glatt" => wert}, "gibt-es-nicht")
        assert Map.has_key?(map, "smoothed"), "Flag-Wert #{inspect(wert)} darf nicht greifen"
      end
    end

    test "alle übrigen Schlüssel bleiben unberührt" do
      basis = %{"campaign" => %{"id" => "x"}, "sessions" => [1, 2], "utterances" => []}
      mit = Luecken.mit_glatt(basis, %{"kind" => "campaign"}, "gibt-es-nicht")
      ohne = Luecken.mit_glatt(basis, %{"kind" => "campaign", "glatt" => "lazy"}, "gibt-es-nicht")

      assert Map.drop(mit, ["smoothed"]) == basis
      assert ohne == basis
    end
  end
end
