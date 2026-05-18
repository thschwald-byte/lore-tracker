defmodule Hub.MixProject do
  use Mix.Project

  def project do
    [
      app: :hub,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :mnesia],
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
      {:gettext, "~> 0.24"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_discord, "~> 0.7"},
      {:dotenvy, "~> 1.1"}
    ]
  end
end
