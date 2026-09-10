defmodule Worker.Agent.KontextTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Kontext

  defp modell(name, args), do: %{role: :assistant, content: nil, tool_calls: [aufruf(name, args)]}
  defp aufruf(name, args), do: %{id: "id_#{name}", name: name, argumente: {:ok, args}}

  defp ergebnis(text),
    do: %{role: :tool, tool_call_id: "x", name: "x", content: text, fehler: false}

  describe "schaetzen/1" do
    test "vier Zeichen je Token, aufgerundet" do
      assert Kontext.schaetzen(%{role: :user, content: "abcd"}) == 1
      assert Kontext.schaetzen(%{role: :user, content: "abcde"}) == 2
      assert Kontext.schaetzen(%{role: :assistant, content: nil, tool_calls: []}) == 0
    end

    test "Werkzeugaufrufe zählen mit Name und Argumenten als JSON" do
      # "echo" (4) + ~s({"t":"ab"}) (10) = 14 Zeichen → 4 Token
      assert Kontext.schaetzen(modell("echo", %{"t" => "ab"})) == 4
    end

    test "Argumente, die kein JSON waren, zählen roh" do
      n = %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "a", name: "ab", argumente: {:error, "xyzxyz"}}]
      }

      assert Kontext.schaetzen(n) == 2
    end
  end

  describe "tokens/3" do
    test "ohne Messung wird alles geschätzt, auch das Feste" do
      fest = [%{role: :system, content: "12345678"}]
      verlauf = [%{role: :user, content: "1234"}]
      assert Kontext.tokens(fest, verlauf, nil) == 3
    end

    test "mit Messung zählt nur, was seitdem angehängt wurde, geschätzt dazu" do
      verlauf = [%{role: :user, content: "egal"}, ergebnis("12345678")]
      assert Kontext.tokens([], verlauf, {1000, 1}) == 1002
    end
  end

  test "voll?/3 ab fenster − reserve" do
    refute Kontext.voll?(90, 100, 10)
    assert Kontext.voll?(91, 100, 10)
  end

  describe "schnitt/2" do
    test "nichts zu schneiden, wenn alles in behalten passt" do
      assert Kontext.schnitt([modell("a", %{}), ergebnis("x")], 1_000) == 0
      assert Kontext.schnitt([], 10) == 0
    end

    test "schneidet vor der jüngsten Runde, die behalten füllt — nie vor einem Ergebnis" do
      lang = String.duplicate("x", 40)

      verlauf = [
        modell("echo", %{"text" => lang}),
        ergebnis(lang),
        modell("echo", %{"text" => lang}),
        ergebnis(lang)
      ]

      assert Kontext.schnitt(verlauf, 20) == 2
      assert Enum.at(verlauf, 2).role == :assistant
    end

    test "Werkzeugergebnisse sind nie ein Schnittpunkt" do
      lang = String.duplicate("x", 400)
      verlauf = [%{role: :user, content: "a"}, modell("b", %{}), ergebnis(lang), ergebnis(lang)]

      i = Kontext.schnitt(verlauf, 50)
      assert Enum.at(verlauf, i).role in [:user, :assistant]
    end

    test "Abweichung von pi: ohne Schnittpunkt dahinter wird am letzten davor geschnitten" do
      # Das riesige Ergebnis ganz hinten füllt behalten allein. pi fände ab
      # dort keinen Schnittpunkt und behielte alles; hier fällt das Ältere weg.
      riesig = String.duplicate("x", 4_000)

      verlauf = [
        %{role: :user, content: "alt"},
        modell("a", %{}),
        ergebnis("kurz"),
        modell("b", %{}),
        ergebnis(riesig)
      ]

      assert Kontext.schnitt(verlauf, 100) == 3
    end
  end

  describe "standard_zusammenfassung/1" do
    test "zählt Nachrichten und Werkzeugaufrufe je Name" do
      weg = [
        modell("lies", %{}),
        ergebnis("x"),
        modell("lies", %{}),
        ergebnis("y"),
        modell("schreib", %{})
      ]

      assert Kontext.standard_zusammenfassung(%{weggefallen: weg, vorherige: nil}) ==
               "[Gekürzt: 5 ältere Nachrichten, 3 Werkzeugaufrufe (lies ×2, schreib ×1).]"
    end

    test "hängt an die vorherige Zusammenfassung an" do
      text = Kontext.standard_zusammenfassung(%{weggefallen: [ergebnis("x")], vorherige: "ALT"})
      assert text == "ALT\n\n[Gekürzt: 1 ältere Nachrichten, 0 Werkzeugaufrufe.]"
    end
  end
end
