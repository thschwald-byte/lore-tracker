defmodule Worker.Repo.ZeitSchluesselTest do
  @moduledoc """
  #1247: **eine String-Whitelist erzeugt keine Atome.**

  Am 25.09.2026 an einem frisch gestarteten Stage-Worker aufgeschlagen:
  `Worker.Repo.Zeit.anker/1` warf `:badarg` in
  `binary_to_existing_atom("beleg")`, und damit fiel der EINZIGE Leser der
  Anker aus — für den Zeit-Jack und für die Zeitlinie der Chronik (Z3). Die
  Absicherung trug sich selbst nicht: Die erlaubten Schlüssel standen als
  Strings da, und `String.to_existing_atom/1` gelingt nur, wenn irgendein
  **geladenes** Modul dasselbe Atom literal nennt. Nach einem Neustart ist das
  Zufall. Dieselbe Klasse wie #646 (Materializer) und #611 (Hub-Icons).

  **Der Wächter liest den Quelltext, und das ist hier die tragende Hälfte.**
  Ein Verhaltenstest kann den Defekt nicht zeigen: In der Testumgebung ist die
  ganze Anwendung geladen, also existieren die Atome, und der alte Code war
  grün — `speicher_test.exs` liest seit dem 24.09. einen Anker mit `beleg`
  zurück und hat nichts gemerkt. Dieselbe Falle wie bei den Wächtern (s. „Ein
  Wächter, der nie anschlägt, ist unbewiesen").
  """
  use ExUnit.Case, async: true

  @quelle "apps/worker/lib/worker/repo/zeit.ex"

  defp quelltext do
    Path.join([__DIR__, "..", "..", "..", "..", ".."])
    |> Path.expand()
    |> Path.join(@quelle)
    |> File.read!()
  end

  test "die Schlüssel-Übersetzung nutzt kein to_existing_atom" do
    # Gesucht wird im CODE, nicht im Text — der Kommentar oben nennt die
    # Funktion absichtlich (er erklärt, warum sie weg ist).
    code =
      quelltext()
      |> String.split("\n")
      |> Enum.reject(&(String.trim_leading(&1) =~ ~r/^#/))
      |> Enum.join("\n")

    refute code =~ "to_existing_atom(",
           "#{@quelle}: Eine String-Whitelist garantiert nicht, dass die Atome existieren"
  end

  test "und die erlaubten Namen stehen als Atome da (~w(…)a)" do
    # Ohne das `a` entstehen die Atome nicht zur Compile-Zeit, und die Map
    # darunter könnte sie nicht bauen.
    assert quelltext() =~ ~r/@bekannt ~w\([^)]*\)a/s,
           "#{@quelle}: @bekannt muss eine Atom-Liste sein"
  end

  test "der Name, an dem es aufschlug, ist dabei" do
    # `beleg` trägt seit Z3 die Prüfpflicht der Chronik — fehlt er, gibt es
    # nichts nachzuprüfen.
    assert quelltext() =~ ~r/@bekannt ~w\([^)]*beleg[^)]*\)a/s
  end
end
