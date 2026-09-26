defmodule Worker.TeststageTest do
  @moduledoc """
  Issue #1260: der Teststage-Abzug. Kein Netz, kein Knoten — geprüft werden die
  Entscheidungen, die man beim Einspielen nicht sehen kann, wenn sie falsch sind.
  """
  use ExUnit.Case, async: true

  alias Worker.Teststage

  setup do
    dir = Path.join(System.tmp_dir!(), "teststage-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp schreiben(dir, name, ereignisse) do
    zeilen = Enum.map(ereignisse, &[Jason.encode!(&1), "\n"])
    File.write!(Path.join(dir, name), zeilen)
  end

  defp ereignis(id, ts, kind \\ "UtteranceAppended"),
    do: %{"event_id" => id, "hub_seq" => 7, "payload" => %{"kind" => kind}, "ts" => ts}

  describe "der Ablageort" do
    test "liegt außerhalb des Repos und trägt kein Datum im Namen" do
      # Ein datierter Pfad ist kein kanonischer Ort — man müsste wissen, welcher
      # der richtige ist, und genau das hat am 26.09.2026 eine Stunde gekostet.
      v = Teststage.standard_verzeichnis()

      assert Path.type(v) == :absolute
      refute v =~ ~r/\d{4}-\d{2}-\d{2}/
      refute String.contains?(v, "lore_tracker/apps")
    end

    test "ein Ziel im Arbeitsbaum wird abgewiesen" do
      # Der Abzug trägt die echten Namen und Gespräche der Runde, und das Repo
      # ist öffentlich.
      repo = "/home/x/Projekte/lore_tracker"

      refute Teststage.pfad_erlaubt?(repo, repo)
      refute Teststage.pfad_erlaubt?("#{repo}/priv/seeds", repo)
      refute Teststage.pfad_erlaubt?("#{repo}/../lore_tracker/apps", repo)
      assert Teststage.pfad_erlaubt?("/home/x/.local/share/lore-jack/teststage", repo)
      assert Teststage.pfad_erlaubt?("/home/x/Projekte/lore_tracker_zwei", repo)
    end

    test "die Wurzel ist der Umbrella-Root, NICHT das App-Verzeichnis" do
      # Der Riegel hing daran, und er hat nicht gegriffen: Die Tasks laufen aus
      # `apps/worker` (so ruft sie `mix cmd --app worker`, so ruft sie
      # `lore.pr_test`), und gegen `File.cwd!()` geprüft galt
      # `<repo>/priv/abzug` als „außerhalb" — genau das Ziel, gegen das der
      # Riegel gebaut ist. Am 26.09.2026 beim Prüfen von Hand aufgefallen; der
      # Unit-Test darüber prüfte nur `pfad_erlaubt?/2` mit GEGEBENER Wurzel.
      wurzel = Teststage.arbeitsbaum()

      assert Path.type(wurzel) == :absolute
      refute String.ends_with?(wurzel, "/apps/worker")
      assert File.exists?(Path.join(wurzel, "mix.exs")), "dort muss die Umbrella-mix.exs liegen"
      assert File.dir?(Path.join(wurzel, "apps"))

      # Und der Riegel greift damit auch für ein Ziel im Repo.
      refute Teststage.pfad_erlaubt?(Path.join(wurzel, "priv/abzug"), wurzel)
      refute Teststage.pfad_erlaubt?(Path.join(wurzel, "apps/worker/priv"), wurzel)
    end

    test "ein Produktions-Knoten wird erkannt" do
      assert Teststage.prod_knoten?(:"worker_prod@cachyos-x8664")
      assert Teststage.prod_knoten?("worker_prod@host")
      refute Teststage.prod_knoten?(:"lore-issue-1260-port-4001-worker-0@host")
      refute Teststage.prod_knoten?(:worker@host)
    end
  end

  describe "lesen" do
    test "ein leeres Verzeichnis ist ein FEHLER, kein leerer Abzug", %{dir: dir} do
      # Ein leerer Abzug, der als Erfolg durchgeht, ist die stille Variante:
      # Die Stage wäre danach leer, und niemand wüsste warum.
      assert Teststage.dateien(dir) == {:error, :kein_abzug}
      assert Teststage.ereignisse(dir) == {:error, :kein_abzug}
    end

    test "ein fehlendes Verzeichnis ebenso" do
      assert Teststage.ereignisse("/gibt/es/nicht") == {:error, :kein_abzug}
    end

    test "nur .jsonl zählt", %{dir: dir} do
      schreiben(dir, "worker_events_global.jsonl", [ereignis("a", "2026-01-01 10:00:00Z")])
      File.write!(Path.join(dir, "LIESMICH.md"), "Notiz für Menschen")

      assert {:ok, [datei]} = Teststage.dateien(dir)
      assert Path.basename(datei) == "worker_events_global.jsonl"
    end

    test "ALLE Dateien zusammen, nach ts sortiert", %{dir: dir} do
      # Die Dateien sind je Tabelle getrennt, die Kausalität läuft quer: Eine
      # Glättung liegt global, die Fakten dazu in der Kampagnentabelle. Datei
      # für Datei einzuspielen hiesse, Fakten vor ihrer Glättung anzuwenden.
      schreiben(dir, "worker_events_global.jsonl", [
        ereignis("global-spaet", "2026-01-01 12:00:00Z", "TranscriptSmoothed"),
        ereignis("global-frueh", "2026-01-01 08:00:00Z", "SessionScheduled")
      ])

      schreiben(dir, "worker_campaign_events_abc.jsonl", [
        ereignis("kampagne-mitte", "2026-01-01 10:00:00Z", "SessionFactsExtracted")
      ])

      assert {:ok, liste} = Teststage.ereignisse(dir)

      assert Enum.map(liste, & &1["event_id"]) ==
               ["global-frueh", "kampagne-mitte", "global-spaet"]
    end

    test "doppelte event_id wird entfernt", %{dir: dir} do
      # Am 25.09.2026 entstand ein Abzug, in dem jedes Ereignis zweimal stand
      # (26 MB statt 3). Er trägt die Warnung im Namen — ein Werkzeug, das sich
      # darauf verlässt, hat keine.
      schreiben(dir, "worker_events_global.jsonl", [
        ereignis("a", "2026-01-01 10:00:00Z"),
        ereignis("a", "2026-01-01 10:00:00Z"),
        ereignis("b", "2026-01-01 11:00:00Z")
      ])

      assert {:ok, liste} = Teststage.ereignisse(dir)
      assert Enum.map(liste, & &1["event_id"]) == ["a", "b"]
    end

    test "leere Zeilen stören nicht", %{dir: dir} do
      File.write!(
        Path.join(dir, "worker_events_global.jsonl"),
        [Jason.encode!(ereignis("a", "2026-01-01 10:00:00Z")), "\n\n"]
      )

      assert {:ok, [%{"event_id" => "a"}]} = Teststage.ereignisse(dir)
    end
  end

  describe "die Form fürs Anwenden" do
    test "String-Keys, ts dabei, seq nil, hub_seq weg" do
      # `Materializer.do_apply/1` matcht auf String-Keys; mit Atom-Keys wirft es
      # FunctionClauseError und reisst den Worker um (25.09.2026). Ohne `ts`
      # greift der Auffangzweig und das Ereignis wird STILL verworfen. `seq: nil`
      # ist der dokumentierte Weg für ein Ereignis ohne Hub-Cursor.
      roh = ereignis("a", "2026-01-01 10:00:00Z", "UtteranceAppended")

      assert Teststage.zum_anwenden(roh) == %{
               "event_id" => "a",
               "seq" => nil,
               "payload" => %{"kind" => "UtteranceAppended"},
               "ts" => "2026-01-01 10:00:00Z"
             }
    end

    test "hub_seq des Quell-Workers reist NICHT mit" do
      # Er ist der Cursor des Workers, von dem der Abzug stammt, und bedeutet am
      # Ziel nichts.
      refute Map.has_key?(Teststage.zum_anwenden(ereignis("a", "t")), "hub_seq")
    end
  end

  test "arten/1 zählt, häufigste zuerst" do
    ereignisse = [
      ereignis("a", "t1", "UtteranceAppended"),
      ereignis("b", "t2", "UtteranceAppended"),
      ereignis("c", "t3", "TranscriptSmoothed")
    ]

    assert Teststage.arten(ereignisse) == [{"UtteranceAppended", 2}, {"TranscriptSmoothed", 1}]
  end
end
