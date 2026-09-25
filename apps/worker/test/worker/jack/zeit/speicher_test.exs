defmodule Worker.Jack.Zeit.SpeicherTest do
  @moduledoc """
  #1247: **ein abgebrochener Lauf behält, was er eingetragen hat.**

  Der Anlass sind zwei Totalverluste am 24.09.2026, beide auf derselben
  Sitzung: ein Lauf über 56 Minuten (Wiederholungsschleife) und einer über 62
  Minuten (Wiederholungssperre bei `offen`, 2168 Zeilen gelesen, 1992
  eingeordnet, 25 Glieder). Beide endeten mit **null** Zeilen in der
  Datenbank, weil erst nach `Zeit.laufen/2` veröffentlicht wurde — und dorthin
  kam keiner von beiden.

  Geprüft wird deshalb nicht die Speicherfunktion für sich, sondern der Weg,
  auf dem sie im Betrieb gerufen wird: über den Halter, nach jedem
  Werkzeugaufruf.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Jack.Resuemee.Halter
  alias Worker.Jack.Zeit.{Speicher, Stand, Werkzeuge}
  alias Worker.Timeline.Kette

  @cid "camp-speicher-1247"
  @sid "sess-speicher-1247"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp zeile(nr, id, text),
    do: %{
      nr: nr,
      utterance_id: id,
      sprecher: "SL",
      text: text,
      block_id: "b#{nr}",
      block_text: nil,
      ooc?: false
    }

  defp mitschnitt,
    do: [
      zeile(1, "u1", "Wir machen kurz Pause."),
      zeile(2, "u2", "Es ist jetzt zweiundzwanzig Uhr."),
      zeile(3, "u3", "Ihr geht los."),
      zeile(4, "u4", "Ihr kommt an.")
    ]

  defp halter do
    # **`kette:` gehört dazu, auch wenn sie leer ist** (#1247, 25.09.2026).
    # `Eingabe.aus_repo/1` liefert im Produktionspfad immer eine — bei einer
    # frischen Kampagne eine leere. Fehlt sie, gilt der Lauf als „kennt den
    # Bestand nicht", und der Speicher begräbt nichts (Riegel gegen den
    # Totalverlust). Dieser Test hat das gefunden: Er löscht ein Glied und
    # erwartete den Grabstein.
    stand =
      Stand.neu(:einsortieren, mitschnitt(),
        session_id: @sid,
        campaign_id: @cid,
        kette: Kette.neu()
      )

    {:ok, h} =
      Halter.start_link(stand, abbild: &Stand.abbild/1, nach_aufruf: &Speicher.sichern/1)

    h
  end

  defp ruf(h, name, felder) do
    werkzeuge = Werkzeuge.fuer(h) |> Map.new(&{&1.name, &1})
    Worker.Agent.Aufruf.ausfuehren(%{name: name, argumente: {:ok, felder}}, werkzeuge)
  end

  defp kette_aus_db, do: Worker.Repo.Zeit.kette(@cid, @sid)

  describe "nach jedem Werkzeugaufruf steht der Stand in der Datenbank" do
    test "ein eingereihtes Glied ist sofort da — ohne dass der Lauf endet" do
      h = halter()

      ruf(h, "haenge_an_kette", %{"von" => 2, "bis" => 4, "grund" => "der Aufbruch"})

      k = kette_aus_db()
      assert Kette.anzahl(k) == 1
      assert Kette.reihenfolge(k) == ~w(u2 u3 u4)
      assert Kette.glied_von(k, "u3").grund == "der Aufbruch"
    end

    test "gelöste Zeilen ebenso" do
      h = halter()

      ruf(h, "nicht_in_die_kette", %{"zeilen" => [1], "grund" => "Pausenabsprache"})

      assert kette_aus_db().draussen == %{"u1" => "Pausenabsprache"}
    end

    test "eine Korrektur wird nachgezogen, nicht danebengelegt" do
      h = halter()
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 4})
      glied = Kette.glied_von(kette_aus_db(), "u1")

      ruf(h, "loesche_kettenglied", %{"glied" => 1})

      k = kette_aus_db()
      assert Kette.anzahl(k) == 0, "das gelöschte Glied darf nicht zurückkommen"
      assert Kette.glied(k, glied.id) == nil
    end

    test "ein Anker reist mit — die Kette allein erklärt sich nicht" do
      # Maintainer, 24.09.2026: „Der Stand ist mehr als die Kette."
      h = halter()
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 4})

      ruf(h, "setz_zeitpunkt", %{
        "zeilen" => [2],
        "wert" => "zweiundzwanzig Uhr",
        "welt" => "spielwelt",
        "beleg" => "Es ist jetzt zweiundzwanzig Uhr."
      })

      anker = Worker.Repo.Zeit.anker(@cid)
      assert length(anker) == 1
      assert hd(anker)[:wert] == "zweiundzwanzig Uhr"
    end

    test "und der übrige Stand: Leseabdeckung und Notizen" do
      h = halter()
      ruf(h, "lies_sprechlinie", %{"ab" => 1, "anzahl" => 4})

      {:atomic, [row]} =
        :mnesia.transaction(fn ->
          :mnesia.read(Worker.Schema.Mnesia.jack_zeit_staende(), @sid)
        end)

      stand = Jason.decode!(elem(row, 3))
      assert stand["jack"] == "zeit"
      assert stand["abbild"]["gelesen"] == 4
      assert stand["laeuft"] == true
    end
  end

  describe "der Preis wird nicht doppelt gezahlt" do
    test "ein Aufruf, der nichts ändert, schreibt auch nichts" do
      # Ohne diesen Vergleich schöbe jeder Aufruf die event_id jeder Zeile vor,
      # und der LWW-Vergleich in den Folds verlöre seine Aussage.
      h = halter()
      ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 4})
      vorher = versionen()

      ruf(h, "zahlen", %{})
      ruf(h, "lies_kette", %{})

      assert versionen() == vorher, "lesende Werkzeuge dürfen die Ketten-Rows nicht neu schreiben"
    end

    defp versionen do
      {:atomic, rows} =
        :mnesia.transaction(fn ->
          :mnesia.match_object({Worker.Schema.Mnesia.zeit_kette(), :_, :_, :_, :_, :_, :_})
        end)

      rows |> Enum.map(&{elem(&1, 1), elem(&1, tuple_size(&1) - 1)}) |> Enum.sort()
    end
  end

  describe "die Verdrahtung" do
    test "Zeit.jack gibt den Speicher als nach_aufruf mit" do
      # **Ohne diesen Wächter fällt die ganze Sicherung still weg.** Die
      # Gegenprobe hat es gezeigt: Setzt man `nach_aufruf: nil` in `zeit.ex`,
      # bleiben alle Tests oben grün — sie starten ihren Halter selbst. Ein
      # fehlender Schlüssel erzeugt keinen Fehler, nur ein leeres Ergebnis
      # (#1090-Klasse, heute schon dreimal).
      quelle = File.read!("lib/worker/jack/zeit.ex")

      assert quelle =~ "nach_aufruf: &Speicher.sichern/1",
             "Zeit.jack/0 muss den Speicher mitgeben — sonst wird im Lauf nichts gesichert"
    end

    test "der Halter ruft nach_aufruf nach JEDEM Aufruf" do
      quelle = File.read!("lib/worker/jack/resuemee/halter.ex")

      assert quelle =~ "z = nach_aufruf(%{z | stand: s})",
             "Halter.aufrufen/3 muss den Haken rufen, sonst greift er nie"
    end
  end

  describe "ein Fehler beim Sichern beendet den Lauf nicht" do
    test "ohne Sitzung im Stand passiert nichts, und das Werkzeug antwortet normal" do
      # Messläufe und Tests fahren ohne Mnesia-Kontext — sie dürfen daran
      # nicht scheitern.
      stand = Stand.neu(:einsortieren, mitschnitt())

      {:ok, h} =
        Halter.start_link(stand, abbild: &Stand.abbild/1, nach_aufruf: &Speicher.sichern/1)

      assert {:ok, text} = ruf(h, "haenge_an_kette", %{"von" => 1, "bis" => 2})
      assert text =~ "angelegt"
      assert Kette.anzahl(Halter.stand(h).kette) == 1
    end
  end
end
