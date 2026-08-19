defmodule Hub.MemoryReporterTest do
  @moduledoc """
  Issue #1087: die Speicher-Zeile ist das einzige, was beim nächsten OOM-Kill
  rückwirkend eine Antwort erlaubt. Deshalb sind hier genau die Eigenschaften
  festgenagelt, deren stilles Versagen die Zeile wertlos machen würde:

  - Ohne echtes Cgroup-Limit dürfen KEINE Cgroup-Zahlen in der Zeile stehen
    (auf der Entwicklermaschine wären das die Werte des ganzen Rechners —
    Zahlen, die aussehen wie eine Messung, aber keine sind).
  - Die LiveView-Zählung hängt an einem Phoenix-Interna (`$initial_call`).
    Bricht die Erkennung, meldet die Zeile stumm dauerhaft 0 — genau die
    Spalte, wegen der die Zeile überhaupt gebaut wurde.
  """
  use HubWeb.ConnCase, async: false

  alias Hub.MemoryReporter

  @tmp Path.join(System.tmp_dir!(), "lore-cgroup-test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  defp write_cgroup(files) do
    Enum.each(files, fn {name, content} ->
      File.write!(Path.join(@tmp, name), content)
    end)
  end

  describe "read_cgroup/1" do
    test "liest Limit, Nutzung, Hochwassermarke und anon" do
      write_cgroup(%{
        "memory.max" => "399998976\n",
        "memory.current" => "253968384\n",
        "memory.peak" => "399073280\n",
        "memory.stat" => "anon 188473344\nfile 59179008\nslab 3400512\n"
      })

      assert MemoryReporter.read_cgroup(@tmp) == %{
               limit: 399_998_976,
               current: 253_968_384,
               peak: 399_073_280,
               anon: 188_473_344
             }
    end

    test "ohne echtes Limit (`max`) gibt es gar keine Cgroup-Werte" do
      # Der Fall auf der Entwicklermaschine: die Root-Cgroup hat kein Limit.
      write_cgroup(%{"memory.max" => "max\n", "memory.current" => "12345678\n"})

      assert MemoryReporter.read_cgroup(@tmp) == %{}
    end

    test "fehlendes Verzeichnis ist kein Fehler" do
      assert MemoryReporter.read_cgroup("/gibt/es/nicht") == %{}
    end

    test "einzelne fehlende Datei macht nur dieses Feld nil" do
      write_cgroup(%{"memory.max" => "400000000\n", "memory.current" => "100000000\n"})

      cg = MemoryReporter.read_cgroup(@tmp)

      assert cg[:limit] == 400_000_000
      assert cg[:peak] == nil
      assert cg[:anon] == nil
    end
  end

  describe "cgroup_fields/1" do
    test "leere Cgroup ergibt keine Felder — nicht Felder mit nil" do
      assert MemoryReporter.cgroup_fields(%{}) == []
    end

    test "rechnet in MB und Prozent um" do
      fields =
        MemoryReporter.cgroup_fields(%{
          limit: 399_998_976,
          current: 253_968_384,
          peak: 399_073_280,
          anon: 188_473_344
        })

      assert fields[:cg_limit_mb] == 381
      assert fields[:cg_used_mb] == 242
      assert fields[:cg_peak_mb] == 380
      assert fields[:cg_anon_mb] == 179
      # Issue #1098: anon/limit (179/381), NICHT current/limit (242/381 = 63 %).
      assert fields[:cg_pct] == 47
    end

    test "der Prozentwert rechnet auf anon, nicht auf current" do
      # Die echten Werte der ersten Prod-Messung: `current` enthält 147 MB
      # Seitencache, den der Kernel wegwirft, bevor er killt. Auf `current`
      # gerechnet stünden hier 79 % — im LEERLAUF, bei null Betrachtern, also
      # dauerhaft über der 85-%-Warnschwelle nach dem ersten Betrachter.
      fields =
        MemoryReporter.cgroup_fields(%{
          limit: 399_998_976,
          current: 315_621_376,
          peak: 328_204_288,
          anon: 161_480_704
        })

      assert fields[:cg_used_mb] == 301
      assert fields[:cg_anon_mb] == 154
      assert fields[:cg_pct] == 40
      refute MemoryReporter.warn?(fields)
    end

    test "ohne anon-Wert gibt es keinen Prozentwert statt eines falschen" do
      # `memory.stat` nicht lesbar → lieber keine Zahl als die von `current`.
      fields =
        MemoryReporter.cgroup_fields(%{
          limit: 400_000_000,
          current: 390_000_000,
          peak: nil,
          anon: nil
        })

      assert fields[:cg_used_mb] == 371
      assert fields[:cg_pct] == nil
      refute MemoryReporter.warn?(fields)
    end
  end

  describe "pct/2" do
    test "nicht messbar bleibt nil statt 0" do
      # 0 % und „keine Ahnung" sind verschiedene Aussagen; ein stilles 0
      # sähe im Log wie ein leerer Container aus.
      assert MemoryReporter.pct(nil, 100) == nil
      assert MemoryReporter.pct(50, nil) == nil
      assert MemoryReporter.pct(50, 0) == nil
    end

    test "rundet auf ganze Prozent" do
      assert MemoryReporter.pct(1, 3) == 33
    end
  end

  describe "warn?/1" do
    test "ab 85 % des nicht-reklamierbaren Anteils wird die Zeile zur Warnung" do
      refute MemoryReporter.warn?(cg_pct: 84)
      assert MemoryReporter.warn?(cg_pct: 85)
      assert MemoryReporter.warn?(cg_pct: 99)
    end

    test "ohne Cgroup-Messung wird nie gewarnt" do
      refute MemoryReporter.warn?(total_mb: 160)
    end
  end

  describe "top_processes/1" do
    test "nennt Namen, Größe und Mailbox-Länge" do
      out = MemoryReporter.top_processes(3)

      assert out =~ ~r/\w+\/\d+kb\/q\d+/
      assert length(String.split(out, ",")) == 3
    end
  end

  describe "live_view_count/0" do
    test "zählt einen wirklich gemounteten LiveView", %{conn: conn} do
      stub_reader!(%{
        "users" => [%{"discord_id" => "did-mem", "role" => "admin", "display_name" => "Mem"}]
      })

      before = MemoryReporter.live_view_count()

      user = Fixtures.user(discord_id: "did-mem", role: :admin)
      {:ok, _lv, _html} = conn |> log_in(user) |> live("/settings")

      # Gegenprobe zur Erkennung selbst: bricht das `$initial_call`-Matching,
      # bleibt diese Zahl bei 0 und der Test wird rot — statt dass die
      # Log-Zeile still dauerhaft „live_views=0" behauptet.
      assert MemoryReporter.live_view_count() > before
    end
  end

  describe "collect/1" do
    test "enthält immer die BEAM-Zahlen, Cgroup nur wenn messbar" do
      fields = MemoryReporter.collect(%{cgroup_dir: "/gibt/es/nicht"})

      assert is_integer(fields[:total_mb])
      assert is_integer(fields[:processes_mb])
      assert is_integer(fields[:binary_mb])
      assert is_integer(fields[:procs])
      assert is_integer(fields[:live_views])
      assert is_binary(fields[:top])
      refute Keyword.has_key?(fields, :cg_limit_mb)
    end

    test "mit Cgroup-Verzeichnis stehen die Kernel-Zahlen daneben" do
      write_cgroup(%{
        "memory.max" => "399998976\n",
        "memory.current" => "253968384\n"
      })

      fields = MemoryReporter.collect(%{cgroup_dir: @tmp})

      assert fields[:cg_limit_mb] == 381
      assert fields[:cg_used_mb] == 242
      # Die BEAM-Zahl und die Kernel-Zahl stehen NEBENEINANDER — genau ihre
      # Abweichung war der Befund (BEAM 160 MB vs. Cgroup 242 MiB).
      assert is_integer(fields[:total_mb])
    end
  end
end
