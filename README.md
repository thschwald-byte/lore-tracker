# LoreTracker

Session recording, transcription, and lore tracking for tabletop RPG campaigns.

**Status: early development.** Expect rough edges, breaking changes, and incomplete features.

## What it does

LoreTracker is an Elixir umbrella project with two main components:

- **Hub** (`apps/hub`) — Phoenix LiveView web app. Hosts campaigns, displays transcripts, surfaces summaries / epic recaps / chronicles per campaign. Designed to be deployable (e.g. Gigalixir).
- **Worker** (`apps/worker`) — Local install on the GM's machine. Records audio during sessions, transcribes via Whisper, runs local LLM passes for summarization, and replicates results into the Hub via an event log.

A `shared` library app holds code reused by both.

## Quick start (development)

Requires Elixir `~> 1.19` and Erlang/OTP.

```bash
mix deps.get
mix compile
cd apps/hub && mix phx.server   # hub on http://localhost:4000
```

For the local worker against your dev hub, see `CLAUDE.md` → "Local multi-BEAM setup".

## License

LoreTracker is licensed under the **[PolyForm Noncommercial License 1.0.0](LICENSE)**.

**This means:**

- ✅ Free to use, modify, fork, and self-host for personal, hobby, research, educational, charitable, and other noncommercial purposes.
- ❌ Commercial use requires a separate commercial license. See [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md) — short version: email <thschwald@gmail.com>.

This is a deliberate choice: the source is open so anyone can read, learn, fork, and run it for their own table — but the right to sell it stays with the original author.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributions are welcome; by submitting one you agree the maintainer may relicense it (including commercially).

## Third-party licenses

LoreTracker builds on top of Phoenix, Ecto, Bandit, and many other excellent open-source libraries. All runtime dependencies are under permissive licenses (MIT, Apache-2.0, ISC, BSD-3-Clause). Each dependency keeps its own license under `deps/<dep>/LICENSE` after `mix deps.get`.
