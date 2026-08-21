defmodule Worker.Recording.DiarizeLazyTest do
  @moduledoc """
  Issue #1124 (Schnitt B): das Diarisierungs-Modell laedt erst beim ersten
  `/diarize` und wird am Ende des Transcribe-Jobs wieder freigegeben.

  Die drei Waechter hier pinnen jeweils eine Kante, die still versagt:

  1. Der Readiness-Marker. Laedt der Sidecar lazy, meldet sein `/health`
     dauerhaft `"loaded":false`. Bliebe die Readiness daran haengen, stoppte
     `Worker.Sidecar` den Dienst nach `health_max_attempts` (180) als
     `:health_timeout` — drei Minuten nach dem Boot, ohne dass am Sidecar
     etwas falsch waere.
  2. Elixir-Marker gegen Python-`/health`. Beide Seiten muessen dasselbe Feld
     meinen; driftet eine, ist die Folge derselbe stille Stop.
  3. Der Unload-Aufruf am Job-Ende. Faellt er weg, bleibt das Modell liegen und
     nichts wird rot — der Zustand vor diesem Issue, nur unbemerkt.
  """

  # async: false — der Unload-Test fasst echte Worker-Settings an.
  use ExUnit.Case, async: false

  alias Worker.Recording.Diarize
  alias Worker.Sidecar

  @sidecar_py "priv/sidecar/diarization_sidecar.py"
  @transcribe_ex "lib/worker/recording/transcribe.ex"

  # Vom Test-Verzeichnis aus gerechnet, nicht vom cwd: die Suite laeuft mal aus
  # dem Umbrella-Root (`mix test`), mal aus apps/worker (`mix cmd --app worker`).
  @worker_root Path.expand("../../..", __DIR__)
  defp read_worker_file!(rel), do: @worker_root |> Path.join(rel) |> File.read!()

  describe "Readiness-Marker" do
    test "der Diarisierungs-Spec haengt NICHT mehr am geladenen Modell" do
      marker = Sidecar.health_ready_marker(Sidecar.diarization_spec())

      refute marker =~ "loaded",
             "Readiness des lazy ladenden Sidecars darf nicht am Modell-Zustand haengen"

      assert marker =~ "status"
      assert marker =~ "ok"
    end

    test "Specs ohne eigenen Marker behalten das alte Verhalten" do
      assert Sidecar.health_ready_marker(%{name: :irgendwas}) == "\"loaded\":true"
      assert Sidecar.health_ready_marker(%{health_ready_marker: nil}) == "\"loaded\":true"
    end

    test "der Elixir-Marker passt zu dem, was das Python-/health liefert" do
      py = read_worker_file!(@sidecar_py)
      marker = Sidecar.health_ready_marker(Sidecar.diarization_spec())

      # Der Marker ist JSON ohne Leerzeichen ("status":"ok"), die Quelle ist ein
      # Python-Dict ("status": "ok") — verglichen wird deshalb leerzeichenfrei.
      health_block =
        py
        |> String.split("@app.get(\"/health\")")
        |> List.last()
        |> String.split("@app.post")
        |> List.first()
        |> String.replace(~r/\s+/, "")

      assert health_block =~ String.replace(marker, " ", ""),
             "Python-/health liefert den Marker nicht mehr, den Worker.Sidecar erwartet"
    end
  end

  describe "Sidecar-Quelltext" do
    test "das Modell wird nicht mehr im lifespan geladen" do
      py = read_worker_file!(@sidecar_py)

      lifespan =
        py
        |> String.split("async def lifespan")
        |> List.last()
        |> String.split("\ndef ")
        |> List.first()

      refute lifespan =~ "from_pretrained",
             "Modell-Load gehoert seit #1124 in _ensure_pipeline, nicht in den Startup"
    end

    test "es gibt einen /unload-Endpunkt und einen Lazy-Load-Pfad" do
      py = read_worker_file!(@sidecar_py)

      assert py =~ "@app.post(\"/unload\")"
      assert py =~ "def _ensure_pipeline"
      assert py =~ "torch.cuda.empty_cache()"
    end
  end

  describe "Unload" do
    test "ohne konfigurierten Sidecar ist unload/0 ein No-op" do
      alt = Worker.Settings.get(:diarization_sidecar_url)

      try do
        Worker.Settings.put(:diarization_sidecar_url, nil)
        assert Diarize.unload() == :ok
      after
        # Wiederherstellen ist Pflicht, nicht Hoeflichkeit: die Settings liegen
        # in Mnesia und ueberleben den Testlauf.
        Worker.Settings.put(:diarization_sidecar_url, alt)
      end
    end

    test "der Transcribe-Job entlaedt am Ende, und nur wenn diarisiert wurde" do
      src = read_worker_file!(@transcribe_ex)

      run_mixed =
        src
        |> String.split("def run_mixed")
        |> List.last()
        |> String.split("\n  defp ")
        |> List.first()

      assert run_mixed =~ "after",
             "Unload gehoert in den after-Block, sonst ueberlebt das Modell einen Fehlerpfad"

      assert run_mixed =~ "Worker.Recording.Diarize.unload()"

      assert run_mixed =~ ~r/if\s+multi_files\s*!=\s*\[\]/,
             "Unload nur bei Raummikro-Jobs — sonst Lograuschen in jedem Discord-Job"
    end
  end
end
