defmodule Worker.Agent.MahnungTest do
  @moduledoc """
  #1247: **sammeln, bis es knapp wird — dann mahnen, dann auf Freigabe
  kompaktieren.**

  Maintainer, 25.09.2026: „so dass er sammeln kann bis es knapp wird und dann
  sagen wir — ‚jetzt aber mal schreiben' — und ihm evtl ein Werkzeug geben ‚ich
  habe geschrieben, jetzt kompaktieren'."

  Der Anlass: Auf seattleV5 S2 (3385 Zeilen) las der Zeit-Jack den ganzen
  Mitschnitt, sicherte nichts, und die Laufzeit fasste **mitten in seiner
  Arbeit** zusammen. Das Gelesene war fort, er begann von vorn — 90
  Leseaufrufe, eine Notiz, zwei Kompaktierungen, kein Fortschritt.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.{Lauf, Werkzeug}

  defmodule Stub do
    @moduledoc false
    def antworten(_n, _w, opts) do
      pid = Keyword.fetch!(opts, :skript)

      case Agent.get_and_update(pid, fn [h | t] -> {h, t} end) do
        %{} = a -> {:ok, a}
        other -> other
      end
    end
  end

  defp antwort(felder),
    do:
      Map.merge(
        %{text: nil, denken: nil, aufrufe: [], stopp: :stop, nutzung: nil},
        Map.new(felder)
      )

  defp aufruf(name), do: %{id: "id_#{name}", name: name, argumente: {:ok, %{}}}

  defp merk do
    Werkzeug.neu(
      name: "merk",
      beschreibung: "merkt etwas",
      parameter: %{"type" => "object"},
      ausfuehren: fn _ -> {:ok, "gemerkt"} end
    )
  end

  defp laufen(skript, opts) do
    {:ok, pid} = Agent.start_link(fn -> skript end)

    [
      modell: {Stub, skript: pid},
      system: "SYSTEM",
      nachrichten: [%{role: :user, content: "AUFTRAG"}],
      werkzeuge: [merk(), Worker.Jack.Resuemee.Werkzeuge.freigabe()],
      beobachter: self()
    ]
    |> Keyword.merge(opts)
    |> Worker.Agent.laufen()
  end

  # **Gezählt wird über den Beobachter, nicht über `bericht.nachrichten`** —
  # ein Fund beim Schreiben dieses Tests: Der Verlauf ist nicht das Protokoll.
  # Die Kompaktierung schneidet ältere Nachrichten weg, also genau die
  # Mahnung, die man nachweisen will; der erste Wurf sah deshalb eine
  # Mahnung, wo zwei waren.
  defp mahnungen do
    empfangen()
    |> Enum.filter(&(&1["ereignis"] == "mahnung"))
  end

  defp empfangen(gesammelt \\ []) do
    receive do
      {:agent, daten} -> empfangen([daten | gesammelt])
    after
      0 -> Enum.reverse(gesammelt)
    end
  end

  # Ein Fenster, das die Mahnschwelle (75 %) erreicht, aber die harte Grenze
  # (fenster - reserve) noch nicht: So wird geprüft, dass die Mahnung VOR der
  # Zwangs-Kompaktierung kommt — das ist der ganze Sinn.
  defp eng, do: [fenster: 100, reserve: 5, behalten: 20, zusammenfassen: fn _ -> "STAND" end]

  defp tool_texte(bericht),
    do: bericht.nachrichten |> Enum.filter(&(&1.role == :tool)) |> Enum.map(& &1.content)

  describe "die Mahnung" do
    test "kommt am Werkzeug-Ergebnis, sobald es knapp wird" do
      # Am Ergebnis, nicht als eigener Zug: Ein `:user`-Zug dazwischen sähe aus,
      # als spräche der Tisch.
      {:ok, b} =
        laufen(
          [
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 80, ausgabe: 2}),
            antwort(text: "fertig")
          ],
          kontext: eng()
        )

      assert [text] = tool_texte(b)
      assert text =~ "gemerkt"
      assert text =~ "Sichere"
      assert text =~ "jetzt_kompaktieren"
      assert [%{"prozent" => p}] = mahnungen()
      assert p >= 75
    end

    test "bleibt aus, solange Platz ist" do
      {:ok, b} =
        laufen(
          [
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 10, ausgabe: 2}),
            antwort(text: "fertig")
          ],
          kontext: eng()
        )

      assert [text] = tool_texte(b)
      refute text =~ "Sichere"
      assert mahnungen() == []
    end

    test "und kommt nur EINMAL, nicht in jeder Runde" do
      # Sonst lernt das Modell, sie zu überlesen — dieselbe Erfahrung wie bei
      # jeder Warnung, die zu oft erscheint.
      {:ok, b} =
        laufen(
          [
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 80, ausgabe: 2}),
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 85, ausgabe: 2}),
            antwort(text: "fertig")
          ],
          kontext: eng()
        )

      assert length(mahnungen()) == 1
      assert Enum.count(tool_texte(b), &String.contains?(&1, "Sichere")) == 1
    end

    test "ohne Kontext-Verwaltung passiert nichts" do
      {:ok, b} =
        laufen([antwort(aufrufe: [aufruf("merk")]), antwort(text: "fertig")], [])

      assert [text] = tool_texte(b)
      refute text =~ "Sichere"
      assert mahnungen() == []
    end
  end

  describe "die Freigabe" do
    test "kompaktiert sofort, auch unter der harten Grenze" do
      # Der Sinn: Das Modell hat gerade gesichert — jetzt ist der günstige
      # Moment, nicht irgendwann mitten in der nächsten Leserunde.
      {:ok, b} =
        laufen(
          [
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 80, ausgabe: 2}),
            antwort(aufrufe: [aufruf("jetzt_kompaktieren")], nutzung: %{eingabe: 82, ausgabe: 2}),
            antwort(text: "fertig")
          ],
          kontext: eng()
        )

      assert b.kompaktierungen >= 1
    end

    test "und erlaubt danach eine neue Mahnung" do
      # Nach der Zusammenfassung ist wieder Platz; wird es erneut knapp, muss
      # die Laufzeit erneut mahnen dürfen.
      {:ok, b} =
        laufen(
          [
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 80, ausgabe: 2}),
            antwort(aufrufe: [aufruf("jetzt_kompaktieren")], nutzung: %{eingabe: 82, ausgabe: 2}),
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 90, ausgabe: 2}),
            antwort(text: "fertig")
          ],
          kontext: eng()
        )

      assert b.kompaktierungen >= 1
      assert length(mahnungen()) == 2, "nach der Freigabe muss erneut gemahnt werden können"
    end

    test "das Werkzeug antwortet, ohne etwas zu behaupten" do
      # Es sagt, was passiert — und ausdrücklich, dass Eingetragenes bleibt.
      w = Worker.Jack.Resuemee.Werkzeuge.freigabe()
      assert w.name == Lauf.kompakt_werkzeug()
      assert {:ok, text} = w.ausfuehren.(%{})
      assert text =~ "eingetragen"
    end
  end

  describe "die harte Grenze bleibt" do
    test "ein Modell, das nie freigibt, wird trotzdem kompaktiert" do
      # Ohne das hinge der Lauf an einer Höflichkeit.
      {:ok, b} =
        laufen(
          [
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 200, ausgabe: 10}),
            antwort(aufrufe: [aufruf("merk")], nutzung: %{eingabe: 200, ausgabe: 10}),
            antwort(text: "fertig")
          ],
          kontext: eng()
        )

      assert b.kompaktierungen >= 1
    end
  end
end
