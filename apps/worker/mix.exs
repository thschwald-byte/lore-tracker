defmodule Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :worker,
      version: "0.31.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :mnesia],
      mod: {Worker.Application, []}
    ]
  end

  defp deps do
    [
      {:shared, in_umbrella: true},
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:slipstream, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:dotenvy, "~> 1.1"},
      {:req, "~> 0.5"}
    ]
  end
end
