defmodule Worker.Agent.LaufTest do
  use ExUnit.Case, async: true

  alias Worker.Agent.Werkzeug

  # Ein Modell, das ein Skript abspielt. Jeder Eintrag ist eine Antwort-Map,
  # `{:error, grund}` oder eine Funktion ohne Argument, die eines davon
  # liefert. Jeder Aufruf meldet dem Test, was das Modell zu sehen bekam.
  defmodule Stub do
    @moduledoc false
    @behaviour Worker.Agent.Modell

    @impl true
    def antworten(nachrichten, werkzeuge, opts) do
      send(Keyword.fetch!(opts, :test), {:modell, nachrichten, Enum.map(werkzeuge, & &1.name)})

      naechste =
        Agent.get_and_update(Keyword.fetch!(opts, :skript), fn
          [kopf | rest] -> {kopf, rest}
          [] -> {:leer, []}
        end)

      case naechste do
        :leer -> raise "Stub-Skript erschöpft"
        f when is_function(f, 0) -> ausgeben(f.())
        x -> ausgeben(x)
      end
    end

    defp ausgeben({:error, _} = e), do: e
    defp ausgeben(%{} = a), do: {:ok, a}
  end

  defp antwort(felder \\ []),
    do:
      Map.merge(
        %{text: nil, denken: nil, aufrufe: [], stopp: :stop, nutzung: nil},
        Map.new(felder)
      )

  defp aufruf(name, args, id \\ nil),
    do: %{id: id || "id_#{name}", name: name, argumente: {:ok, args}}

  defp echo do
    Werkzeug.neu(
      name: "echo",
      beschreibung: "Gibt den Text zurück.",
      parameter: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      ausfuehren: fn %{"text" => t} ->
        send(self(), {:echo, t})
        {:ok, "echo: " <> t}
      end
    )
  end

  defp werkzeug(name, ausfuehren) do
    Werkzeug.neu(
      name: name,
      beschreibung: name,
      parameter: %{"type" => "object"},
      ausfuehren: ausfuehren
    )
  end

  defp laufen(skript, opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> skript end)

    [
      modell: {Stub, skript: pid, test: self()},
      system: "SYSTEM",
      nachrichten: [%{role: :user, content: "AUFTRAG"}],
      werkzeuge: [echo()]
    ]
    |> Keyword.merge(opts)
    |> Worker.Agent.laufen()
  end

  defp werkzeug_nachrichten(bericht), do: Enum.filter(bericht.nachrichten, &(&1.role == :tool))

  test "ohne Werkzeugaufruf endet der Lauf nach einer Runde" do
    assert {:ok, bericht} = laufen([antwort(text: "fertig")])
    assert %{ende: :fertig, runden: 1} = bericht

    assert_received {:modell,
                     [%{role: :system, content: "SYSTEM"}, %{role: :user, content: "AUFTRAG"}],
                     ["echo"]}
  end

  test "Werkzeugrunde: Ergebnis kommt mit der ID des Aufrufs zurück ans Modell" do
    assert {:ok, bericht} =
             laufen([
               antwort(stopp: :werkzeuge, aufrufe: [aufruf("echo", %{"text" => "hi"}, "a1")]),
               antwort()
             ])

    assert_received {:echo, "hi"}
    assert bericht.runden == 2

    assert [%{role: :tool, tool_call_id: "a1", name: "echo", content: "echo: hi", fehler: false}] =
             werkzeug_nachrichten(bericht)

    assert_received {:modell, _, _}
    assert_received {:modell, zweite_runde, _}
    assert [:system, :user, :assistant, :tool] = Enum.map(zweite_runde, & &1.role)
  end

  test "mehrere Aufrufe einer Antwort laufen nacheinander in ihrer Reihenfolge" do
    aufrufe = [aufruf("echo", %{"text" => "1"}, "a"), aufruf("echo", %{"text" => "2"}, "b")]
    assert {:ok, bericht} = laufen([antwort(aufrufe: aufrufe), antwort()])

    assert ["a", "b"] = bericht |> werkzeug_nachrichten() |> Enum.map(& &1.tool_call_id)
    assert_received {:echo, "1"}
    assert_received {:echo, "2"}
  end

  describe "Fehler werden Ergebnisse, keine Abstürze" do
    test "unbekanntes Werkzeug nennt die verfügbaren" do
      assert {:ok, bericht} = laufen([antwort(aufrufe: [aufruf("gibtsnicht", %{})]), antwort()])
      assert [%{fehler: true, content: text}] = werkzeug_nachrichten(bericht)
      assert text =~ ~s(Werkzeug "gibtsnicht" gibt es nicht)
      assert text =~ "Verfügbar: echo"
    end

    test "Argumente, die kein JSON-Objekt sind" do
      kaputt = %{id: "k", name: "echo", argumente: {:error, ~s({"text": "hal)}}
      assert {:ok, bericht} = laufen([antwort(aufrufe: [kaputt]), antwort()])
      assert [%{fehler: true, content: text}] = werkzeug_nachrichten(bericht)
      assert text =~ "kein JSON-Objekt"
      assert text =~ ~s({"text": "hal)
      refute_received {:echo, _}
    end

    test "Verstoß gegen das Schema: Werkzeug läuft nicht, Meldung nennt Feld und Erhaltenes" do
      assert {:ok, bericht} =
               laufen([antwort(aufrufe: [aufruf("echo", %{"text" => 5})]), antwort()])

      assert [%{fehler: true, content: text}] = werkzeug_nachrichten(bericht)
      assert text =~ "text: erwartet string, erhalten integer"
      assert text =~ ~s("text": 5)
      refute_received {:echo, _}
    end

    test "Ausnahme im Werkzeug" do
      kaputt = werkzeug("kaputt", fn _ -> raise "boom" end)

      assert {:ok, bericht} =
               laufen([antwort(aufrufe: [aufruf("kaputt", %{})]), antwort()], werkzeuge: [kaputt])

      assert [%{fehler: true, content: "boom"}] = werkzeug_nachrichten(bericht)
    end

    test "ungültiges Ergebnis eines Werkzeugs" do
      schief = werkzeug("schief", fn _ -> :huch end)

      assert {:ok, bericht} =
               laufen([antwort(aufrufe: [aufruf("schief", %{})]), antwort()], werkzeuge: [schief])

      assert [%{fehler: true, content: text}] = werkzeug_nachrichten(bericht)
      assert text =~ "ungültiges Ergebnis: :huch"
    end

    test "Map als Ergebnis geht als JSON ans Modell" do
      map = werkzeug("map", fn _ -> {:ok, %{"n" => 1}} end)

      assert {:ok, bericht} =
               laufen([antwort(aufrufe: [aufruf("map", %{})]), antwort()], werkzeuge: [map])

      assert [%{content: ~s({"n":1})}] = werkzeug_nachrichten(bericht)
    end

    test "abgeschnittene Antwort: kein Aufruf wird ausgeführt, alle werden abgelehnt" do
      aufrufe = [aufruf("echo", %{"text" => "a"}, "x"), aufruf("echo", %{"text" => "b"}, "y")]
      assert {:ok, bericht} = laufen([antwort(stopp: :laenge, aufrufe: aufrufe), antwort()])

      assert [%{fehler: true, content: t1}, %{fehler: true}] = werkzeug_nachrichten(bericht)
      assert t1 =~ "Ausgabegrenze"
      refute_received {:echo, _}
    end
  end

  describe "Ende" do
    test "halt beendet den Lauf, wenn alle Aufrufe halt liefern" do
      fertig = werkzeug("fertig", fn _ -> {:halt, "erledigt"} end)

      assert {:ok, %{ende: :halt, runden: 1}} =
               laufen([antwort(aufrufe: [aufruf("fertig", %{})])], werkzeuge: [fertig])
    end

    test "halt neben einem normalen Aufruf beendet nichts" do
      fertig = werkzeug("fertig", fn _ -> {:halt, "erledigt"} end)
      aufrufe = [aufruf("fertig", %{}), aufruf("echo", %{"text" => "noch"})]

      assert {:ok, %{ende: :fertig, runden: 2}} =
               laufen([antwort(aufrufe: aufrufe), antwort()], werkzeuge: [fertig, echo()])
    end

    test "Rundendeckel" do
      immer = antwort(aufrufe: [aufruf("echo", %{"text" => "x"})])

      assert {:error, %{ende: {:deckel, :runden}, runden: 2}} =
               laufen([immer, immer, immer], max_runden: 2)
    end

    test "Wanduhr wird vor jedem Modellaufruf geprüft" do
      langsam = fn ->
        Process.sleep(30)
        antwort(aufrufe: [aufruf("echo", %{"text" => "x"})])
      end

      assert {:error, %{ende: {:deckel, :zeit}, runden: 1}} =
               laufen([langsam, antwort()], max_ms: 10)
    end

    test "Modellfehler beendet den Lauf mit Grund und Verlauf" do
      assert {:error, %{ende: {:modell_fehler, :kaputt}, nachrichten: [_, _]}} =
               laufen([{:error, :kaputt}])
    end

    test "Ausnahme im Modell-Client wird zum Modellfehler" do
      assert {:error, %{ende: {:modell_fehler, {:ausnahme, "Stub-Skript erschöpft"}}}} =
               laufen([])
    end

    test "bei_stopp kann den Lauf mit einer Nachricht fortsetzen" do
      bei_stopp = fn
        %{text: "bin fertig"} -> {:weiter, "Es sind noch Blöcke offen."}
        _ -> :fertig
      end

      assert {:ok, %{ende: :fertig, runden: 2}} =
               laufen([antwort(text: "bin fertig"), antwort()], bei_stopp: bei_stopp)

      assert_received {:modell, _, _}
      assert_received {:modell, zweite, _}
      assert %{role: :user, content: "Es sind noch Blöcke offen."} = List.last(zweite)
    end

    test "Nutzung wird über alle Runden summiert" do
      n = %{eingabe: 100, ausgabe: 10}

      assert {:ok, %{nutzung: %{eingabe: 200, ausgabe: 20}}} =
               laufen([
                 antwort(nutzung: n, aufrufe: [aufruf("echo", %{"text" => "x"})]),
                 antwort(nutzung: n)
               ])
    end
  end

  describe "Kompaktierung" do
    test "schneidet vor der jüngsten Runde, ersetzt das Ältere durch eine Zusammenfassung, der Auftrag bleibt" do
      test = self()
      lang = String.duplicate("x", 40)

      runde = fn nutzung ->
        antwort(nutzung: nutzung, aufrufe: [aufruf("echo", %{"text" => lang})])
      end

      voll = %{eingabe: 200, ausgabe: 10}

      zusammenfassen = fn %{weggefallen: weg, vorherige: vorherige} ->
        send(test, {:zusammen, Enum.map(weg, & &1.role), vorherige})
        "STAND #{length(weg)}"
      end

      assert {:ok, bericht} =
               laufen([runde.(nil), runde.(voll), runde.(voll), antwort()],
                 kontext: [
                   fenster: 100,
                   reserve: 10,
                   behalten: 20,
                   zusammenfassen: zusammenfassen
                 ]
               )

      assert bericht.kompaktierungen == 2
      assert_received {:zusammen, [:assistant, :tool], nil}
      assert_received {:zusammen, [:assistant, :tool], "STAND 2"}

      assert_received {:modell, _, _}
      assert_received {:modell, _, _}
      assert_received {:modell, dritte, _}

      assert [
               %{role: :system},
               %{role: :user, content: "AUFTRAG"},
               %{role: :user, content: "STAND 2"},
               %{role: :assistant},
               %{role: :tool}
             ] = dritte
    end

    test "ohne kontext-Option wird nie kompaktiert" do
      voll = %{eingabe: 1_000_000, ausgabe: 0}
      aufrufe = [aufruf("echo", %{"text" => "x"})]

      assert {:ok, %{kompaktierungen: 0}} =
               laufen([
                 antwort(nutzung: voll, aufrufe: aufrufe),
                 antwort(nutzung: voll, aufrufe: aufrufe),
                 antwort()
               ])
    end
  end

  describe "Wiederholungssperre" do
    defp lies(wiederholung \\ :zaehlt) do
      Werkzeug.neu(
        name: "lies",
        beschreibung: "liest",
        parameter: %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}},
        ausfuehren: fn %{"x" => x} -> {:ok, "Inhalt " <> String.duplicate(x, 80)} end,
        wiederholung: wiederholung
      )
    end

    defp lies_aufruf(nutzung \\ nil),
      do: antwort(nutzung: nutzung, aufrufe: [aufruf("lies", %{"x" => "a"})])

    defp warnungen(bericht),
      do: bericht |> werkzeug_nachrichten() |> Enum.map(&(&1.content =~ "WARNUNG — Wiederholung"))

    test "der vierte gleiche Aufruf läuft nicht, die Antwort ist die Warnung; der Lauf geht weiter" do
      skript = List.duplicate(lies_aufruf(), 5) ++ [antwort()]
      assert {:ok, bericht} = laufen(skript, werkzeuge: [lies()])

      assert warnungen(bericht) == [false, false, false, true, true]
      assert %{ende: :fertig, runden: 6} = bericht

      vierte = bericht |> werkzeug_nachrichten() |> Enum.at(3)
      refute vierte.content =~ "Inhalt"
      assert vierte.fehler
      assert vierte.content =~ "nicht ausgeführt"
      assert vierte.content =~ "Lass diesen Punkt liegen und mach mit dem nächsten weiter."
      assert vierte.content =~ "ein 6. Mal, wird der Lauf abgebrochen"
    end

    test "beim sechsten gleichen Aufruf bricht der Lauf ab; der Aufruf selbst läuft nicht" do
      skript = List.duplicate(antwort(aufrufe: [aufruf("echo", %{"text" => "x"})]), 7)
      assert {:error, bericht} = laufen(skript)
      assert %{ende: {:abbruch, {:wiederholung, "echo"}}, runden: 6} = bericht

      # Ausgeführt nur die ersten drei; der 4. und 5. sind Warnungen, der 6. bricht ab.
      for _ <- 1..3, do: assert_received({:echo, "x"})
      refute_received {:echo, "x"}

      assert %{fehler: true, content: text} = bericht |> werkzeug_nachrichten() |> List.last()
      assert text =~ "zum 6. Mal"
    end

    test "ein Werkzeug kann den Lauf abbrechen; übrige Aufrufe der Antwort laufen nicht" do
      stopp = werkzeug("stopp", fn _ -> {:abbruch, "nach dem Ende dreimal gerufen"} end)
      aufrufe = [aufruf("stopp", %{}, "s"), aufruf("echo", %{"text" => "danach"}, "e")]

      assert {:error, bericht} = laufen([antwort(aufrufe: aufrufe)], werkzeuge: [stopp, echo()])
      assert bericht.ende == {:abbruch, {:werkzeug, "stopp"}}
      refute_received {:echo, _}

      assert [
               %{tool_call_id: "s", fehler: true, content: "nach dem Ende dreimal gerufen"},
               %{tool_call_id: "e", content: "Nicht ausgeführt: der Lauf ist abgebrochen."}
             ] = werkzeug_nachrichten(bericht)
    end

    test "Schleife über drei Werkzeuge: der vierte Umlauf wird bei jedem Aufruf gewarnt" do
      umlauf = [
        antwort(aufrufe: [aufruf("lies", %{"x" => "a"})]),
        antwort(aufrufe: [aufruf("echo", %{"text" => "b"})]),
        antwort(aufrufe: [aufruf("pruefe", %{})])
      ]

      pruefe = werkzeug("pruefe", fn _ -> {:error, "steht schon im Bestand"} end)
      skript = List.flatten(List.duplicate(umlauf, 4)) ++ [antwort()]
      assert {:ok, bericht} = laufen(skript, werkzeuge: [lies(), echo(), pruefe])

      assert warnungen(bericht) == List.duplicate(false, 9) ++ [true, true, true]
    end

    test "wiederholung: :bis_aenderung — ein erfolgreicher bestandsändernder Aufruf setzt zurück" do
      eintragen =
        Werkzeug.neu(
          name: "eintragen",
          beschreibung: "trägt ein",
          parameter: %{"type" => "object", "properties" => %{"n" => %{"type" => "integer"}}},
          ausfuehren: fn _ -> {:ok, "eingetragen"} end,
          aendert_bestand: true
        )

      skript =
        List.duplicate(lies_aufruf(), 3) ++
          [antwort(aufrufe: [aufruf("eintragen", %{"n" => 1})])] ++
          List.duplicate(lies_aufruf(), 3) ++ [antwort()]

      assert {:ok, bericht} = laufen(skript, werkzeuge: [lies(:bis_aenderung), eintragen])
      refute Enum.any?(warnungen(bericht))

      ohne = List.duplicate(lies_aufruf(), 4) ++ [antwort()]
      assert {:ok, bericht} = laufen(ohne, werkzeuge: [lies(:bis_aenderung)])
      assert List.last(warnungen(bericht))
    end

    test "wiederholung: :frei nimmt ein Werkzeug ganz aus (weiter())" do
      skript = List.duplicate(lies_aufruf(), 7) ++ [antwort()]
      assert {:ok, bericht} = laufen(skript, werkzeuge: [lies(:frei)])
      assert warnungen(bericht) == List.duplicate(false, 7)
    end

    test "auch Fehlerergebnisse zählen" do
      schon_da = werkzeug("eintragen", fn _ -> {:error, "steht schon im Bestand"} end)
      skript = List.duplicate(antwort(aufrufe: [aufruf("eintragen", %{})]), 4) ++ [antwort()]
      assert {:ok, bericht} = laufen(skript, werkzeuge: [schon_da])
      assert warnungen(bericht) == [false, false, false, true]
    end

    test "die Kompaktierung setzt nicht zurück — gezählt wird über den ganzen Lauf" do
      voll = %{eingabe: 200, ausgabe: 10}
      skript = [lies_aufruf(), lies_aufruf(), lies_aufruf(voll), lies_aufruf(), antwort()]

      assert {:ok, bericht} =
               laufen(skript,
                 werkzeuge: [lies()],
                 kontext: [fenster: 100, reserve: 10, behalten: 20]
               )

      # Die erste Kompaktierung fällt vor den vierten Aufruf (nur die dritte
      # Antwort meldet volle Nutzung). Eine zweite danach ist möglich, weil die
      # Warnung die vierte Antwort verlängert — für die Aussage hier egal.
      assert bericht.kompaktierungen >= 1
      # Nach dem Schnitt stehen nur noch die jüngsten Ergebnisse im Verlauf;
      # das letzte ist der vierte gleiche Aufruf, und der trägt die Warnung.
      assert List.last(warnungen(bericht))
    end

    test "wiederholungen: false schaltet die Sperre ab, eine ungültige Angabe wirft" do
      skript = List.duplicate(lies_aufruf(), 5) ++ [antwort()]
      assert {:ok, bericht} = laufen(skript, werkzeuge: [lies()], wiederholungen: false)
      refute Enum.any?(warnungen(bericht))

      assert_raise ArgumentError, ~r/wiederholungen:/, fn -> laufen([], wiederholungen: 0) end

      assert_raise ArgumentError, ~r/abbruch > warnung/, fn ->
        laufen([], wiederholungen: [warnung: 6, abbruch: 4])
      end
    end
  end

  @tag :tmp_dir
  test "Protokoll: eine JSON-Zeile je Ereignis, in Reihenfolge", %{tmp_dir: dir} do
    pfad = Path.join(dir, "lauf/protokoll.jsonl")

    assert {:ok, _} =
             laufen([antwort(aufrufe: [aufruf("echo", %{"text" => "hi"})]), antwort(text: "ok")],
               protokoll: pfad
             )

    zeilen = pfad |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert ["start", "antwort", "ergebnis", "antwort", "ende"] =
             Enum.map(zeilen, & &1["ereignis"])

    assert %{"name" => "echo", "art" => "ok", "text" => "echo: hi"} = Enum.at(zeilen, 2)
    assert %{"aufrufe" => [%{"argumente" => %{"text" => "hi"}}]} = Enum.at(zeilen, 1)
    assert %{"ende" => ":fertig", "runden" => 2} = List.last(zeilen)
  end

  describe "Optionen werden beim Start geprüft" do
    test "doppelte Werkzeugnamen" do
      assert_raise ArgumentError, ~r/Namen doppelt: echo/, fn ->
        laufen([], werkzeuge: [echo(), echo()])
      end
    end

    test "Modul, das Worker.Agent.Modell nicht implementiert" do
      assert_raise ArgumentError, ~r/implementiert Worker.Agent.Modell nicht/, fn ->
        laufen([], modell: {String, []})
      end
    end

    test "kontext, in den behalten und reserve nicht passen" do
      assert_raise ArgumentError, ~r/kontext:/, fn ->
        laufen([], kontext: [fenster: 100, reserve: 60, behalten: 50])
      end
    end

    test "Werkzeug mit Schema-Schlüssel, der nicht geprüft würde" do
      assert_raise ArgumentError, ~r/nicht unterstützt im Schema: a.pattern/, fn ->
        Werkzeug.neu(
          name: "w",
          beschreibung: "w",
          parameter: %{
            "type" => "object",
            "properties" => %{"a" => %{"type" => "string", "pattern" => "x"}}
          },
          ausfuehren: fn _ -> {:ok, ""} end
        )
      end
    end

    test "Werkzeugname, den die Chat-API ablehnt" do
      assert_raise ArgumentError, ~r/Werkzeugname "hat leerzeichen"/, fn ->
        werkzeug("hat leerzeichen", fn _ -> {:ok, ""} end)
      end
    end
  end
end
