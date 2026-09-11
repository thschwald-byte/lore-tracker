defmodule Worker.Jack.ReferenzFortsetzenTest do
  # Fortsetzen eines abgebrochenen Referenzlaufs in Phase 2 (Tom, 11.09.:
  # nach dem Reset des Fünf-Stunden-Fensters weitermachen). Claude Code ist
  # hier ein Skript, das init und result schreibt und den Auftrag ablegt — der
  # MCP-Server wird dabei nicht gestartet.
  use ExUnit.Case, async: true

  alias Worker.Jack.{Abbild, Abschluss, Fortsetzung, Referenz, Stand}

  @bloecke for i <- 0..20, do: %{text: "Satz #{i}.", sprecher: "X"}

  defp stand_mitten_in_phase2 do
    s =
      Stand.neu(bloecke: @bloecke, phase: 2)
      |> Stand.eintragen(%{"nummer" => 1, "claim" => "A", "source_refs" => [3], "_iter" => 1})

    %{s | lfd: 1, gelesen: [{0, 9}, {10, 14}], sammelnd: [{10, 14}]}
  end

  @tag :tmp_dir
  test "im_durchgang_laden: derselbe Durchgang, die gelesenen Bereiche bleiben",
       %{tmp_dir: dir} do
    :ok = Abbild.schreiben(dir, stand_mitten_in_phase2())
    basis = [bloecke: @bloecke, phase: 2]

    # Zum Vergleich: so lädt der nächste Durchgang.
    {:ok, naechster} = Fortsetzung.laden(dir, basis)
    assert {naechster.durchgang, naechster.gelesen} == {2, []}

    {:ok, s} = Referenz.im_durchgang_laden(dir, basis)
    assert {s.durchgang, s.lfd} == {1, 1}
    assert s.gelesen == [{0, 9}, {10, 14}]
    assert Abschluss.nie_gelesen(s) == Abschluss.nie_gelesen(stand_mitten_in_phase2())
  end

  defp claude_attrappe(dir) do
    pfad = Path.join(dir, "claude")

    File.write!(pfad, """
    #!/bin/sh
    printf '%s' "$2" > auftrag.txt
    [ -e ../beilage.tsv ] && touch beilage_waehrend_des_laufs.txt
    echo '{"type":"system","subtype":"init","model":"m","claude_code_version":"t","tools":[]}'
    echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"usage":{"input_tokens":1,"output_tokens":1}}'
    """)

    File.chmod!(pfad, 0o755)
    pfad
  end

  defp abgebrochener_lauf(dir, name, quelle, aenderung \\ & &1) do
    nach = Path.join(dir, name)
    d1 = Path.join(nach, "d1")
    :ok = Abbild.schreiben(d1, stand_mitten_in_phase2())
    File.write!(Path.join(d1, "claude_strom.jsonl"), "alt\n")
    File.cp!(quelle, Path.join(d1, "beilage.tsv"))

    messlauf =
      aenderung.(%{
        "art" => "referenz",
        "modell" => "m",
        "effort" => "e",
        "beispiele" => nil,
        "ende" => "abgebrochen",
        "bestand" => 1,
        "phasen" => [
          %{"nr" => 1, "teil" => 1, "ende" => "halt"},
          %{"nr" => 2, "teil" => 1, "ende" => "{:exit, 1}"}
        ]
      })

    File.write!(Path.join(nach, "messlauf.json"), Jason.encode!(messlauf))
    nach
  end

  defp opts(dir, nach, quelle, mehr \\ []) do
    Keyword.merge(
      [
        eingabe: %{bloecke: @bloecke, cast: [], straenge: []},
        mcp_eingabe: %{"eingabe" => "demo"},
        auftraege: %{phase2: "AUFTRAG ZWEI"},
        nach: nach,
        modell: "m",
        effort: "e",
        beispiele: nil,
        claude: claude_attrappe(dir),
        worker_dir: dir,
        max_ms: 30_000,
        beilagen: [{quelle, "beilage.tsv"}]
      ],
      mehr
    )
  end

  @tag :tmp_dir
  test "fortsetzen: ein neuer Teil in Phase 2, nichts überschrieben, Beilagen erst danach",
       %{tmp_dir: dir} do
    quelle = Path.join(dir, "quelle.tsv")
    File.write!(quelle, "geheim\n")
    nach = abgebrochener_lauf(dir, "lauf", quelle)
    d1 = Path.join(nach, "d1")

    ergebnis = Referenz.fortsetzen(opts(dir, nach, quelle))

    assert %{
             "ende" => "abgebrochen",
             "bestand" => 1,
             "fortsetzungen" => [
               %{"teil" => 2, "vorheriges_ende" => "{:exit, 1}", "bestand_vorher" => 1}
             ]
           } = ergebnis

    assert [_, _, %{nr: 2, teil: 2}] = ergebnis["phasen"]

    # Der Rohstrom des ersten Teils bleibt, der neue hat eine eigene Datei.
    assert File.read!(Path.join(d1, "claude_strom.jsonl")) == "alt\n"
    assert File.read!(Path.join(d1, "claude_strom_2.jsonl")) =~ ~s("type":"result")
    assert File.exists?(Path.join(nach, "messlauf_vor_fortsetzung.json"))

    assert %{"im_durchgang" => true, "von" => ^d1, "nach" => ^d1, "phase" => 2} =
             Path.join(d1, "mcp_konfig_2.json") |> File.read!() |> Jason.decode!()

    # Auftrag von Phase 2, dahinter der Arbeitsstand wie nach einer Kompaktierung.
    auftrag = File.read!(Path.join([d1, "cc", "auftrag.txt"]))
    assert auftrag =~ "AUFTRAG ZWEI"
    assert auftrag =~ "## Wo du stehst"

    # Während des Laufs lag die Beilage nicht in der Ablage, danach wieder.
    refute File.exists?(Path.join([d1, "cc", "beilage_waehrend_des_laufs.txt"]))
    assert File.read!(Path.join(d1, "beilage.tsv")) == "geheim\n"

    assert %{"phasen" => [_, _, %{"teil" => 2}]} =
             Path.join(nach, "messlauf.json") |> File.read!() |> Jason.decode!()
  end

  @tag :tmp_dir
  test "fortsetzen lehnt ab: Phase 1 offen, andere Einstellungen, eine fremde Beilage",
       %{tmp_dir: dir} do
    quelle = Path.join(dir, "quelle.tsv")
    File.write!(quelle, "geheim\n")

    offen =
      abgebrochener_lauf(dir, "offen", quelle, fn m ->
        put_in(m, ["phasen"], [%{"nr" => 1, "ende" => "{:exit, 1}"}])
      end)

    assert {:error, {:nicht_fortsetzbar, _}} = Referenz.fortsetzen(opts(dir, offen, quelle))

    anders = abgebrochener_lauf(dir, "anders", quelle)

    assert {:error, {:einstellungen_anders, _, _}} =
             Referenz.fortsetzen(opts(dir, anders, quelle, effort: "high"))

    fremd = abgebrochener_lauf(dir, "fremd", quelle)
    File.write!(Path.join([fremd, "d1", "beilage.tsv"]), "verändert\n")

    assert {:error, {:beilage_weicht_ab, _}} = Referenz.fortsetzen(opts(dir, fremd, quelle))
    refute File.exists?(Path.join(fremd, "messlauf_vor_fortsetzung.json"))
  end

  defp limit_zeile(status, typ, reset),
    do:
      Jason.encode!(%{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{"status" => status, "rateLimitType" => typ, "resetsAt" => reset}
      })

  defp result_zeile(fehler),
    do:
      Jason.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => fehler,
        "duration_ms" => 1
      })

  defp zeilen(liste), do: Enum.join(liste, "\n") <> "\n"

  # Claude Code am Limit: jede Sitzung endet sofort an der Grenze.
  defp claude_am_limit(dir, reset) do
    pfad = Path.join(dir, "claude_am_limit")

    File.write!(pfad, """
    #!/bin/sh
    echo '#{limit_zeile("rejected", "five_hour", reset)}'
    echo '#{result_zeile(true)}'
    """)

    File.chmod!(pfad, 0o755)
    pfad
  end

  @tag :tmp_dir
  test "grenze: das letzte rate_limit_event des jüngsten Teils, nur bei rejected und Fehler",
       %{tmp_dir: dir} do
    assert Referenz.grenze(dir) == :keine

    File.write!(
      Path.join(dir, "claude_strom.jsonl"),
      zeilen([limit_zeile("rejected", "five_hour", 100), result_zeile(true)])
    )

    assert Referenz.grenze(dir) == {:fuenf_stunden, 100}

    File.write!(
      Path.join(dir, "claude_strom_2.jsonl"),
      zeilen([limit_zeile("allowed", "five_hour", 200), result_zeile(false)])
    )

    assert Referenz.grenze(dir) == :keine

    File.write!(
      Path.join(dir, "claude_strom_10.jsonl"),
      zeilen([
        limit_zeile("allowed", "five_hour", 1),
        limit_zeile("rejected", "seven_day", 300),
        result_zeile(true)
      ])
    )

    assert Referenz.grenze(dir) == {:andere, "seven_day", 300}
  end

  @tag :tmp_dir
  test "bis_fertig: vor jedem Teil bis zum Reset warten, nach max_teile aufhören",
       %{tmp_dir: dir} do
    quelle = Path.join(dir, "quelle.tsv")
    File.write!(quelle, "geheim\n")
    nach = abgebrochener_lauf(dir, "lauf", quelle)

    # Der abgebrochene erste Teil endete am Fünf-Stunden-Fenster.
    File.write!(
      Path.join([nach, "d1", "claude_strom.jsonl"]),
      zeilen([limit_zeile("rejected", "five_hour", 1000), result_zeile(true)])
    )

    ich = self()

    o =
      opts(dir, nach, quelle,
        claude: claude_am_limit(dir, 5000),
        max_teile: 2,
        jetzt: fn -> 900 end,
        warten: fn ms -> send(ich, {:warten, ms}) end
      )

    assert {:aufgehoert, :max_teile} = Referenz.bis_fertig(o)
    # Reset plus eine Minute, gerechnet ab „jetzt“.
    assert_received {:warten, 160_000}
    assert_received {:warten, 4_160_000}

    assert %{"phasen" => phasen, "ende" => "abgebrochen"} =
             nach |> Path.join("messlauf.json") |> File.read!() |> Jason.decode!()

    assert Enum.map(phasen, & &1["teil"]) == [1, 1, 2, 3]
    assert File.read!(Path.join([nach, "d1", "beilage.tsv"])) == "geheim\n"
  end

  @tag :tmp_dir
  test "bis_fertig hört auf: ein Teil ohne Grenze, die Grenze der Woche", %{tmp_dir: dir} do
    quelle = Path.join(dir, "quelle.tsv")
    File.write!(quelle, "geheim\n")
    ich = self()
    warten = fn ms -> send(ich, {:warten, ms}) end

    ohne = abgebrochener_lauf(dir, "ohne", quelle)

    assert {:aufgehoert, {:teil_endete, :keine}} =
             Referenz.bis_fertig(opts(dir, ohne, quelle, warten: warten))

    woche = abgebrochener_lauf(dir, "woche", quelle)

    File.write!(
      Path.join([woche, "d1", "claude_strom.jsonl"]),
      zeilen([limit_zeile("rejected", "seven_day", 300), result_zeile(true)])
    )

    assert {:aufgehoert, {:grenze, "seven_day", 300}} =
             Referenz.bis_fertig(opts(dir, woche, quelle, warten: warten))

    refute File.exists?(Path.join(woche, "messlauf_vor_fortsetzung.json"))
    refute_received {:warten, _}
  end
end
