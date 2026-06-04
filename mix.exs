defmodule LoreTracker.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  # Prod release for the hosted Hub. Worker is intentionally excluded — it
  # is a local-install on the admin's machine, not part of the container.
  defp releases do
    [
      lore_tracker: [
        applications: [
          hub: :permanent,
          shared: :permanent
        ],
        include_executables_for: [:unix]
      ]
    ]
  end

  defp deps do
    [
      # Issue #544: AST-Linter (Smells + Custom-Checks). Umbrella-weit, nur
      # dev/test, kein Runtime-Dep → fließt nicht in den Hub-Release. Custom-
      # Checks werden via `.credo.exs` `requires:` geladen (nicht app-kompiliert,
      # daher kein `use Credo.Check` im Prod-Compile-Pfad).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --app hub mix assets.setup"],
      "assets.setup": ["cmd --app hub mix assets.setup"],
      "assets.build": ["cmd --app hub mix assets.build"],
      "assets.deploy": ["cmd --app hub mix assets.deploy"],
      # Gigalixir/CI hook: build the Hub release including digested assets.
      "release.hub": ["assets.deploy", "release lore_tracker"]
    ]
  end
end
