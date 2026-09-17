defmodule Worker.Jack.BeispieleV1Test do
  # Die Fälle aus eves beispiele_test.mjs (pi, 11.09.) mit denselben
  # erwarteten Zeichenketten, gegen die echte beispiele_v1.md: so ist die
  # wörtliche Gleichheit von Port und Spike geprüft statt behauptet. Die Datei
  # liegt außerhalb des Repos — daher :jack_prod, per Default ausgeschlossen:
  #   mix test test/worker/jack/beispiele_v1_test.exs --include jack_prod
  use ExUnit.Case, async: true

  alias Worker.Jack.Beispiele

  @moduletag :jack_prod

  @pfad Path.expand("~/Projekte/.lore-messungen/1174-s1-extraktion/beispiele/beispiele_v1.md")
  @sha256 "dfb9123231535ff38cb52765c0fd5894a93d7c87e95d8cab7bff24bc203aaf12"

  setup_all do
    case File.read(@pfad) do
      {:ok, text} -> %{text: text}
      {:error, _} -> {:skip, "beispiele_v1.md fehlt: #{@pfad}"}
    end
  end

  defp txt({:ok, antwort}), do: Jason.encode!(antwort)

  defp satz(text) do
    {:ok, b} = Beispiele.lesen(text, @pfad)
    b
  end

  test "v1: Hash, Übersicht, Suche, Fehler, alle, beispiel(n)", %{text: text} do
    b = satz(text)
    assert b.sha256 == @sha256

    u = txt(Beispiele.beispiele(b, %{}))

    assert u =~
             ~r/^\{"regeln":".*","beispiele":\[.*\],"hinweis":"beispiel\(n\) zeigt ein Beispiel vollständig, beispiele\(alle: true\) alle\."\}$/s

    uo = Jason.decode!(u)
    assert String.starts_with?(uo["regeln"], "# Beispiele")
    refute uo["regeln"] |> String.trim_trailing() |> String.ends_with?("---")
    assert u =~ "Grundregel" and u =~ "ü"
    refute u =~ "\\u00"
    assert txt(Beispiele.beispiele(b, %{"alle" => false})) == u

    assert length(uo["beispiele"]) == 36
    assert u =~ ~s|"beispiele":[{"nummer":1,"klasse":"Regel","stichwort":"Edge verfällt"},|

    assert txt(Beispiele.beispiele(b, %{"suche" => "EDGE verfällt"})) ==
             ~s|{"suche":"EDGE verfällt","treffer":[{"nummer":1,"klasse":"Regel","stichwort":"Edge verfällt"}],"hinweis":"beispiel(n) zeigt ein Beispiel vollständig."}|

    s2 = b |> Beispiele.beispiele(%{"suche" => "schad"}) |> txt() |> Jason.decode!()
    nummern = Enum.map(s2["treffer"], & &1["nummer"])
    assert length(nummern) >= 3
    assert nummern == Enum.sort(nummern)

    assert txt(Beispiele.beispiele(b, %{"suche" => "xyzzy"})) ==
             ~s|{"suche":"xyzzy","treffer":[],"hinweis":"Kein Beispiel enthält „xyzzy“. beispiele() zeigt die Übersicht."}|

    assert txt(Beispiele.beispiele(b, %{"suche" => "   "})) == ~s|{"fehler":"suche ist leer."}|

    assert txt(Beispiele.beispiele(b, %{"suche" => "Edge", "alle" => true})) ==
             ~s|{"fehler":"Entweder suche oder alle, nicht beides."}|

    a = b |> Beispiele.beispiele(%{"alle" => true}) |> txt()
    assert a =~ ~r/^\{"regeln":/
    ao = Jason.decode!(a, objects: :ordered_objects)
    assert Enum.map(ao.values, &elem(&1, 0)) == ["regeln", "beispiele"]
    texte = for e <- ao["beispiele"], do: e["text"]
    assert length(texte) == 36
    assert String.starts_with?(hd(texte), "### Beispiel 1 · Regel · Edge verfällt\n")
    assert Enum.all?(texte, &(&1 == String.trim_trailing(&1)))

    b7 = txt(Beispiele.beispiel(b, 7))

    assert String.starts_with?(
             b7,
             ~s|{"nummer":7,"text":"### Beispiel 7 · gemischt · Verwundung mit Abzug\\n|
           )

    assert Jason.decode!(b7)["text"] =~ "Begründung:"

    assert txt(Beispiele.beispiel(b, 42)) ==
             ~s|{"fehler":"Beispiel 42 gibt es nicht, vorhanden sind 1–36."}|
  end

  test "entfallen (Beispiel 3 gestrichen): Übersicht, beispiel(3), alle, Suche, max", %{
    text: text
  } do
    kopf = ~r/^### Beispiel 3 · .*$/m
    assert Regex.match?(kopf, text)
    b = satz(Regex.replace(kopf, text, "### Beispiel 3 · entfallen", global: false))

    uo = b |> Beispiele.beispiele(%{}) |> txt() |> Jason.decode!()
    e = Enum.find(uo["beispiele"], &(&1["nummer"] == 3))

    assert Jason.encode!(
             Jason.OrderedObject.new(Enum.map(~w(nummer klasse stichwort), &{&1, e[&1]}))
           ) ==
             ~s|{"nummer":3,"klasse":"entfallen","stichwort":""}|

    assert txt(Beispiele.beispiel(b, 3)) == ~s|{"fehler":"Beispiel 3 ist entfallen."}|

    alle = b |> Beispiele.beispiele(%{"alle" => true}) |> txt() |> Jason.decode!()
    refute Enum.any?(alle["beispiele"], &(&1["nummer"] == 3))
    assert length(alle["beispiele"]) == 35

    s = b |> Beispiele.beispiele(%{"suche" => "entfallen"}) |> txt() |> Jason.decode!()
    refute Enum.any?(s["treffer"], &(&1["nummer"] == 3))

    assert txt(Beispiele.beispiel(b, 99)) ==
             ~s|{"fehler":"Beispiel 99 gibt es nicht, vorhanden sind 1–36."}|
  end

  test "doppelte Nummer und kaputte Kopfzeile scheitern laut beim Laden", %{text: text} do
    doppelt = String.replace(text, "### Beispiel 2 ·", "### Beispiel 1 ·", global: false)
    assert {:error, {:doppelte_nummer, [1]}} = Beispiele.lesen(doppelt)

    kaputt =
      String.replace(text, "### Beispiel 2 · Regel", "### Beispiel 2 · regel", global: false)

    assert {:error, {:unlesbare_kopfzeile, _}} = Beispiele.lesen(kaputt)
  end
end
