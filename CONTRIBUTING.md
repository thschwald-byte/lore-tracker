# Contributing to LoreTracker

Thanks for your interest in contributing!

## Licensing of contributions

LoreTracker is released under the **PolyForm Noncommercial License 1.0.0** (see `LICENSE`), with the maintainer also offering it under a separate commercial license (see `LICENSE-COMMERCIAL.md`).

**By submitting a contribution** (pull request, patch, suggestion that gets incorporated into the codebase, etc.), you agree that:

1. Your contribution is licensed to the project under the **PolyForm Noncommercial License 1.0.0** on the same terms as the rest of the project.
2. You **grant the maintainer (Thomas Falk) the perpetual, worldwide, royalty-free right to relicense your contribution under any other license**, including commercial licenses, at the maintainer's sole discretion.
3. You have the legal right to make the contribution and grant these rights (i.e., the code is yours, or you have your employer's permission, etc.).
4. Your contribution is provided **as is**, with no warranty.

If you cannot agree to these terms, please do not submit a contribution. If anything is unclear, open an issue first and we'll talk it through.

## Where to start

- **Issues**: <https://codeberg.org/tomloresys/lore-tracker/issues>
- Pick an open issue, or open a new one describing what you want to do, before sending code.

## Workflow

1. Fork or branch off `master`.
2. Branch naming: `issue-<N>-short-slug` (e.g. `issue-12-export-markdown`).
3. Run `mix format` before committing.
4. Keep commits small and focused — `mix compile` should pass at each commit.
5. Open a pull request against `master`.
6. The maintainer will review, request changes if needed, and merge.

## Code style

- Follow standard Elixir / Phoenix conventions.
- `mix format` is canonical — no debate.
- Keep modules in the right umbrella app (`hub`, `worker`, `shared`).
- Document non-obvious *why* in comments, not *what*.

## Questions

Open an issue or email <thschwald@gmail.com>.
