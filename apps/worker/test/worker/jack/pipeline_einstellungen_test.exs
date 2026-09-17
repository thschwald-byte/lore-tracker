defmodule Worker.Jack.PipelineEinstellungenTest do
  # J4 (#1207): Jacks Regler kommen aus Worker.Settings. Ohne gesetzte Keys muss
  # exakt das Modell der Messreihe C herauskommen — sonst änderte der Umbau
  # Jacks Verhalten, ohne dass jemand etwas eingestellt hat. Nicht async:
  # worker_state ist ein Singleton (Muster settings_test.exs).
  use ExUnit.Case, async: false

  alias Worker.Jack.{Messlauf, Phase, Pipeline}
  alias Worker.Settings

  setup do
    {:atomic, :ok} = :mnesia.clear_table(Worker.Schema.Mnesia.worker_state())
    :ok
  end

  defp endpunkt_und_modell! do
    Settings.put(:local_endpoint, "http://x:1")
    Settings.put(:model_stage2_local, "qwen3.8:27b")
  end

  describe "modell/0" do
    test "ohne gesetzte Regler: exakt das Modell der Reihe C" do
      endpunkt_und_modell!()

      assert {:ok, {modul, o}} = Pipeline.modell()

      {ref_modul, ref} =
        Messlauf.modell_reihe_c(endpunkt: "http://x:1", modell_name: "qwen3.8:27b")

      assert modul == ref_modul
      # Reihenfolge der Keyword-Liste ist egal, der Inhalt nicht.
      assert Map.new(o) == Map.new(ref)

      assert o[:temperatur] == 0.7
      assert o[:max_ausgabe] == 60_000
      assert o[:extra] == %{"top_p" => 0.8, "frequency_penalty" => 0.4}
    end

    test "gesetzte Regler werden durchgereicht" do
      endpunkt_und_modell!()
      Settings.put(:jack_temperature, 0.3)
      Settings.put(:jack_top_p, 0.95)
      Settings.put(:jack_frequency_penalty, 0.0)
      Settings.put(:jack_max_tokens, 12_000)

      assert {:ok, {Worker.Agent.Modell.Ollama, o}} = Pipeline.modell()

      assert o[:endpunkt] == "http://x:1"
      assert o[:modell] == "qwen3.8:27b"
      assert o[:temperatur] == 0.3
      assert o[:max_ausgabe] == 12_000
      assert o[:extra] == %{"top_p" => 0.95, "frequency_penalty" => 0.0}
    end

    test "ohne Endpunkt oder Modell ein Fehler, kein stiller Rückfall" do
      assert Pipeline.modell() == {:error, :no_local_endpoint_configured}

      Settings.put(:local_endpoint, "http://x:1")
      assert Pipeline.modell() == {:error, {:no_model_configured, 2}}
    end
  end

  describe "kontext_fenster/0" do
    test "Default 98 304 — derselbe Wert wie das Fenster der Messläufe" do
      assert Pipeline.kontext_fenster() == {:ok, 98_304}
    end

    test "ein gesetzter Wert geht durch, bis hinunter zum Mindestfenster" do
      Settings.put(:ctx_jack, 32_768)
      assert Pipeline.kontext_fenster() == {:ok, 32_768}

      mindestens = Phase.mindestfenster()
      Settings.put(:ctx_jack, mindestens)
      assert Pipeline.kontext_fenster() == {:ok, mindestens}
    end

    test "unter dem Mindestfenster oder keine ganze Zahl: ein Fehler vor dem Lauf" do
      mindestens = Phase.mindestfenster()

      Settings.put(:ctx_jack, mindestens - 1)

      assert Pipeline.kontext_fenster() ==
               {:error, {:ctx_jack_ungueltig, mindestens - 1, mindestens}}

      Settings.put(:ctx_jack, "98304")
      assert Pipeline.kontext_fenster() == {:error, {:ctx_jack_ungueltig, "98304", mindestens}}

      # Sichtbar in /admin/errors als eigene Klasse, nicht als "other".
      assert Worker.Recording.Pipeline.classify_pipeline_error(
               {:ctx_jack_ungueltig, 8000, mindestens}
             ) == "ctx_jack_ungueltig"
    end

    test "das Mindestfenster fasst Reserve und Behalten der Kompaktierung" do
      # Worker.Agent.Lauf verlangt reserve + behalten < fenster (4096 + 8000).
      assert Phase.mindestfenster() == 4096 + 8000 + 1
    end
  end
end
