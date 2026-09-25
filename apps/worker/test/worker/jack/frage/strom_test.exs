defmodule Worker.Jack.Frage.StromTest do
  @moduledoc """
  Issue #850: der Denkstrom ins Fenster (Maintainer, 25.09.2026).

  Die beiden Zusagen, die hier hängen: Er ist **gedrosselt** (ein Stück je
  Token wären Tausende Nachrichten durch Hub und PubSub), und er trägt **nicht
  die Werkzeug-Ergebnisse** — die stehen schon in der Kampagne, sie ein
  zweites Mal zu übertragen wäre die #1146-Klasse.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Frage.Strom

  defp sammler do
    eltern = self()
    Strom.starten("lauf-1", &send(eltern, &1))
  end

  defp agent(pid, daten), do: send(pid, {:agent, daten})

  defp delta(text),
    do: %{"ereignis" => "delta", "art" => "denken", "text" => text}

  describe "Denken" do
    test "wird zusammengeklebt, nicht Token für Token geschickt" do
      p = sammler()
      for t <- ["Ich ", "denke ", "nach."], do: agent(p, delta(t))
      Strom.beenden(p)

      assert_receive {:frage_strom, "lauf-1", [%{art: "denken", text: "Ich denke nach."}]}, 2000
    end

    test "ohne Inhalt wird nichts gemeldet" do
      p = sammler()
      Strom.beenden(p)

      refute_receive {:frage_strom, _, _}, 300
    end
  end

  describe "Werkzeuge" do
    test "Name und Argumente kommen durch, gekürzt" do
      p = sammler()

      agent(p, %{
        "ereignis" => "antwort",
        "aufrufe" => [%{"name" => "suche_bisher", "argumente" => %{"begriff" => "Karaoke"}}]
      })

      Strom.beenden(p)

      assert_receive {:frage_strom, _, [%{art: "werkzeug", text: t}]}, 2000
      assert t =~ "suche_bisher"
      assert t =~ "Karaoke"
    end

    test "ein langes Argument wird abgeschnitten" do
      p = sammler()
      lang = String.duplicate("x", 300)

      agent(p, %{
        "ereignis" => "antwort",
        "aufrufe" => [%{"name" => "n", "argumente" => %{"a" => lang}}]
      })

      Strom.beenden(p)

      assert_receive {:frage_strom, _, [%{text: t}]}, 2000
      assert String.length(t) < 120, "ein Aufruf darf das Fenster nicht fluten"
      assert t =~ "…"
    end

    test "eine Liste reist als Zahl, nicht als Inhalt" do
      p = sammler()

      agent(p, %{
        "ereignis" => "antwort",
        "aufrufe" => [%{"name" => "antworte", "argumente" => %{"fakt_ids" => ["a", "b", "c"]}}]
      })

      Strom.beenden(p)

      assert_receive {:frage_strom, _, [%{text: t}]}, 2000
      assert t =~ "[3]"
    end
  end

  describe "Werkzeug-Ergebnisse bleiben draußen" do
    test "vom Ergebnis reist nur die Größe" do
      p = sammler()
      inhalt = Enum.map_join(1..50, "\n", &"Zeile #{&1} mit Inhalt")
      agent(p, %{"ereignis" => "ergebnis", "ergebnis" => inhalt})
      Strom.beenden(p)

      assert_receive {:frage_strom, _, [%{art: "ergebnis", text: t}]}, 2000
      assert t == "50 Zeilen"
      refute t =~ "Inhalt", "der Inhalt steht schon in der Kampagne (#1146)"
    end
  end

  describe "Drosselung" do
    test "mehrere Token in einem Takt ergeben EINE Nachricht" do
      p = sammler()
      for i <- 1..200, do: agent(p, delta("#{i} "))
      Strom.beenden(p)

      assert_receive {:frage_strom, _, [%{art: "denken", text: t}]}, 2000
      assert t =~ "1 "
      assert t =~ "200 "
      refute_receive {:frage_strom, _, _}, 300
    end
  end

  describe "Unbekanntes" do
    test "ein Ereignis, das der Strom nicht kennt, wird verworfen statt zu stören" do
      p = sammler()
      agent(p, %{"ereignis" => "kompaktierung", "was" => "egal"})
      agent(p, delta("Text"))
      Strom.beenden(p)

      assert_receive {:frage_strom, _, [%{art: "denken", text: "Text"}]}, 2000
    end
  end
end
