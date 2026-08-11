defmodule Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :worker,
      version: "0.156.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # Issue #537: Coverage-Report (mix coveralls.json) für mix lore.coverage_floor.
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.json": :test,
        "coveralls.html": :test
      ]
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
      {:req, "~> 0.7"},
      # Issue #985 Slice 1 (Discord-Bot-Voice-Capture-Epic): DAVE-Receive-Decrypt
      # (Crypto.dave_decrypt) gibt es NUR auf nostrum-main — das neueste Hex-
      # Release (0.10.4) liegt vor dem DAVE-Merge. Der reale Pin lebt im
      # committeten mix.lock (Mix löst git-Deps ohne branch:/ref: NICHT bei
      # jedem deps.get neu auf — nur ein expliziter `mix deps.update nostrum`
      # bumpt). :dave (Rust-NIF) wird transitiv via rustler_precompiled gezogen,
      # kein lokaler Rust-Toolchain nötig (precompiled Target für x86_64 Linux
      # vorhanden — verifiziert im #941-Spike auf dieser Maschine).
      {:nostrum, github: "Kraigie/nostrum"},
      # Issue #546: Mutation-Testing (MIT-lizenziert — FOSS-kompatibel, anders als
      # muzak/CC-BY-NC). dev-only, kein Runtime-Dep. Periodischer Lauf via
      # `mix muex` (kein hartes CI-Gate — zu langsam), siehe CONTRIBUTING.md.
      {:muex, "~> 0.6", only: :dev, runtime: false},
      # Issue #537: Coverage-Report + per-Modul-Floor (mix lore.coverage_floor).
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end
end
