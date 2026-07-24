defmodule Hub.MixProject do
  use Mix.Project

  def project do
    [
      app: :hub,
      version: "1.92.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Issue #537: Coverage-Floor pro kritischem Modul. ExCoveralls erzeugt den
      # Report (`mix coveralls.json` → cover/excoveralls.json); die per-Modul-
      # Floors prüft `mix lore.coverage_floor` (ExCoveralls kennt nur einen
      # globalen minimum_coverage).
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
      # Issue #362: KEIN plug_cowboy — der Hub serviert via Bandit
      # (Bandit.PhoenixAdapter, s. config). Das vormals generierte plug_cowboy war
      # ungenutzt und zog cowboy + cowlib (GHSA-g2wm-735q-3f56, low) in den
      # internet-facing Hub-Release. Entfernt → kleinere Prod-Angriffsfläche.
      {:jason, "~> 1.4"},
      # Issue #291: Markdown → HTML für Resümee/Epos/Chronik-Anzeige.
      {:earmark, "~> 1.4"},
      # Issue #385: XSS-Sanitizer für user-editierten Markdown (Chronik-
      # Body). Earmark mit escape: true ist erste Schicht, HtmlSanitizeEx
      # zweite — Defense-in-Depth.
      {:html_sanitize_ex, "~> 1.4"},
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
       depth: 1},
      # Issue #66: phoenix_live_view 1.1.x braucht lazy_html als Test-Dep für das
      # DOM-Parsing in Phoenix.LiveViewTest (LiveView-Mount-Tests).
      {:lazy_html, ">= 0.1.0", only: :test},
      # Issue #544: credo (+ Credo.Test.Case) für den AST-Custom-Check-Test, der
      # in der hub-Suite läuft (CI testet hub-scoped). dev/test-only, kein
      # Runtime-Dep → fließt nicht in den Hub-Release.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Issue #546: Mutation-Testing (MIT — FOSS-kompatibel, anders als muzak/
      # CC-BY-NC). dev-only, periodischer `mix muex`-Lauf auf den Hotspots
      # (z.B. HubWeb.Permissions), kein hartes CI-Gate. Siehe CONTRIBUTING.md.
      {:muex, "~> 0.6", only: :dev, runtime: false},
      # Issue #537: Coverage-Report + per-Modul-Floor (mix lore.coverage_floor).
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end
end
