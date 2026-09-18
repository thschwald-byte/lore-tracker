defmodule Worker.Jack.Chronik.WerkzeugeTest do
  @moduledoc """
  Issue #1211: die Werkzeugliste je Lauf — und zwei Wächter, die still
  brechen würden.

  `Resuemee.Werkzeuge.aus/3` baut die Liste über `Map.new(definitionen)`:
  Zwei Definitionen mit demselben Namen entscheidet die Reihenfolge, also
  zufällig. `fakt_umhaengen` gibt es zweimal — für Notiz-Gruppen
  (Überblick) und für Einträge (Schreiben, Durchsicht) —, deshalb steht die
  Notizen-Variante nur im Überblick.
  """
  use ExUnit.Case, async: true

  alias Worker.Jack.Chronik.Werkzeuge
  alias Worker.Jack.Resuemee.Stand

  defp stand(lauf) do
    %Stand{
      art: :chronik,
      lauf: lauf,
      sitzung: %{id: "s1", nummer: 1, name: "Erste"},
      fakten: [%{id: "S1-F1", fakt_id: "f_1", typ: "ereignis", aussage: "Etwas geschieht"}],
      eintraege: [],
      chronik: [],
      notizen: [],
      boegen: [],
      gelesen: MapSet.new(),
      # Die Lesebasis (`Worker.Jack.Lesen`) erwartet einen echten
      # `Worker.Jack.Stand`, keine Map — sonst FunctionClauseError.
      mitschnitt: %Worker.Jack.Stand{bloecke: %{}, max_block: -1, cast: [], straenge: []}
    }
  end

  describe "kein Name doppelt" do
    test "in keinem Lauf gibt es zwei Definitionen mit demselben Namen" do
      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        namen = Enum.map(Werkzeuge.definitionen(stand(lauf)), & &1.name)
        doppelt = namen -- Enum.uniq(namen)

        assert doppelt == [],
               "#{lauf}: #{inspect(doppelt)} doppelt — Map.new entscheidet dann nach " <>
                 "Reihenfolge, also zufällig"
      end
    end

    test "jeder Name aus namen/1 hat genau eine Definition" do
      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        s = stand(lauf)
        vorhanden = MapSet.new(Werkzeuge.definitionen(s), & &1.name)

        for name <- Werkzeuge.namen(s) do
          assert MapSet.member?(vorhanden, name),
                 "#{lauf}: #{name} steht in namen/1, hat aber keine Definition — " <>
                   "`aus/3` bricht dann mit KeyError"
        end
      end
    end
  end

  describe "fakt_umhaengen" do
    test "ist in allen drei Läufen erreichbar" do
      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        assert "fakt_umhaengen" in Werkzeuge.namen(stand(lauf)), to_string(lauf)
      end
    end

    test "im Überblick hängt es Gruppen um, im Schreiben Einträge" do
      ueberblick = finde(stand(:ueberblick), "fakt_umhaengen")
      schreiben = finde(stand(:schreiben), "fakt_umhaengen")

      assert ueberblick.beschreibung =~ "von einer Gruppe in eine andere"
      assert ueberblick.beschreibung =~ "Schlüssel"
      assert schreiben.beschreibung =~ "von einem Eintrag in einen anderen"
      assert schreiben.beschreibung =~ "Eintrags-ID"
    end

    test "es nennt seine drei Felder als Pflicht" do
      w = finde(stand(:ueberblick), "fakt_umhaengen")

      assert w.parameter["required"] == ~w(fakt von nach)
      assert Map.keys(w.parameter["properties"]) |> Enum.sort() == ~w(fakt nach von)
    end
  end

  describe "zahlen() — damit er nicht selbst zählt" do
    test "ist in allen drei Läufen erreichbar und nennt die fertig-Zahlen" do
      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        s = stand(lauf)
        assert "zahlen" in Werkzeuge.namen(s), to_string(lauf)

        # `Antwort.geordnet/1` liefert ein `Jason.OrderedObject` — über Access
        # lesen, nicht über Map-Funktionen.
        antwort = Worker.Jack.Chronik.Abschluss.zahlen_text(s)
        assert antwort["fuer_fertig"] != nil, to_string(lauf)
      end
    end

    test "die Zahlen unter fuer_fertig sind genau die, die fertig verlangt" do
      for {lauf, erwartet} <- [
            ueberblick: ~w(gruppen fakten_zugeordnet),
            schreiben: ~w(eintraege fakten_zugeordnet),
            durchsicht: ~w(bestaetigt ersetzt)
          ] do
        s = stand(lauf)
        fuer = Worker.Jack.Chronik.Abschluss.zahlen_text(s)["fuer_fertig"]

        assert Enum.sort(Map.keys(fuer)) == Enum.sort(erwartet),
               "#{lauf}: was zahlen() liefert, muss fertig() verlangen — sonst zählt er " <>
                 "doch wieder selbst"
      end
    end

    test "es ändert nichts und zählt erst bei unverändertem Bestand als Wiederholung" do
      w = finde(stand(:schreiben), "zahlen")

      assert w.wiederholung == :bis_aenderung
      refute Map.get(w, :aendert_bestand, false)
    end
  end

  describe "hilfe kennt alles" do
    test "jedes Werkzeug jedes Laufs ist über hilfe erklärbar" do
      for lauf <- [:ueberblick, :schreiben, :durchsicht] do
        s = stand(lauf)
        defs = Enum.filter(Werkzeuge.definitionen(s), &(&1.name in Werkzeuge.namen(s)))
        hilfe = Worker.Jack.Resuemee.Werkzeuge.hilfe(defs)

        for name <- Werkzeuge.namen(s) do
          {:ok, antwort} = hilfe.ausfuehren.(%{"werkzeug" => name})
          text = Jason.encode!(antwort)

          assert text =~ name, "#{lauf}/#{name}: hilfe kennt es nicht"
          refute text =~ "gibt es in diesem Lauf nicht", "#{lauf}/#{name}"
        end
      end
    end

    test "die Übersicht nennt fakt_umhaengen mit seinem ersten Satz" do
      s = stand(:schreiben)
      defs = Enum.filter(Werkzeuge.definitionen(s), &(&1.name in Werkzeuge.namen(s)))

      {:ok, antwort} = Worker.Jack.Resuemee.Werkzeuge.hilfe(defs).ausfuehren.(%{})

      assert Jason.encode!(antwort) =~ "fakt_umhaengen — Hängt EINEN Fakt"
    end
  end

  defp finde(s, name), do: Enum.find(Werkzeuge.definitionen(s), &(&1.name == name))
end
