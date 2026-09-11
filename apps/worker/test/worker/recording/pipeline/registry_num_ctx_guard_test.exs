defmodule Worker.Recording.Pipeline.RegistryNumCtxGuardTest do
  # J4 (#1207): Entity- und Thread-Registry laufen auf Jacks Modell und
  # schicken bewusst KEIN num_ctx mit — sonst lüde Ollama das Modell neben
  # Jacks Instanz mit eigenem Fenster neu (mit ctx_jack = 98 304 womöglich über
  # den Grafikspeicher hinaus). Ein zurückgekehrtes num_ctx erzeugt keinen
  # Fehler, nur einen langsamen oder ausweichenden Lauf; deshalb ein
  # Quelltext-Wächter.
  use ExUnit.Case, async: true

  @dateien [
    "lib/worker/recording/pipeline/entity_registry.ex",
    "lib/worker/recording/pipeline/thread_registry.ex"
  ]

  test "die Registries setzen kein num_ctx in ihren LLM-Optionen" do
    for datei <- @dateien do
      quelltext = File.read!(datei)

      refute quelltext =~ ~r/num_ctx:\s/,
             "#{datei} setzt wieder num_ctx in den Optionen"
    end
  end
end
