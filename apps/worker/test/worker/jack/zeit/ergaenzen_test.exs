defmodule Worker.Jack.Zeit.ErgaenzenTest do
  @moduledoc """
  #1247: **die Kette ist persistent, und ein weiterer Lauf ergänzt sie** — er
  baut sie nicht neu.

  Maintainer, 25.09.2026: „die kette ist ja persistent — jeder weitere lauf
  soll diese kette ergänzen — nicht jede session schreibt eine neue kette."

  Vorher stimmte beides nicht, und gemessen war es schlimmer als vermutet:

    * **Jeder Lauf begann leer** (`Stand.neu` ohne `kette:`), und weil der
      Speicher gegen den Bestand vergleicht, bekam beim ERSTEN Werkzeugaufruf
      alles Bestehende einen Grabstein. Ein Regenerate löschte die Kette der
      Sitzung, statt sie zu ergänzen — und seit „speichern nach jedem Aufruf"
      (derselbe Tag) passierte das, bevor der Lauf irgendetwas eingeordnet
      hatte.
    * **Über Sitzungsgrenzen gab es keine Ordnung.** Der Lauf sah die Glieder
      anderer Sitzungen nicht und konnte nicht sagen, wo seine liegt.
  """
  use ExUnit.Case, async: false

  import Worker.TestHelper

  alias Worker.Jack.Zeit.Kettenspeicher
  alias Worker.Timeline.Kette

  @cid "camp-ergaenzen-1247"
  @s1 "sess-eins"
  @s2 "sess-zwei"

  setup do
    reset_for_permutation!()
    mat_pid = ensure_materializer!()
    on_exit(fn -> if mat_pid && Process.alive?(mat_pid), do: Process.exit(mat_pid, :kill) end)
    :ok
  end

  defp sitzung(id), do: %{id: id}
  defp kampagne, do: %{id: @cid}
  defp naechster_lauf, do: Process.sleep(2)

  # Sitzung 1 hat gearbeitet: zwei Glieder stehen in der Datenbank.
  defp erster_lauf do
    {:ok, k, a} = Kette.anhaengen(Kette.neu(), ["u1", "u2"], grund: "die Anreise")
    {:ok, k, b} = Kette.anhaengen(k, ["u3"], grund: "der Überfall")
    {2, 0} = Kettenspeicher.veroeffentlichen(sitzung(@s1), kampagne(), k)
    {k, a, b}
  end

  describe "ein zweiter Lauf derselben Sitzung" do
    test "ergänzt die Kette, statt sie zu begraben" do
      {k, _a, _b} = erster_lauf()
      naechster_lauf()

      # Der Lauf setzt auf dem Bestand auf (so wie ihn die Eingabe lädt) und
      # hängt ein Glied an.
      geladen = Worker.Repo.Zeit.kette(@cid)
      assert Kette.anzahl(geladen) == 2, "die Eingabe muss den Bestand laden"

      {:ok, erweitert, _} = Kette.anhaengen(geladen, ["u4"], grund: "die Flucht")
      assert {1, 0} = Kettenspeicher.veroeffentlichen(sitzung(@s1), kampagne(), erweitert)

      danach = Worker.Repo.Zeit.kette(@cid)
      assert Kette.anzahl(danach) == 3
      assert Kette.reihenfolge(danach) == ~w(u1 u2 u3 u4)
      assert Kette.anzahl(k) == 2, "die alte Kette selbst bleibt unberührt (pure)"
    end

    test "ein Lauf, der NICHTS tut, begräbt nichts" do
      # Das war der schlimmste Fall: leerer Start + Vergleich gegen den
      # Bestand = Grabstein für alles, beim ersten Werkzeugaufruf.
      erster_lauf()
      naechster_lauf()

      geladen = Worker.Repo.Zeit.kette(@cid)
      assert {0, 0} = Kettenspeicher.veroeffentlichen(sitzung(@s1), kampagne(), geladen)
      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid)) == 2
    end

    test "und was er bewusst löscht, wird begraben — die Regel gilt weiter" do
      # Das LETZTE Glied: kein Nachbar zieht nach, also genau ein Grabstein.
      {_k, _a, b} = erster_lauf()
      naechster_lauf()

      {:ok, kuerzer} = Kette.loeschen(Worker.Repo.Zeit.kette(@cid), b.id)
      assert {0, 1} = Kettenspeicher.veroeffentlichen(sitzung(@s1), kampagne(), kuerzer)
      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid)) == 1
    end

    test "beim Löschen in der Mitte zieht der rechte Nachbar nach" do
      # Der Platz steht als Bezug auf die Kennung des linken Nachbarn — wer
      # ein Glied herausnimmt, muss die Zeile dessen nachziehen, was danach
      # kommt, sonst zeigt sie ins Leere.
      {:ok, k, _} = Kette.anhaengen(Kette.neu(), ["u1"])
      {:ok, k, mitte} = Kette.anhaengen(k, ["u2"])
      {:ok, k, _} = Kette.anhaengen(k, ["u3"])
      {3, 0} = Kettenspeicher.veroeffentlichen(sitzung(@s1), kampagne(), k)
      naechster_lauf()

      {:ok, kuerzer} = Kette.loeschen(Worker.Repo.Zeit.kette(@cid), mitte.id)

      assert {1, 1} = Kettenspeicher.veroeffentlichen(sitzung(@s1), kampagne(), kuerzer),
             "ein Grabstein und eine nachgezogene Zeile"

      assert Kette.reihenfolge(Worker.Repo.Zeit.kette(@cid)) == ~w(u1 u3)
    end
  end

  describe "ein Lauf einer ANDEREN Sitzung" do
    test "sieht die Glieder der ersten und begräbt sie nicht" do
      erster_lauf()
      naechster_lauf()

      geladen = Worker.Repo.Zeit.kette(@cid)
      {:ok, mit_s2, _} = Kette.anhaengen(geladen, ["v1"], grund: "Sitzung 2, die Rückkehr")

      assert {1, 0} = Kettenspeicher.veroeffentlichen(sitzung(@s2), kampagne(), mit_s2),
             "nur das neue Glied — die fremden dürfen keine Grabsteine bekommen"

      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid)) == 3
    end

    test "und lässt jedes Glied in SEINER Sitzung" do
      # Ohne das wanderten die Glieder von Sitzung 1 in Sitzung 2, sobald ein
      # Lauf von dort sie mitschreibt — sichtbar erst daran, dass
      # `kette(cid, sid)` plötzlich anders zählt.
      erster_lauf()
      naechster_lauf()

      {:ok, mit_s2, _} = Kette.anhaengen(Worker.Repo.Zeit.kette(@cid), ["v1"])
      Kettenspeicher.veroeffentlichen(sitzung(@s2), kampagne(), mit_s2)

      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid, @s1)) == 2
      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid, @s2)) == 1
    end

    test "auch wenn es ein fremdes Glied VERÄNDERT" do
      # Ein Lauf von Sitzung 2 darf ein Glied von Sitzung 1 versetzen oder
      # erweitern — es bleibt dann trotzdem ein Glied von Sitzung 1.
      {_k, a, _b} = erster_lauf()
      naechster_lauf()

      {:ok, erweitert, _} = Kette.erweitern(Worker.Repo.Zeit.kette(@cid), a.id, ["u9"])
      assert {1, 0} = Kettenspeicher.veroeffentlichen(sitzung(@s2), kampagne(), erweitert)

      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid, @s1)) == 2,
             "das geänderte Glied bleibt in Sitzung 1"

      assert Kette.anzahl(Worker.Repo.Zeit.kette(@cid, @s2)) == 0
      assert Kette.glied(Worker.Repo.Zeit.kette(@cid), a.id).utts == ~w(u1 u2 u9)
    end
  end

  describe "die Verdrahtung" do
    test "die Eingabe lädt die Kette der KAMPAGNE, nicht der Sitzung" do
      # Kampagnenweit, weil Geschehen an der Sitzungsgrenze nicht aufhört —
      # und weil ein Lauf sonst nicht sagen kann, wo seine Sitzung liegt.
      quelle = File.read!("lib/worker/jack/zeit/eingabe.ex")

      assert quelle =~ "kette: Worker.Repo.Zeit.kette(campaign.id)",
             "ohne das beginnt jeder Lauf leer und begräbt den Bestand"

      refute quelle =~ "kette: Worker.Repo.Zeit.kette(campaign.id, session"
    end

    test "und der Stand übernimmt sie über die Erbe-Liste" do
      # `erbe/1` ist die eine Liste, aus der beide Seiten lesen (#1247). Wäre
      # `:kette` dort nicht drin, käme sie nie im Stand an — genau der Fehler,
      # an dem der Prüf-Lauf die ganze Arbeit verlor.
      assert Map.has_key?(Worker.Jack.Zeit.erbe(%Worker.Jack.Zeit.Stand{}), :kette)
    end
  end
end
