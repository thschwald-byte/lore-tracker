defmodule HubWeb.CampaignLiveFragFensterTest do
  @moduledoc """
  Issue #850, erster Schnitt: das Frag-Fenster.

  Zwei Sorten Prüfung, und die zweite ist die wichtigere. Der Verhaltensteil
  hält den synthetischen Lauf fest (Frage → Konsole → Antwort mit Belegen).
  Die **Quelltext-Wächter** halten die vier Entscheidungen fest, die das
  Fenster unbrauchbar machen, wenn jemand sie beiläufig zurücknimmt — und
  keine davon erzeugt einen Fehler, wenn sie fällt:

  * `showModal()` statt `show()` — das Fenster würde alles blockieren und
    wäre damit genau das, was es nicht sein soll.
  * `phx-click-away` am Dialog — der erste Klick in eine Spalte schlösse es,
    mitsamt der halb getippten Antwort.
  * fehlendes `JS.ignore_attributes("open")` — morphdom diffte das
    `open`-Attribut weg, und das Fenster schlösse sich bei der nächsten
    Server-Antwort von selbst.
  * fehlende `handle_info`-Klausel in der CampaignLive — sie hat keinen
    Auffangzweig (#1149), der Timer-Tick brächte sie zum Absturz.
  """

  use HubWeb.ConnCase, async: false

  alias HubWeb.CampaignLive.FragFenster
  alias HubWeb.CampaignLive.FragFenster.Synthetisch

  describe "Zustand und synthetische Läufe (pur)" do
    test "initial/0 liefert alle Felder, die eine Klausel später schreibt (#1005)" do
      f = FragFenster.initial()

      # Ein Feld, das per Map-Update geschrieben wird, aber hier fehlt, wirft
      # zur Laufzeit einen KeyError — in VoiceSession war das ein Crash-Loop.
      for k <- [:offen?, :verlauf, :lauf, :frage, :befunde], do: assert(Map.has_key?(f, k))
      refute f.offen?
      assert f.verlauf == []
      assert f.lauf == nil
    end

    test "die Zahl am Knopf zählt Befunde, nicht das Gespräch" do
      f = FragFenster.initial()
      assert FragFenster.offene(f) == length(Synthetisch.befunde())

      # Das Gespräch ist flüchtig (Maintainer 25.09.) — es darf die Zahl nicht bewegen.
      assert FragFenster.offene(%{f | verlauf: [%{art: :frage, text: "x"}]}) ==
               FragFenster.offene(f)
    end

    test "jeder Lauf endet mit einer Antwort, und die Belege sind vollständig" do
      for art <- [:figur, :verbindung, :leer] do
        schritte = Synthetisch.schritte(art)
        assert schritte != []
        assert Enum.all?(schritte, &(&1.ms > 0)), "ohne Wartezeit ist die Konsole nicht messbar"
        assert List.last(schritte).art == :fertig

        a = Synthetisch.antwort(art)
        assert a.text != ""

        for b <- a.belege do
          for k <- [:id, :sitzung, :block, :text], do: assert(Map.has_key?(b, k))
        end
      end
    end

    test "die Nicht-Antwort sagt es, statt etwas zu erfinden" do
      assert Synthetisch.antwort(:leer).text =~ "nicht in den Aufzeichnungen"
      assert Synthetisch.antwort(:leer).belege == []

      # Der wichtigere Fall: beide Belege echt, die Verbindung erfunden (#850,
      # Kommentar 5, Frage 3). Die Antwort muss trotz Fundstellen NEIN sagen.
      v = Synthetisch.antwort(:verbindung)
      assert length(v.belege) == 2
      assert v.text =~ "steht nichts" or v.text =~ "nirgends"
    end

    test "die Spur der Verbindungs-Frage zeigt die fehlende Verbindung, bevor der Text es tut" do
      treffer =
        Synthetisch.schritte(:verbindung)
        |> Enum.filter(&(&1.art == :werkzeug and &1.treffer != nil))

      assert Enum.any?(treffer, &(&1.treffer == 0)),
             "ohne einen Null-Treffer in der Spur ist der Prototyp für diese Frage wertlos"
    end
  end

  describe "Quelltext-Wächter" do
    @fenster "lib/hub_web/live/campaign_live/frag_fenster.ex"
    @hook "assets/js/hooks/frag_fenster.js"
    @live "lib/hub_web/live/campaign_live.ex"

    test "der Dialog wird nicht-modal geöffnet — .show(), nie .showModal()" do
      js = nur_code(@hook, "//")
      assert js =~ ".show()"
      refute js =~ "showModal", "showModal blockiert die Seite — genau das soll das Fenster nicht"
    end

    test "kein phx-click-away am Dialog" do
      refute nur_code(@fenster, "#") =~ "phx-click-away",
             "ein Klick in eine Spalte würde das Fenster schließen — mitsamt der Antwort"
    end

    test "JS.ignore_attributes(\"open\") hält den Zustand gegen morphdom" do
      code = nur_code(@fenster, "#")

      assert code =~ ~s|JS.ignore_attributes("open")|,
             "ohne das diffed der nächste Server-Render das offene Fenster zu"

      refute code =~ ~s|phx-update="ignore"|,
             "das fröre den Inhalt ein — die Antwort erschiene nie"
    end

    test "die CampaignLive hat eine Klausel für den Timer-Tick (sie hat keinen Auffangzweig)" do
      assert File.read!(@live) =~ "def handle_info({:frag_schritt,"
    end

    test "ein zweiter Lauf bricht den Timer des ersten ab" do
      assert nur_code(@fenster, "#") =~ "Process.cancel_timer"
    end

    # Ein Wächter, der seine eigene Begründung findet, ist wertlos: Die
    # Moduledocs erklären, WARUM `showModal`, `phx-click-away` und
    # `phx-update="ignore"` hier falsch wären — und nennen sie dabei. Geprüft
    # wird deshalb der Code ohne Kommentare und ohne die Doku-Heredocs.
    defp nur_code(pfad, kommentar) do
      Path.join(Application.app_dir(:hub) |> Path.join("../../../../apps/hub"), pfad)
      |> Path.expand()
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn z, {acc, in_doc?} ->
        t = String.trim(z)

        cond do
          in_doc? -> {acc, not String.ends_with?(t, ~s("""))}
          String.starts_with?(t, ["@moduledoc \"\"\"", "@doc \"\"\""]) -> {acc, true}
          String.starts_with?(t, kommentar) -> {acc, false}
          true -> {[ohne_rest(z, kommentar) | acc], false}
        end
      end)
      |> elem(0)
      |> Enum.join("\n")
    end

    # Auch der Kommentar am Zeilenende zählt nicht als Code — `this.el.show();
    # // NICHT showModal()` ist eine Begründung, kein Aufruf. Das Leerzeichen
    # vor dem Marker schützt URLs (`https://…`).
    defp ohne_rest(zeile, kommentar) do
      case String.split(zeile, " " <> kommentar, parts: 2) do
        [code | _] -> code
        _ -> zeile
      end
    end
  end
end
