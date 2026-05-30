defmodule Hub.MixProject do
  use Mix.Project

  def project do
    [
      app: :hub,
      version: "1.31.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind hub", "esbuild hub"],
      "assets.deploy": [
        "tailwind hub --minify",
        "esbuild hub --minify",
        "phx.digest"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Hub.Application, []}
    ]
  end

  defp deps do
    [
      {:shared, in_umbrella: true},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      # Issue #291: Markdown → HTML für Resümee/Epos/Chronik-Anzeige.
      {:earmark, "~> 1.4"},
      {:gettext, "~> 0.24"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_discord, "~> 0.7"},
      {:dotenvy, "~> 1.1"},
      {:joken, "~> 2.6"},
      {:req, "~> 0.5"},
      {:tabler_icons, "~> 0.6"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:live_select, "~> 1.5"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1}
    ]
  end
end
