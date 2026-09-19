defmodule Worker.MaterializerZeitAnkerTest do
  @moduledoc """
  #1247 (Z1): der `ZeitAnkerSet`-Fold — Konvergenz, Rücknahme ohne Delete, und
  die harte Regel, dass eine menschlich abgesegnete Stelle niemand
  überschreibt.

  **Der Rundreise-Test ist Absicht und kein Beiwerk.** Die Nutzdaten liegen
  als JSON-Blob statt als Spalten; das vermeidet die Migrations- und
  Positionsfalle (#1211), verschiebt aber die Formprüfung nach innen — eine
  Spalte erzwingt ihre Form beim Schreiben, ein Blob nicht. Benennt die
  Kodierung eines Tages ein Feld anders, merkt es niemand, bis ein Leser
  `nil` bekommt. `schreiben → lesen → vollständig` ist die Entsprechung zu
  dem Schema-Wächter, den eine Spaltenlösung geschenkt bekäme.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S

  @cid "camp-zeit-1247"
  @sid "sess-zeit-1247"
  @anker "z_abc123"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp daten(extra) do
    Map.merge(
      %{
        "utterance_ids" => ["u1", "u2"],
        "art" => "zeitpunkt",
        "wert" => "am 15. November 2080",
        "welt" => "spielwelt",
        "zweifel" => "",
        "beleg" => "„wir schreiben den fünfzehnten November\"",
        "quelle" => "jack",
        "abgesegnet_von" => "",
        "abgesegnet_am" => ""
      },
      extra
    )
  end

  # Die `event_id`s müssen hier **lexikografisch aufsteigend** sein („za-01"
  # vor „za-02"), weil `event_id_supersedes?/2` Strings vergleicht. In Prod
  # sind es UUIDv7, also von sich aus monoton. Beim ersten Wurf hiessen sie
  # „za-a"/„za-b" bzw. „za-set"/„za-los" — und dann verlor die spätere
  # Schreibung, was wie ein Fehler im Fold aussah und keiner war.
  defp ev(extra, seq, event_id, anker \\ @anker) do
    event(
      "ZeitAnkerSet",
      %{
        "anker_id" => anker,
        "campaign_id" => @cid,
        "session_id" => @sid,
        "daten" => daten(extra)
      },
      seq,
      event_id: event_id
    )
  end

  defp row(anker \\ @anker) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(S.zeit_anker(), anker) end)
    rows
  end

  defp gelesen(anker \\ @anker) do
    case row(anker) do
      [r] -> Jason.decode!(elem(r, 4))
      _ -> nil
    end
  end

  defp wert, do: (gelesen() || %{})["wert"]

  describe "Rundreise: was geschrieben wird, kommt vollständig zurück" do
    test "jedes Feld der Kodierung überlebt den Fold" do
      assert {:applied, 1} = Materializer.apply_event(ev(%{}, 1, "za-01"))

      d = gelesen()

      # Vollständigkeit gegen die Feldliste des Plans — nicht gegen eine
      # Stichprobe. Fehlt eines, ist der Blob still unvollständig geworden.
      for feld <- ~w(utterance_ids art wert welt zweifel beleg quelle
                     abgesegnet_von abgesegnet_am) do
        assert Map.has_key?(d, feld), "Feld #{feld} ist im Blob verloren gegangen"
      end

      assert d["utterance_ids"] == ["u1", "u2"]
      assert d["art"] == "zeitpunkt"

      # Und die Spalten daneben, die die Cascade braucht.
      [r] = row()
      assert elem(r, 1) == @anker
      assert elem(r, 2) == @cid
      assert elem(r, 3) == @sid
    end
  end

  describe "Konvergenz" do
    test "LWW: der höhere event_id gewinnt, jede Reihenfolge endet gleich" do
      events = [
        ev(%{"wert" => "erster"}, 1, "za-01"),
        ev(%{"wert" => "zweiter"}, 2, "za-02")
      ]

      assert Enum.uniq(materialize_permutations(events, &wert/0)) == ["zweiter"]
    end

    test "Rücknahme schreibt eine reguläre Zeile statt zu löschen (#698)" do
      Materializer.apply_event(ev(%{}, 1, "za-01"))
      Materializer.apply_event(ev(%{"art" => "geloest"}, 2, "za-02"))

      # Die Zeile steht noch — nur ihr Inhalt sagt jetzt „gehört nicht auf die
      # Linie". Ein Delete würde bei vertauschter Zustellung divergieren.
      assert [_] = row()
      assert gelesen()["art"] == "geloest"
    end

    test "Setzen und Zurücknehmen konvergieren in beiden Reihenfolgen" do
      events = [ev(%{}, 1, "za-01"), ev(%{"art" => "geloest"}, 2, "za-02")]
      holen = fn -> (gelesen() || %{})["art"] end

      assert Enum.uniq(materialize_permutations(events, holen)) == ["geloest"]
    end
  end

  describe "die Absegnung ist hart" do
    test "ein maschineller Anker überschreibt keinen abgesegneten — auch mit höherem event_id" do
      Materializer.apply_event(
        ev(%{"wert" => "von Hand", "quelle" => "mensch", "abgesegnet_am" => "2026-09-19"}, 1, "za-01")
      )

      # Höherer event_id, also nach LWW der Gewinner — und trotzdem abgewiesen.
      assert {:applied, 2} = Materializer.apply_event(ev(%{"wert" => "von Jack"}, 2, "za-02"))

      assert wert() == "von Hand"
    end

    test "auch die Reihenfolge kann die Absegnung nicht aushebeln" do
      events = [
        ev(%{"wert" => "von Jack"}, 2, "za-02"),
        ev(%{"wert" => "von Hand", "quelle" => "mensch", "abgesegnet_am" => "2026-09-19"}, 1,
          "za-01")
      ]

      # Egal, welches zuerst ankommt: am Ende steht die menschliche Festlegung.
      assert Enum.uniq(materialize_permutations(events, &wert/0)) == ["von Hand"]
    end

    test "ein Mensch überschreibt einen Menschen — dort gilt wieder LWW" do
      Materializer.apply_event(
        ev(%{"wert" => "erste Kuration", "abgesegnet_am" => "2026-09-18"}, 1, "za-01")
      )

      Materializer.apply_event(
        ev(%{"wert" => "zweite Kuration", "abgesegnet_am" => "2026-09-19"}, 2, "za-02")
      )

      assert wert() == "zweite Kuration"
    end
  end

  describe "Boundary-Defense" do
    test "ein Anker ohne Utterances wird verworfen statt ortlos gespeichert" do
      assert {:applied, 1} = Materializer.apply_event(ev(%{"utterance_ids" => []}, 1, "za-01"))
      assert row() == []
    end

    test "fehlende IDs und fehlende Daten crashen nicht" do
      e1 = event("ZeitAnkerSet", %{"anker_id" => nil, "campaign_id" => @cid}, 1)
      assert {:applied, 1} = Materializer.apply_event(e1)

      e2 = event("ZeitAnkerSet", %{"anker_id" => @anker, "campaign_id" => @cid}, 2)
      assert {:applied, 2} = Materializer.apply_event(e2)

      assert row() == []
    end
  end

  describe "Cascade" do
    test "CampaignDeleted räumt Anker und Stand mit" do
      Materializer.apply_event(ev(%{}, 1, "za-01"))
      assert [_] = row()

      Materializer.apply_event(
        event("CampaignDeleted", %{"campaign_id" => @cid, "id" => @cid}, 2)
      )

      assert row() == []
    end

    test "SessionDeleted räumt die Anker dieser Sitzung" do
      Materializer.apply_event(ev(%{}, 1, "za-01"))
      assert [_] = row()

      Materializer.apply_event(
        event("SessionDeleted", %{"session_id" => @sid, "campaign_id" => @cid}, 2)
      )

      assert row() == []
    end
  end
end
