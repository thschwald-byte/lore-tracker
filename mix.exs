defmodule LoreTracker.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd --app hub mix assets.setup"],
      "assets.setup": ["cmd --app hub mix assets.setup"],
      "assets.build": ["cmd --app hub mix assets.build"],
      "assets.deploy": ["cmd --app hub mix assets.deploy"]
    ]
  end
end
