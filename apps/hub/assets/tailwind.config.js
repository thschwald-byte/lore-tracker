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
  ],
  theme: {
    extend: {
      colors: {
        // Background ramp
        bg: {
          0: "#0a0e1a", // deepest (page background)
          1: "#11172a", // panel
          2: "#1a2138", // card
          3: "#222c47", // hover / sidebar item
        },
        // Teal/cyan accent — matches the d20 glow in the mockup
        accent: {
          DEFAULT: "#3fc7d3",
          soft: "#7cdde5",
          glow: "#3fc7d3",
        },
        ink: {
          0: "#e8edf5", // primary text
          1: "#b6c1d4", // secondary
          2: "#7c89a4", // muted
        },
        rec: {
          DEFAULT: "#e04848",
          soft: "#ff6b6b",
        },
      },
      boxShadow: {
        glow: "0 0 24px rgba(63, 199, 211, 0.35)",
        "glow-sm": "0 0 12px rgba(63, 199, 211, 0.25)",
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
