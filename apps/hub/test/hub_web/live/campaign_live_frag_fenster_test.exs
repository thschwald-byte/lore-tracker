defmodule HubWeb.CampaignLiveFragFensterTest do
  @moduledoc """
  Issue #850: das Frag-Fenster, seit S3 am echten Lauf.

  Zwei Sorten Prüfung, und die zweite ist die wichtigere. Der Verhaltensteil
  hält fest, was aus der Antwort des Workers im Fenster wird.
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

  # Ein Socket, wie ihn die CampaignLive hält — mehr braucht `antwort/2` nicht.
  defp socket(frag, fakten \\ []) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, frag: frag, facts: fakten}
    }
  end

  defp lauf(id), do: %{FragFenster.initial() | lauf: %{id: id}, offen?: true}

  defp antwort_payload(id, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "frage_antwort",
        "frage_lauf_id" => id,
        "text" => "Die Antwort.",
        "kurze_ids" => ["S1-F1"],
        "fakt_ids" => ["f_eins"],
        "geprueft" => "gestuetzt"
      },
      extra
    )
  end

  describe "Zustand" do
    test "initial/0 liefert alle Felder, die eine Klausel später schreibt (#1005)" do
      f = FragFenster.initial()

      for schluessel <- [:offen?, :verlauf, :lauf, :frage, :befunde] do
        assert Map.has_key?(f, schluessel), "#{schluessel} fehlt im Anfangszustand"
      end

      assert f.lauf == nil
      assert f.verlauf == []
    end

    test "es gibt Beispielfragen, und keine verspricht ein Ergebnis" do
      assert length(FragFenster.vorschlaege()) > 0

      for v <- FragFenster.vorschlaege() do
        assert String.ends_with?(v, "?"), "#{inspect(v)} ist keine Frage"
      end
    end
  end

  describe "die Antwort des Workers wird zum Verlaufseintrag" do
    test "Text, Belege und Prüfurteil kommen an" do
      {:noreply, s} = FragFenster.antwort(socket(lauf("l1")), antwort_payload("l1"))

      assert [%{art: :antwort} = e] = s.assigns.frag.verlauf
      assert e.text == "Die Antwort."
      assert e.geprueft == "gestuetzt"
      assert [%{kurz: "S1-F1", fakt_id: "f_eins"}] = e.belege
      assert s.assigns.frag.lauf == nil, "der Lauf ist beendet"
    end

    test "ein Fehler wird als Fehler gezeigt, nicht als Antwort" do
      {:noreply, s} =
        FragFenster.antwort(
          socket(lauf("l1")),
          %{"kind" => "frage_fehler", "frage_lauf_id" => "l1", "grund" => "Kein Worker da."}
        )

      assert [%{art: :fehler, text: "Kein Worker da."}] = s.assigns.frag.verlauf
      assert s.assigns.frag.lauf == nil
    end

    test "eine Antwort auf einen überholten Lauf wird verworfen" do
      # Wer eine zweite Frage stellt, während die erste rechnet, will die
      # zweite. Ohne diese Prüfung erschiene die alte Antwort darunter.
      {:noreply, s} = FragFenster.antwort(socket(lauf("neu")), antwort_payload("alt"))

      assert s.assigns.frag.verlauf == []
      assert s.assigns.frag.lauf == %{id: "neu"}
    end
  end

  describe "Belege springen nur, wo es ein Ziel gibt" do
    test "mit geladenem Fakt trägt der Beleg eine Utterance-ID" do
      fakten = [%{"id" => "f_eins", "quell_utterance_ids" => ["u-7", "u-8"]}]
      {:noreply, s} = FragFenster.antwort(socket(lauf("l1"), fakten), antwort_payload("l1"))

      assert [%{utterance_id: "u-7"}] = hd(s.assigns.frag.verlauf).belege
    end

    test "ohne geladene Fakten bleibt das Ziel leer — der Knopf führt nicht ins Nichts" do
      {:noreply, s} = FragFenster.antwort(socket(lauf("l1")), antwort_payload("l1"))

      assert [%{utterance_id: nil, kurz: "S1-F1"}] = hd(s.assigns.frag.verlauf).belege
    end

    test "ein Fakt ohne Quellen taugt nicht als Sprungziel" do
      fakten = [%{"id" => "f_eins", "quell_utterance_ids" => []}]
      {:noreply, s} = FragFenster.antwort(socket(lauf("l1"), fakten), antwort_payload("l1"))

      assert [%{utterance_id: nil}] = hd(s.assigns.frag.verlauf).belege
    end

    test "eine Antwort ohne Belege hat eine leere Liste, keine erfundene" do
      p =
        antwort_payload("l1", %{"kurze_ids" => [], "fakt_ids" => [], "geprueft" => "ohne_beleg"})

      {:noreply, s} = FragFenster.antwort(socket(lauf("l1")), p)

      assert hd(s.assigns.frag.verlauf).belege == []
      assert hd(s.assigns.frag.verlauf).geprueft == "ohne_beleg"
    end
  end

  describe "der Denkstrom geht NICHT in die Assigns (#1146)" do
    test "ein Strom-Stück wird gepusht, nicht im Verlauf abgelegt" do
      {:noreply, s} =
        FragFenster.antwort(socket(lauf("l1")), %{
          "kind" => "frage_strom",
          "frage_lauf_id" => "l1",
          "stuecke" => [%{"art" => "denken", "text" => "Ich überlege."}]
        })

      # Über einen Lauf sammeln sich Tausende Token. In den Assigns würde das
      # bei jedem Diff kopiert und gehalten.
      # Geprüft wird die ZUSAGE (nichts landet im Verlauf), nicht die innere
      # Form von `push_event` — ein Test, der die nachbaut, bricht beim
      # nächsten LiveView-Update, ohne dass sich etwas geändert hat (#1149).
      # Dass gepusht wird, hält der Quelltext-Wächter fest.
      assert s.assigns.frag.verlauf == []
      assert s.assigns.frag.lauf == %{id: "l1"}
    end

    test "ein Strom zu einem überholten Lauf wird verworfen" do
      {:noreply, s} =
        FragFenster.antwort(socket(lauf("neu")), %{
          "kind" => "frage_strom",
          "frage_lauf_id" => "alt",
          "stuecke" => [%{"art" => "denken", "text" => "x"}]
        })

      assert s.assigns.frag.verlauf == []
    end
  end

  describe "das Prüfurteil reist mit — und wird unterschieden" do
    test "alle vier Zustände kommen unverändert im Eintrag an" do
      # „gestützt" und „nur die IDs geprüft" dürfen nicht dasselbe anzeigen:
      # Am Messlauf vom 25.09.2026 kam eine Antwort mit echten IDs durch,
      # deren Aussage in den Fakten nicht stand.
      for zustand <- ~w(gestuetzt nicht_gestuetzt ohne_beleg ungeprueft) do
        {:noreply, s} =
          FragFenster.antwort(socket(lauf("l1")), antwort_payload("l1", %{"geprueft" => zustand}))

        assert hd(s.assigns.frag.verlauf).geprueft == zustand
      end
    end

    test "der Grund einer bemängelten Stützung geht nicht verloren" do
      p =
        antwort_payload("l1", %{"geprueft" => "nicht_gestuetzt", "grund" => "X steht nicht da."})

      {:noreply, s} = FragFenster.antwort(socket(lauf("l1")), p)

      assert hd(s.assigns.frag.verlauf).grund == "X steht nicht da."
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

    test "der Denkstrom geht per push_event, nicht über die Assigns" do
      code = nur_code(@fenster, "#")

      assert code =~ ~s|push_event(socket, "frag_strom"|,
             "ohne push_event wüchse der Strom in den Socket (#1146)"

      assert nur_code(@fenster, "#") =~ ~s|phx-update="ignore"|,
             "ohne das leert morphdom den Strom beim nächsten Diff"
    end

    test "der Lauf wird VOR dem Fragen abonniert" do
      # Sonst kann die Antwort vor dem Abonnement eintreffen und ins Leere
      # laufen — bei 30 Sekunden Laufzeit selten, aber nicht nie.
      code = nur_code(@fenster, "#")
      [vor, _] = String.split(code, "Commands.request_frage", parts: 2)

      assert vor =~ "PipelineStatus.subscribe_frage",
             "abonniert wird nach dem Fragen — die Antwort kann dann ins Leere laufen"
    end

    test "ein zweiter Lauf bricht den ersten beim Worker ab" do
      # Nur zu vergessen reicht nicht: Der Lauf hielte die Grafikkarte für
      # eine Antwort, die niemand mehr sehen will.
      assert nur_code(@fenster, "#") =~ "Commands.abbrechen_frage"
    end

    test "die Antwort geht auf den Lauf-Topic, nicht auf den der Kampagne" do
      # Fragt der Spielleiter „was plant der Schurke", läse auf dem
      # Kampagnen-Topic die ganze Runde mit (#850, S2).
      code = File.read!("lib/hub_web/pipeline_status.ex")
      assert code =~ "def frage_topic("

      [_, route] = String.split(code, "def route(", parts: 2)
      assert route =~ ~s|"frage_lauf_id"|, "route/1 kennt die Lauf-ID nicht"
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
      # Das `reverse` ist nicht Kosmetik: Ohne es kommt der Code RÜCKWÄRTS
      # heraus (die Reduce sammelt mit `[z | acc]`). Solange jeder Wächter nur
      # auf Vorkommen prüft, fällt das nicht auf — der erste, der eine
      # REIHENFOLGE prüft, misst dann das Gegenteil.
      |> Enum.reverse()
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
