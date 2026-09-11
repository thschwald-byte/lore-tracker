defmodule Worker.Jack.ReferenzFolgeTest do
  # Folgedurchgänge des Referenzlaufs bis zur Sättigung (Tom, 11.09.: der
  # Fable-Lauf soll genauso iterieren wie die anderen). Claude Code ist hier
  # ein Skript, das die Phase mit `fertig` abschließt und den Bestand des
  # vorigen Durchgangs übernimmt, ohne etwas Neues einzutragen.
  use ExUnit.Case, async: true

  alias Worker.Jack.{Abbild, Stand}
  alias Worker.Jack.Referenz.Folge

  @bloecke for i <- 0..20, do: %{text: "Satz #{i}.", sprecher: "X"}

  defp aussagen!(d, nummern) do
    File.mkdir_p!(d)

    File.write!(
      Path.join(d, "aussagen.jsonl"),
      Enum.map_join(
        nummern,
        "",
        &(Jason.encode!(%{"nummer" => &1, "source_refs" => [1]}) <> "\n")
      )
    )
  end

  defp lauf(phasen), do: %{"art" => "referenz", "phasen" => phasen}
  defp p(nr, n, ende), do: %{"nr" => nr, "durchgang" => n, "ende" => ende}

  @tag :tmp_dir
  test "naechster_schritt: fortsetzen, nächster Durchgang, gesättigt, Deckel", %{tmp_dir: nach} do
    aussagen!(Path.join(nach, "d1"), [1, 2])
    aussagen!(Path.join(nach, "d2"), [1, 2, 3])
    aussagen!(Path.join(nach, "d3"), [1, 2, 3])

    p1 = %{"nr" => 1, "ende" => "halt"}

    # Ein Durchgang ohne `durchgang` ist Durchgang 1 (Läufe vor den Folgedurchgängen).
    assert Folge.naechster_schritt(lauf([p1, %{"nr" => 2, "ende" => "{:exit, 1}"}]), nach) ==
             {:fortsetzen, 1}

    assert Folge.naechster_schritt(lauf([p1, %{"nr" => 2, "ende" => "halt"}]), nach) ==
             {:durchgang, 2}

    assert Folge.naechster_schritt(lauf([p1, p(2, 1, "halt"), p(2, 2, "halt")]), nach) ==
             {:durchgang, 3}

    assert Folge.naechster_schritt(lauf([p1, p(2, 1, "halt"), p(2, 3, "halt")]), nach) ==
             {:fertig, :gesaettigt}

    assert Folge.naechster_schritt(lauf([p1, p(2, 1, "halt"), p(2, 2, "halt")]), nach, 2) ==
             {:fertig, :deckel}

    assert {:error, {:nicht_fortsetzbar, _}} =
             Folge.naechster_schritt(lauf([%{"nr" => 1, "ende" => "{:exit, 1}"}]), nach)
  end

  defp claude_fertig(dir) do
    pfad = Path.join(dir, "claude_fertig")

    File.write!(pfad, """
    #!/bin/sh
    printf '%s' "$2" > auftrag.txt
    [ -e ../beilage.tsv ] && touch beilage_waehrend_des_laufs.txt
    [ -e ../aussagen.jsonl ] || cp ../../d1/aussagen.jsonl ../aussagen.jsonl
    echo '{"art":"halt","name":"fertig"}' >> ../werkzeuge.jsonl
    echo '{"type":"system","subtype":"init","model":"m","claude_code_version":"t","tools":[]}'
    echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"usage":{"input_tokens":1,"output_tokens":1}}'
    """)

    File.chmod!(pfad, 0o755)
    pfad
  end

  @tag :tmp_dir
  test "bis_fertig: Durchgang 1 zu Ende, dann ein Folgedurchgang ohne Neues — gesättigt",
       %{tmp_dir: dir} do
    quelle = Path.join(dir, "quelle.tsv")
    File.write!(quelle, "geheim\n")
    nach = Path.join(dir, "lauf")
    d1 = Path.join(nach, "d1")

    s =
      Stand.neu(bloecke: @bloecke, phase: 2)
      |> Stand.eintragen(%{"nummer" => 1, "claim" => "A", "source_refs" => [12], "_iter" => 1})

    :ok = Abbild.schreiben(d1, %{s | lfd: 1, gelesen: [{0, 12}], sammelnd: [{0, 12}]})
    File.cp!(quelle, Path.join(d1, "beilage.tsv"))

    File.write!(
      Path.join(nach, "messlauf.json"),
      Jason.encode!(%{
        "art" => "referenz",
        "modell" => "m",
        "effort" => "e",
        "beispiele" => nil,
        "ende" => "abgebrochen",
        "phasen" => [%{"nr" => 1, "ende" => "halt"}, %{"nr" => 2, "ende" => "{:exit, 1}"}]
      })
    )

    opts = [
      eingabe: %{bloecke: @bloecke, cast: [], straenge: []},
      mcp_eingabe: %{"eingabe" => "demo"},
      auftraege: %{phase2: "AUFTRAG ZWEI", folgelauf: "FOLGELAUF"},
      nach: nach,
      modell: "m",
      effort: "e",
      beispiele: nil,
      claude: claude_fertig(dir),
      worker_dir: dir,
      max_ms: 30_000,
      beilagen: [{quelle, "beilage.tsv"}],
      warten: fn _ -> flunk("ohne Grenze wird nicht gewartet") end
    ]

    assert {:fertig, %{"ende" => "gesaettigt"} = lauf} = Folge.bis_fertig(opts)

    assert Enum.map(lauf["phasen"], &{&1["nr"], &1["durchgang"], &1["teil"], &1["ende"]}) ==
             [
               {1, nil, nil, "halt"},
               {2, nil, nil, "{:exit, 1}"},
               {2, 1, 2, "halt"},
               {2, 2, 1, "halt"}
             ]

    assert [%{"nr" => 1, "bestand" => 1}, %{"nr" => 2, "vorher" => 1, "bestand" => 1, "neu" => 0}] =
             lauf["durchgaenge"]

    # Der Folgedurchgang lädt aus d1 in ein eigenes d2, mit dem Folgelauf-Auftrag.
    d2 = Path.join(nach, "d2")

    assert %{"von" => ^d1, "nach" => ^d2, "im_durchgang" => false, "phase" => 2} =
             Path.join(d2, "mcp_konfig.json") |> File.read!() |> Jason.decode!()

    auftrag = File.read!(Path.join([d2, "cc", "auftrag.txt"]))
    assert auftrag =~ "FOLGELAUF"
    assert auftrag =~ "## Dein Gedächtnis"

    # Die Beilagen: nie während eines Teils in der Ablage, danach in beiden.
    refute File.exists?(Path.join([d1, "cc", "beilage_waehrend_des_laufs.txt"]))
    refute File.exists?(Path.join([d2, "cc", "beilage_waehrend_des_laufs.txt"]))
    assert File.read!(Path.join(d1, "beilage.tsv")) == "geheim\n"
    assert File.read!(Path.join(d2, "beilage.tsv")) == "geheim\n"

    # Nichts mehr zu tun: ein weiterer Aufruf ändert nichts.
    assert {:fertig, %{"ende" => "gesaettigt"}} = Folge.fortsetzen(opts)
  end

  @tag :tmp_dir
  test "ein Folgedurchgang beginnt nicht in einem Verzeichnis, das es schon gibt",
       %{tmp_dir: nach} do
    aussagen!(Path.join(nach, "d1"), [1])
    File.mkdir_p!(Path.join(nach, "d2"))

    File.write!(
      Path.join(nach, "messlauf.json"),
      Jason.encode!(%{
        "art" => "referenz",
        "modell" => "m",
        "effort" => "e",
        "beispiele" => nil,
        "phasen" => [%{"nr" => 1, "ende" => "halt"}, %{"nr" => 2, "ende" => "halt"}]
      })
    )

    opts = [
      eingabe: %{bloecke: @bloecke, cast: [], straenge: []},
      auftraege: %{folgelauf: "FOLGELAUF"},
      nach: nach,
      modell: "m",
      effort: "e",
      beispiele: nil
    ]

    assert {:error, {:verzeichnis_gibt_es_schon, _}} = Folge.fortsetzen(opts)
  end
end
