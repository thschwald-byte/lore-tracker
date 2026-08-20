Code.require_file(Path.expand("../../../../tools/credo/module_too_long.ex", __DIR__))

{:ok, _} = Application.ensure_all_started(:credo)

defmodule LoreTracker.Credo.Check.ModuleTooLongTest do
  @moduledoc """
  Issue #544: God-Module-Check (#544-Headline). Threshold via `:max_lines`.

  Issue #1097: gezählt werden CODE-Zeilen — Leerzeilen, `#`-Kommentare und
  Doku-Heredocs zählen nicht mit. Die Tests hier prüfen beides getrennt: die
  Zählung selbst (`code_lines/1`, ohne Credo-Fixture) und ihr Zusammenspiel
  mit der Ratsche für Bestandsdateien.
  """
  use Credo.Test.Case

  alias LoreTracker.Credo.Check.ModuleTooLong

  @src "apps/worker/lib/worker/foo.ex"

  defp source(n_lines) do
    body = Enum.map_join(1..n_lines, "\n", fn i -> "  def f#{i}, do: #{i}" end)
    "defmodule Worker.Foo do\n#{body}\nend\n"
  end

  describe "Zeilen-Schwelle" do
    test "Positiv: File über :max_lines wird geflaggt" do
      source(30)
      |> to_source_file(@src)
      |> run_check(ModuleTooLong, max_lines: 10)
      |> assert_issue(fn i -> assert i.trigger == "defmodule" end)
    end

    test "Negativ: File unter :max_lines bleibt still" do
      source(5)
      |> to_source_file(@src)
      |> run_check(ModuleTooLong, max_lines: 10)
      |> refute_issues()
    end

    test "Default-Threshold (600 Code-Zeilen): ein kleines File bleibt still" do
      source(20)
      |> to_source_file(@src)
      |> run_check(ModuleTooLong)
      |> refute_issues()
    end
  end

  describe "code_lines/1 — was NICHT zählt (#1097)" do
    test "Leerzeilen zählen nicht" do
      assert ModuleTooLong.code_lines(["def a, do: 1", "", "   ", "def b, do: 2"]) == 2
    end

    test "#-Kommentare zählen nicht, auch eingerückt" do
      lines = ["# oben", "def a, do: 1", "    # eingerückt", "def b, do: 2"]
      assert ModuleTooLong.code_lines(lines) == 2
    end

    test "@moduledoc-Heredoc zählt nicht, samt Inhalt und Begrenzern" do
      lines = [
        "defmodule X do",
        ~s(  @moduledoc """),
        "  Eine lange Begründung,",
        "  die mehrere Zeilen braucht.",
        ~s(  """),
        "  def a, do: 1",
        "end"
      ]

      # defmodule + def + end = 3
      assert ModuleTooLong.code_lines(lines) == 3
    end

    test "@doc, @typedoc und @shortdoc ebenso" do
      for attr <- ~w(doc typedoc shortdoc) do
        lines = [~s(  @#{attr} """), "  Text", ~s(  """), "  def a, do: 1"]
        assert ModuleTooLong.code_lines(lines) == 1, "@#{attr} wurde mitgezählt"
      end
    end

    test "einzeilige Doku-Attribute zählen nicht" do
      lines = [~s(  @doc false), ~s(  @moduledoc "kurz"), "  def a, do: 1"]
      assert ModuleTooLong.code_lines(lines) == 1
    end

    test "ein normaler Heredoc-String IST Code — nur Doku-Attribute zählen nicht" do
      lines = [~s(  text = """), "  Hallo", ~s(  """), "  def a, do: 1"]
      assert ModuleTooLong.code_lines(lines) == 4
    end

    test "Credos {lineno, text}-Form wird genauso gezählt wie rohe Strings" do
      roh = ["def a, do: 1", "", "# x"]
      mit_nr = Enum.with_index(roh, fn t, i -> {i + 1, t} end)
      assert ModuleTooLong.code_lines(mit_nr) == ModuleTooLong.code_lines(roh)
    end

    test "eine Datei aus reiner Doku hat null Code-Zeilen" do
      lines = [~s(@moduledoc """), "nur Text", ~s(""" ) |> String.trim()]
      assert ModuleTooLong.code_lines(lines) == 0
    end
  end

  describe "Ratsche für Bestandsdateien (#1097)" do
    @bestand [{@src, 25}]

    # source(n) erzeugt n defs + defmodule + end = n + 2 Code-Zeilen.
    test "Bestandsdatei darf ihren eingetragenen Stand halten" do
      source(23)
      |> to_source_file(@src)
      |> run_check(ModuleTooLong, max_lines: 10, bestand: @bestand)
      |> refute_issues()
    end

    test "eine Zeile mehr als eingetragen wird rot" do
      source(24)
      |> to_source_file(@src)
      |> run_check(ModuleTooLong, max_lines: 10, bestand: @bestand)
      |> assert_issue()
    end

    test "andere Dateien bleiben an der regulären Grenze" do
      source(30)
      |> to_source_file("apps/worker/lib/worker/bar.ex")
      |> run_check(ModuleTooLong, max_lines: 10, bestand: @bestand)
      |> assert_issue()
    end

    test "grenze_fuer/3: Eintrag unter max_lines wird ignoriert, nie verschärft" do
      # Sonst gatete ein alter Eintrag eine Datei strenger als die reguläre
      # Grenze — eine Regel, die niemand gelesen hat.
      assert ModuleTooLong.grenze_fuer("a.ex", [{"a.ex", 100}], 600) == 600
      assert ModuleTooLong.grenze_fuer("a.ex", [{"a.ex", 700}], 600) == 700
      assert ModuleTooLong.grenze_fuer("b.ex", [{"a.ex", 700}], 600) == 600
      assert ModuleTooLong.grenze_fuer("a.ex", [], 600) == 600
      assert ModuleTooLong.grenze_fuer("a.ex", nil, 600) == 600
    end
  end

  describe "die Bestandsliste in .credo.exs" do
    # Ohne diesen Wächter wird die Liste zur Müllhalde: ein Eintrag, dessen
    # Datei längst geschrumpft ist, fällt niemandem auf — er sieht aus wie
    # eine Regel, ist aber nur noch Altlast. Und ein zu hoch gesetzter Eintrag
    # gäbe einer Datei stillschweigend Wachstum frei, das niemand beschlossen
    # hat.
    setup do
      {config, _} = Code.eval_file(Path.expand("../../../../.credo.exs", __DIR__))

      bestand =
        config
        |> Map.fetch!(:configs)
        |> hd()
        |> Map.fetch!(:checks)
        |> Enum.find_value([], fn
          {ModuleTooLong, opts} -> Keyword.get(opts, :bestand, [])
          _ -> nil
        end)

      # Ohne Einträge wären die beiden Tests darunter stumm grün — das wäre
      # genau die Sorte Wächter, die nichts bewacht.
      assert bestand != [], "Bestandsliste in .credo.exs nicht gefunden"

      {:ok, bestand: bestand, root: Path.expand("../../../..", __DIR__)}
    end

    test "jeder Eintrag zeigt auf eine existierende Datei", %{bestand: b, root: root} do
      for {pfad, _} <- b do
        assert File.exists?(Path.join(root, pfad)), "Bestands-Eintrag ohne Datei: #{pfad}"
      end
    end

    test "kein Eintrag ist überflüssig oder zu großzügig", %{bestand: b, root: root} do
      for {pfad, erlaubt} <- b do
        ist =
          Path.join(root, pfad)
          |> File.read!()
          |> String.split("\n")
          |> ModuleTooLong.code_lines()

        assert ist > 600,
               "#{pfad} hat nur #{ist} Code-Zeilen — der Bestands-Eintrag ist überflüssig " <>
                 "und gehört ersatzlos aus .credo.exs entfernt (#1097)."

        assert erlaubt == ist,
               "#{pfad}: Eintrag sagt #{erlaubt}, tatsächlich #{ist}. Die Ratsche muss auf " <>
                 "dem Ist-Stand stehen — ein höherer Wert gäbe stillschweigend Wachstum frei, " <>
                 "ein niedrigerer wäre bereits rot."
      end
    end
  end
end
