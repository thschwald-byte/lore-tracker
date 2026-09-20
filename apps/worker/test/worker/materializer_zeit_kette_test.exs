defmodule Worker.MaterializerZeitKetteTest do
  @moduledoc """
  #1247: der `ZeitKettengliedSet`-Fold und die Rundreise der Kette durch
  Mnesia.

  **Die Rundreise ist der eigentliche Gegenstand.** Die Kette lag bis hierhin
  als Blob im Jack-Stand, und dabei ist sie seit dem Umbau auf Bäume still
  unvollständig geworden: Die Ablage schrieb `id`, `utts`, `grund` — die
  **Kinder nicht**. Kein Test hat das gemerkt, weil keiner die Kette
  gespeichert und wieder gelesen hat. `bauen → speichern → lesen → identisch`
  ist die Prüfung, die dieser Klasse entspricht.
  """

  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Jack.Zeit.Kettenspeicher
  alias Worker.Materializer
  alias Worker.Schema.Mnesia, as: S
  alias Worker.Timeline.Kette

  @cid "camp-kette-1247"
  @sid "sess-kette-1247"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  # Die `event_id`s müssen lexikografisch aufsteigend sein („zk-01" vor
  # „zk-02"), weil `event_id_supersedes?/2` Strings vergleicht — in Prod sind
  # es UUIDv7 und damit von sich aus monoton (dieselbe Falle wie im
  # Anker-Test).
  defp ev(daten, seq, event_id, glied_id \\ "g_eins") do
    event(
      "ZeitKettengliedSet",
      %{
        "glied_id" => glied_id,
        "campaign_id" => @cid,
        "session_id" => @sid,
        "daten" => daten
      },
      seq,
      event_id: event_id
    )
  end

  defp glied(extra \\ %{}) do
    Map.merge(
      %{"art" => "glied", "utts" => ["u1"], "vorher" => nil, "eltern" => nil, "grund" => nil},
      extra
    )
  end

  defp gelesen(glied_id) do
    {:atomic, rows} = :mnesia.transaction(fn -> :mnesia.read(S.zeit_kette(), glied_id) end)

    case rows do
      [r] -> Jason.decode!(elem(r, 4))
      _ -> nil
    end
  end

  defp grund, do: (gelesen("g_eins") || %{})["grund"]

  defp sitzung, do: %{id: @sid}
  defp kampagne, do: %{id: @cid}

  # **Zwischen zwei Läufen muss eine Millisekunde liegen.** `event_id` ist
  # eine UUIDv7 und innerhalb derselben Millisekunde NICHT geordnet
  # (nachgemessen: rund die Hälfte aufeinanderfolgender IDs ist kleiner als
  # ihr Vorgänger). Wer hier zweimal ohne Pause schreibt, prüft nicht die
  # LWW-Zusage, sondern den Zufall — ein Drittel der Läufe war rot. Im
  # Betrieb liegen zwischen zwei Läufen Minuten; der Test bildet das nach,
  # statt die Eigenschaft zu verstecken.
  defp naechster_lauf, do: Process.sleep(2)

  # Eine Kette mit Baum, wie sie ein Lauf hinterlässt.
  defp beispielkette do
    {:ok, k, a} = Kette.anhaengen(Kette.neu(), ["u1", "u2"], grund: "die Anreise")
    {:ok, k, b} = Kette.anhaengen(k, ["u3"], grund: "der Überfall")
    {:ok, k, kind} = Kette.unterhaengen(k, b.id, ["u4"], grund: "der Hinterhalt")
    {:ok, k, _} = Kette.unterhaengen(k, kind.id, ["u5"], grund: "der erste Schuss")
    {:ok, k, _} = Kette.unterhaengen(k, b.id, ["u6"], grund: "die Flucht")
    {:ok, k} = Kette.draussen(k, ["u9"], "Tischgespräch")
    {k, a, b}
  end

  describe "Rundreise: was geschrieben wird, kommt vollständig zurück" do
    test "ein Baum überlebt Speichern und Lesen mit allen Tiefen" do
      # Genau die Klasse, die im Blob des Jack-Stands still verloren ging.
      {k, _a, b} = beispielkette()

      # Fünf Glieder plus die eine gelöste Zeile.
      assert {6, 0} = Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)

      zurueck = Worker.Repo.Zeit.kette(@cid, @sid)

      assert zurueck == k
      assert Kette.anzahl(zurueck) == 5
      assert Kette.reihenfolge(zurueck) == ~w(u1 u2 u3 u4 u5 u6)
      assert Kette.glied(zurueck, b.id).grund == "der Überfall"
      assert zurueck.draussen == %{"u9" => "Tischgespräch"}
    end

    test "jedes Feld der Kodierung überlebt den Fold" do
      assert {:applied, 1} = Materializer.apply_event(ev(glied(%{"grund" => "x"}), 1, "zk-01"))

      d = gelesen("g_eins")

      for feld <- ~w(art utts vorher eltern grund) do
        assert Map.has_key?(d, feld), "Feld #{feld} ist im Blob verloren gegangen"
      end

      {:atomic, [r]} = :mnesia.transaction(fn -> :mnesia.read(S.zeit_kette(), "g_eins") end)
      assert elem(r, 1) == "g_eins"
      assert elem(r, 2) == @cid
      assert elem(r, 3) == @sid
    end

    test "die Kampagnen-Form liest über alle Sitzungen" do
      # Der Normalfall für die Chronik: Geschehen hört nicht an der
      # Sitzungsgrenze auf.
      {k, _, _} = beispielkette()
      Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)

      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid)) == 5
    end
  end

  describe "Konvergenz" do
    test "LWW: der höhere event_id gewinnt, jede Reihenfolge endet gleich" do
      events = [
        ev(glied(%{"grund" => "erster"}), 1, "zk-01"),
        ev(glied(%{"grund" => "zweiter"}), 2, "zk-02")
      ]

      assert Enum.uniq(materialize_permutations(events, &grund/0)) == ["zweiter"]
    end

    test "ein entferntes Glied bekommt einen Grabstein statt eines Deletes (#698)" do
      # Mit Delete käme das Glied bei vertauschter Zustellung zurück — die
      # Row muss stehen bleiben und als entfernt gelten.
      Materializer.apply_event(ev(glied(), 1, "zk-01"))
      Materializer.apply_event(ev(%{"entfernt" => true}, 2, "zk-02"))

      assert gelesen("g_eins")["entfernt"] == true
      assert Worker.Repo.Zeit.ketten_zeilen(@cid, @sid) == []
    end

    test "Grabstein und Wiederkehr konvergieren in jeder Reihenfolge" do
      events = [
        ev(glied(%{"grund" => "da"}), 1, "zk-01"),
        ev(%{"entfernt" => true}, 2, "zk-02"),
        ev(glied(%{"grund" => "wieder da"}), 3, "zk-03")
      ]

      ergebnisse = materialize_permutations(events, fn -> (gelesen("g_eins") || %{})["grund"] end)
      assert Enum.uniq(ergebnisse) == ["wieder da"]
    end
  end

  describe "der Speicher schreibt nur, was sich geändert hat" do
    test "derselbe Stand zweimal schreibt kein zweites Ereignis" do
      # Ein Ereignis je Lauf und Glied schöbe die event_id vor; der
      # LWW-Vergleich verlöre damit seine Aussage.
      {k, _, _} = beispielkette()

      assert {6, 0} = Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)
      naechster_lauf()
      assert {0, 0} = Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)
    end

    test "ein gewachsenes Glied schreibt genau seine Zeile" do
      {k, a, _} = beispielkette()
      Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)

      naechster_lauf()
      {:ok, k, _} = Kette.erweitern(k, a.id, ["u7"])

      assert {1, 0} = Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)
      assert Kette.glied(Worker.Repo.Zeit.kette(@cid, @sid), a.id).utts == ~w(u1 u2 u7)
    end

    test "ein herausgenommenes Glied hinterlässt einen Grabstein — und der Nachbar zieht nach" do
      # Der Platz steht als Bezug auf die Kennung des linken Nachbarn; wer
      # ein Glied entfernt, muss die Zeile dessen nachziehen, was danach
      # kommt. Sonst zeigt sie ins Leere.
      {:ok, k, a} = Kette.anhaengen(Kette.neu(), ["u1"])
      {:ok, k, b} = Kette.anhaengen(k, ["u2"])
      {:ok, k, c} = Kette.anhaengen(k, ["u3"])
      Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)

      naechster_lauf()
      {:ok, k} = Kette.loeschen(k, b.id)

      assert {1, 1} = Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k),
             "die Zeile von c wird umgeschrieben, b bekommt einen Grabstein"

      zurueck = Worker.Repo.Zeit.kette(@cid, @sid)
      assert Kette.reihenfolge(zurueck) == ~w(u1 u3)
      assert Kette.glied(zurueck, b.id) == nil

      assert [^a, ^c] =
               zurueck.glieder
               |> Enum.map(&%{id: &1.id, utts: &1.utts, kinder: &1.kinder, grund: &1.grund})
    end

    test "ein versetztes Glied ändert die Zeilen beider Nachbarn" do
      {:ok, k, a} = Kette.anhaengen(Kette.neu(), ["u1"])
      {:ok, k, _b} = Kette.anhaengen(k, ["u2"])
      {:ok, k, c} = Kette.anhaengen(k, ["u3"])
      Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)

      naechster_lauf()
      {:ok, k} = Kette.versetzen(k, c.id, {:vor, a.id})
      Kettenspeicher.veroeffentlichen(sitzung(), kampagne(), k)

      assert Kette.reihenfolge(Worker.Repo.Zeit.kette(@cid, @sid)) == ~w(u3 u1 u2)
    end
  end

  describe "Ablehnungen" do
    test "ein Glied ohne Äußerungen und ohne Grabstein wird nicht geschrieben" do
      Materializer.apply_event(ev(%{"art" => "glied", "utts" => []}, 1, "zk-01"))

      assert gelesen("g_eins") == nil
    end

    test "eine Zeile ohne Kennung wird nicht geschrieben" do
      Materializer.apply_event(ev(glied(), 1, "zk-01", ""))

      assert Worker.Repo.Zeit.ketten_zeilen(@cid, @sid) == []
    end
  end
end
