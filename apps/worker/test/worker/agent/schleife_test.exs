defmodule Worker.Agent.SchleifeTest do
  @moduledoc """
  #1247: die Wiederholung **innerhalb einer Antwort** — die Degeneration, die
  keine der bestehenden Sperren sah.

  Gemessen am laufenden Zeit-Jack (25.09.2026, seattleV5 S2): 52.962 Zeichen
  Denktext in EINER Runde, darin dreissigmal derselbe Absatz, elf Minuten
  Rechenzeit — und `wiederholungen: 0`, weil die Wiederholungssperre gleiche
  **Werkzeugaufrufe** zählt. Der Rundendeckel greift ebenso nicht: Die Runde
  ist eine.

  Die Sätze unten stammen wörtlich aus diesem Lauf.
  """
  use ExUnit.Case, async: true

  alias Worker.Agent.Modell.Schleife

  # Der echte Absatz, den das Modell dreissigmal geschrieben hat.
  @echt """
  Hmm. But Befunde 4-6 are clearly about my session (S2/S3 references). Befunde 1-3 might be about S1 anchors (which I can't fix — only melde_konflikt).

  Wait, but the Befund list is "die Rechnung" for the whole chain. Let me try to find the anchors. Maybe lies_kette shows more if I look at a specific node? The Befunde are listed globally at the bottom. Maybe I should read my session's lines around where times are mentioned.

  Let me read my session's game lines and find time expressions. Read 466-719, 720-1119, etc. in chunks of 80 lines. That's about 2600 lines... a lot but doable in chunks. Actually, maybe I should be smarter: Befunde are specific. Let me guess the anchors:
  """

  describe "pruefen/1 am echten Fall" do
    test "erkennt die dreifache Wiederholung des echten Absatzes" do
      assert {:schleife, _block, n} = Schleife.pruefen(String.duplicate(@echt, 3))
      assert n >= Schleife.mindestens()
    end

    test "und lässt zwei Vorkommen durch — eine Wiederholung ist noch keine Schleife" do
      # Ein Modell darf einen Gedanken zweimal fassen. Die Schwelle ist
      # bewusst grosszügig; dreissig Vorkommen sind der Fall, um den es geht.
      assert Schleife.pruefen(String.duplicate(@echt, 2)) == :weiter
    end

    test "langer Text ohne Wiederholung bleibt unberührt" do
      # **Abgebrochen wird wegen Wiederholung, nie wegen Länge** — ein langer
      # Denkstrom ist legitim.
      text = for i <- 1..400, into: "", do: "Gedanke Nummer #{i}: #{:erlang.unique_integer()} — "
      assert byte_size(text) > 10_000
      assert Schleife.pruefen(text) == :weiter
    end

    test "kurzer Text kann keine Schleife sein" do
      assert Schleife.pruefen("kurz") == :weiter
      assert Schleife.pruefen("") == :weiter
    end
  end

  describe "dazu/2 — der Strom" do
    test "prüft erst, wenn genug dazugekommen ist" do
      # Eine Teilstring-Suche über einen wachsenden Text ist billig, aber
      # nicht kostenlos: geprüft wird alle `intervall/0` Zeichen.
      {z, befund} = Schleife.dazu(Schleife.neu(), String.duplicate(@echt, 3))
      assert {:schleife, _, _} = befund
      assert byte_size(z.text) == byte_size(String.duplicate(@echt, 3))
    end

    test "stückweise gefüttert findet es dasselbe" do
      # So kommt es im Betrieb: Delta für Delta, in Stücken, die das Netz
      # schneidet.
      voll = String.duplicate(@echt, 4)

      {_z, befund} =
        voll
        |> String.graphemes()
        |> Enum.chunk_every(37)
        |> Enum.map(&Enum.join/1)
        |> Enum.reduce({Schleife.neu(), :weiter}, fn
          stueck, {z, :weiter} -> Schleife.dazu(z, stueck)
          _stueck, fertig -> fertig
        end)

      assert {:schleife, _block, n} = befund
      assert n >= Schleife.mindestens()
    end

    test "unter der Schwelle bleibt es bei :weiter" do
      {_z, befund} = Schleife.dazu(Schleife.neu(), "ein kurzer Gedanke")
      assert befund == :weiter
    end
  end

  describe "die Verdrahtung" do
    @quelle "apps/worker/lib/worker/agent/modell/ollama.ex"

    defp quelltext(pfad) do
      Path.join([__DIR__, "..", "..", "..", "..", ".."])
      |> Path.expand()
      |> Path.join(pfad)
      |> File.read!()
    end

    test "der Client streamt IMMER, nicht nur mit Beobachter" do
      # Der tragende Punkt: Der Strom war bis #1247 an `:bei_delta` gebunden,
      # und das setzt `Lauf` nur bei vorhandenem Beobachter (Laufsicht). Eine
      # Erkennung, die daran hängt, wäre genau die #1163-Klasse — ein
      # Wächter, der nur anschlägt, wenn ohnehin jemand hinsieht.
      quelle = quelltext(@quelle)
      refute quelle =~ "defp ganz(", "der nicht gestreamte Pfad ist toter Code"

      assert quelle =~ "gestreamt(nachrichten, werkzeuge, opts, Keyword.get(opts, :bei_delta))",
             "antworten/3 muss immer streamen; bei_delta ist nur die Meldung"
    end

    test "der Strom wird bei einer Schleife abgebrochen, nicht bloss gemeldet" do
      quelle = quelltext(@quelle)
      assert quelle =~ "{:halt,", "ohne :halt läuft das Modell bis max_tokens weiter"
      assert quelle =~ "Strom.abbrechen(strom, \"schleife\")"
      assert quelle =~ "Worker.Telemetry.zaehle(:modell_schleife)"
    end

    test "die Laufzeit verwirft die Aufrufe eines abgebrochenen Stroms" do
      # Ein abgebrochener Strom kann kein vollständiges Argument-JSON
      # garantieren; ein halber Aufruf ist schlimmer als keiner.
      quelle = quelltext("apps/worker/lib/worker/agent/lauf.ex")
      assert quelle =~ "defp nach_antwort(s, %{stopp: :schleife} = a)"
      assert quelle =~ "gestoppt(s, %{a | aufrufe: []})"
    end

    test "und das Nachhaken sagt, dass es nicht an den Angaben liegt" do
      assert {:weiter, text} =
               Worker.Jack.Phase.nachhaken(%{stopp: :schleife, ohne_aufruf_in_folge: 1})

      assert text =~ "wiederholt"
      assert text =~ "nicht weiter"
      assert text =~ "hilfe()"
      refute text =~ "Setz die Arbeit fort", "das ist der Text für den anderen Fall"
    end

    test "nach drei Anläufen endet der Lauf" do
      assert Worker.Jack.Phase.nachhaken(%{stopp: :schleife, ohne_aufruf_in_folge: 9}) == :fertig
    end

    test "das Signal ist bekannt und ab dem ersten Mal laut" do
      assert :modell_schleife in Worker.Telemetry.signale()
      assert Worker.Telemetry.schwellen()[:modell_schleife] == 1
    end
  end
end
