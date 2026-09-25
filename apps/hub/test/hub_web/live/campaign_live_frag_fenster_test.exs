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

  describe "Belege zeigen auf echte Stellen, sobald es welche gibt" do
    defp fakt(n),
      do: %{
        "id" => "f_#{n}",
        "claim" => "Aussage #{n}",
        "session_id" => "s-1",
        "quell_utterance_ids" => ["u-#{n}-a", "u-#{n}-b"]
      }

    test "mit geladenen Fakten trägt jeder Beleg ein Sprungziel" do
      a = Synthetisch.antwort(:figur, Enum.map(1..8, &fakt/1), [%{"id" => "s-1", "number" => 3}])

      assert a.belege != []

      for b <- a.belege do
        assert b.utterance_id, "ohne Ziel ist der ↗ tot"
        assert b.sitzung == "S3", "die Sitzungsnummer kommt aus der Sitzungsliste"
        assert b.text != ""
      end
    end

    test "dieselbe Frage zeigt dieselben Belege" do
      f = Enum.map(1..12, &fakt/1)
      assert Synthetisch.antwort(:figur, f) == Synthetisch.antwort(:figur, f)
    end

    test "verschiedene Fragen greifen verschiedene Fakten" do
      f = Enum.map(1..12, &fakt/1)
      a = Synthetisch.antwort(:figur, f).belege |> Enum.map(& &1.id)
      b = Synthetisch.antwort(:verbindung, f).belege |> Enum.map(& &1.id)
      refute a == b, "sonst sieht jede Antwort gleich aus"
    end

    test "ohne Fakten bleibt der erfundene Beleg — und sein Ziel ist ausdrücklich leer" do
      a = Synthetisch.antwort(:figur, [])
      assert a.belege != []
      for b <- a.belege, do: refute(b[:utterance_id], "ein erfundener Beleg darf nicht springen")
    end

    test "Fakten ohne Quellen taugen nicht als Beleg" do
      ohne = [
        %{"id" => "f_x", "claim" => "x", "session_id" => "s-1", "quell_utterance_ids" => []}
      ]

      assert Synthetisch.antwort(:figur, ohne).belege == []
    end

    test "die Nicht-Antwort bleibt eine Nicht-Antwort, auch mit Fakten" do
      a = Synthetisch.antwort(:leer, Enum.map(1..8, &fakt/1))
      assert a.text =~ "nicht in den Aufzeichnungen"
      assert a.belege == [], "eine Nicht-Antwort belegt nichts"
    end
  end

  describe "Der zweite Eingang: Befund am Objekt" do
    test "nicht jede Fakt-Zeile trägt ein Zeichen, aber immer dieselben" do
      ids = for n <- 1..200, do: "f_#{n}"
      mit = Enum.filter(ids, &Synthetisch.befund_an_fakt/1)

      assert mit != [], "ohne Marker ist der zweite Eingang unerreichbar"
      assert length(mit) < div(length(ids), 3), "zu viele — die Spalte würde blinken"

      # Deterministisch: beim Neuladen stehen die Zeichen an denselben Zeilen.
      assert Enum.map(ids, &Synthetisch.befund_an_fakt/1) ==
               Enum.map(ids, &Synthetisch.befund_an_fakt/1)
    end

    test "jeder gestreute Marker zeigt auf einen Befund, den es gibt" do
      bekannte = MapSet.new(Synthetisch.befunde(), & &1.id)

      for n <- 1..200, bf = Synthetisch.befund_an_fakt("f_#{n}") do
        assert MapSet.member?(bekannte, bf), "#{bf} zeigt ins Leere"
      end
    end

    test "ein Fakt ohne id bekommt kein Zeichen" do
      refute Synthetisch.befund_an_fakt(nil)
    end

    test "zweimal auf dasselbe Zeichen klicken legt den Befund nicht doppelt ab" do
      sock = %Phoenix.LiveView.Socket{assigns: %{frag: FragFenster.initial(), __changed__: %{}}}
      [b | _] = Synthetisch.befunde()

      {:noreply, s1} = FragFenster.event(sock, "frag_befund", %{"id" => b.id})
      assert length(s1.assigns.frag.verlauf) == 1
      assert s1.assigns.frag.offen?

      # Zweiter Klick — in der Spalte hin und her, oder schlicht nochmal.
      {:noreply, s2} = FragFenster.event(s1, "frag_befund", %{"id" => b.id})
      assert length(s2.assigns.frag.verlauf) == 1, "der Befund stünde sonst zweimal da"
      assert s2.assigns.frag.offen?, "und das Fenster muss trotzdem aufgehen"
    end

    test "ein Zeichen, dessen Befund es nicht gibt, tut nichts" do
      sock = %Phoenix.LiveView.Socket{assigns: %{frag: FragFenster.initial(), __changed__: %{}}}
      {:noreply, s} = FragFenster.event(sock, "frag_befund", %{"id" => "gibt-es-nicht"})
      assert s.assigns.frag.verlauf == []
    end
  end

  describe "Wartetext" do
    alias HubWeb.CampaignLive.FragFenster.Warten

    test "fünfzig Sprüche, keiner doppelt" do
      l = Warten.sprueche()
      assert length(l) == 50
      assert length(Enum.uniq(l)) == 50, "ein doppelter Spruch fällt beim Zusehen auf"
    end

    test "jeder Spruch sagt, was gerade geschieht — und keiner verspricht ein Ergebnis" do
      for spruch <- Warten.sprueche() do
        assert String.ends_with?(spruch, "…"), "#{spruch} — die Auslassung trägt das Laufende"

        # Verboten ist, was ABSCHLUSS behauptet — das kann erst die Antwort
        # einlösen. „Warte auf die Antwort der Schiffs-KI …" ist dagegen
        # einwandfrei: Es beschreibt genau das Warten. (Der erste Wurf dieses
        # Tests verbot „Antwort" und schlug auf diesen Spruch an.)
        refute spruch =~ ~r/gefunden|fertig|erledigt|Treffer|abgeschlossen/iu, spruch
      end
    end

    test "der Wechsel ist lang genug zum Lesen und kurz genug als Lebenszeichen" do
      assert Warten.wechsel_ms() >= 1_500
      assert Warten.wechsel_ms() <= 5_000
    end
  end

  describe "Quelltext-Wächter" do
    @fenster "lib/hub_web/live/campaign_live/frag_fenster.ex"
    @hook "assets/js/hooks/frag_fenster.js"
    @live "lib/hub_web/live/campaign_live.ex"
    @warten "assets/js/hooks/frag_warten.js"

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

      assert code =~ ~s|JS.ignore_attributes(["open", "style"])|,
             "beide Namen sind nötig: `open` hält das Fenster offen, `style` hält es an seinem Platz"

      # Am DIALOG wäre `phx-update="ignore"` falsch — es fröre den Inhalt ein
      # und die Antwort erschiene nie. Am Wartetext ist es dagegen richtig
      # (der Hook schreibt dort, und jeder Konsolen-Schritt ist ein Diff), also
      # wird gezielt das Dialog-Tag geprüft, nicht die Datei.
      refute dialog_tag(code) =~ ~s|phx-update="ignore"|,
             "das fröre den Inhalt des Fensters ein — die Antwort erschiene nie"
    end

    test "die CampaignLive hat eine Klausel für den Timer-Tick (sie hat keinen Auffangzweig)" do
      assert File.read!(@live) =~ "def handle_info({:frag_schritt,"
    end

    test "der Hook speichert keine Position, die nicht vom Betrachter stammt" do
      # Sonst schreibt der ResizeObserver die zurückgesetzte Lage nach
      # localStorage und der Sprung überlebt das Neuladen.
      js = nur_code(@hook, "//")
      assert js =~ "if (!this.el.style.left || !this.el.open) return;"
    end

    test "das Eingabefeld wird nicht bei jedem Tastendruck zum Server geschickt" do
      refute nur_code(@fenster, "#") =~ "phx-change",
             "ein Event je Tastendruck ist die #1200-Klasse — und jedes davon ein Diff am Fenster"
    end

    test "der Spinner ist kein Würfel" do
      # Ein Würfel sagt „Zufall" — das Gegenteil dessen, was die Fußzeile des
      # Fensters verspricht (nur geprüfte Fakten, mit Beleg).
      js = nur_code(@warten, "//")
      assert js =~ "⠋", "der Braille-Spinner fehlt"
      # Das `u` ist Pflicht: Ohne Unicode-Modus vergleicht die Zeichenklasse
      # BYTES, und die UTF-8-Sequenzen von Würfeln (U+26xx) und Braille (U+28xx)
      # teilen sich Präfixe — der Wächter schlug auf seinen eigenen Spinner an.
      refute js =~ ~r/[⚀⚁⚂⚃⚄⚅]/u, "ein Würfel widerspricht der Zusage des Fensters"
    end

    test "der Wartetext dreht im Browser, nicht über den Server" do
      assert nur_code(@warten, "//") =~ "setInterval"

      refute nur_code(@fenster, "#") =~ "warte_tick",
             "ein Server-Timer je Textwechsel wären ~50 Diffs pro Lauf (#1200-Klasse)"
    end

    test "ein zweiter Lauf bricht den Timer des ersten ab" do
      assert nur_code(@fenster, "#") =~ "Process.cancel_timer"
    end

    # Der öffnende `<dialog …>`-Tag allein — Attribute, die nur dort falsch
    # wären, lassen sich sonst nicht von denen der Kinder unterscheiden.
    defp dialog_tag(code) do
      case String.split(code, "<dialog", parts: 2) do
        [_, rest] -> rest |> String.split(">", parts: 2) |> hd()
        _ -> ""
      end
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
