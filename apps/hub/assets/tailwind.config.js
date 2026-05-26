// LoreTracker tailwind config — dark fantasy/tech palette to match the mockups.
//
// Heroicons are imported via Phoenix's standard plugin pattern: see
// https://hexdocs.pm/phoenix/asset_management.html#css

const plugin = require("tailwindcss/plugin");
const fs = require("fs");
const path = require("path");

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/hub_web.ex",
    "../lib/hub_web/**/*.*ex",
    "../../../deps/live_select/lib/**/*.*ex",
  ],
  theme: {
    extend: {
      colors: {
        // Design System v0.1 (Issue #194) — semantic tokens via CSS-Vars (RGB-Triplets)
        // mit <alpha-value>-Support, damit `bg-primary/40` etc. funktioniert.
        bg:               "rgb(var(--color-bg) / <alpha-value>)",
        surface:          "rgb(var(--color-surface) / <alpha-value>)",
        "surface-2":      "rgb(var(--color-surface-2) / <alpha-value>)",
        border:           "rgb(var(--color-border) / <alpha-value>)",
        fg:               "rgb(var(--color-fg) / <alpha-value>)",
        "fg-muted":       "rgb(var(--color-fg-muted) / <alpha-value>)",
        primary:          "rgb(var(--color-primary) / <alpha-value>)",
        "primary-bright": "rgb(var(--color-primary-bright) / <alpha-value>)",
        "primary-fg":     "rgb(var(--color-primary-fg) / <alpha-value>)",
        danger:           "rgb(var(--color-danger) / <alpha-value>)",
        success:          "rgb(var(--color-success) / <alpha-value>)",
        warning:          "rgb(var(--color-warning) / <alpha-value>)",

        // Legacy-Aliase (Sidebar + ältere components nutzen die noch).
        // Werden im Konsistenz-Check-Folge-Issue auf semantic tokens umgestellt.
        "bg-0":        "rgb(var(--color-bg) / <alpha-value>)",
        "bg-1":        "rgb(var(--color-surface) / <alpha-value>)",
        "bg-2":        "rgb(var(--color-surface-2) / <alpha-value>)",
        "bg-3":        "rgb(var(--color-surface-2) / <alpha-value>)",
        accent:        "rgb(var(--color-primary) / <alpha-value>)",
        "accent-soft": "rgb(var(--color-primary-bright) / <alpha-value>)",
        ink: {
          0: "rgb(var(--color-fg) / <alpha-value>)",
          1: "rgb(var(--color-fg) / <alpha-value>)",
          2: "rgb(var(--color-fg-muted) / <alpha-value>)",
        },
        rec: {
          DEFAULT: "rgb(var(--color-danger) / <alpha-value>)",
          soft:    "rgb(var(--color-danger) / <alpha-value>)",
        },
      },
      fontFamily: {
        sans: ["Inter", "system-ui", "sans-serif"],
        display: ["Cinzel", "Georgia", "serif"],
      },
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    // Heroicons plugin (inline-svg via Tailwind classes like `hero-bell`).
    plugin(function ({ matchComponents, theme }) {
      const iconsDir = path.join(__dirname, "../../../deps/heroicons/optimized");
      const values = {};
      const icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"],
      ];
      icons.forEach(([suffix, dir]) => {
        try {
          fs.readdirSync(path.join(iconsDir, dir)).forEach((file) => {
            const name = path.basename(file, ".svg") + suffix;
            values[name] = { name, fullPath: path.join(iconsDir, dir, file) };
          });
        } catch (_e) {
          // Heroicons not yet fetched (e.g. fresh checkout before `mix deps.get`).
        }
      });
      matchComponents(
        {
          hero: ({ name, fullPath }) => {
            const content = fs
              .readFileSync(fullPath)
              .toString()
              .replace(/\r?\n|\r/g, "");
            const size = theme("spacing.6");
            return {
              [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
              "-webkit-mask": `var(--hero-${name})`,
              mask: `var(--hero-${name})`,
              "mask-repeat": "no-repeat",
              "background-color": "currentColor",
              "vertical-align": "middle",
              display: "inline-block",
              width: size,
              height: size,
            };
          },
        },
        { values }
      );
    }),
  ],
};
