# LoreTracker

Session-Aufnahme, Transkription und Lore-Tracking für Pen-&-Paper-Rollenspiel-Kampagnen.

**Status: frühe Entwicklung.** Rauh Kanten, Breaking Changes und unfertige Features sind zu erwarten.

> **Note for non-German readers:** Most documentation in this repo is written in German (the maintainer is most fluent in German). See [`CLAUDE.md`](CLAUDE.md) → "Language" for details. Translation tools work fine here.

## Was es tut

LoreTracker ist ein Elixir-Umbrella-Projekt mit zwei Haupt-Komponenten:

- **Hub** (`apps/hub`) — Phoenix-LiveView-Webapp. Hosted Kampagnen, zeigt Transkripte, liefert Resümees / Epos / Chronik pro Kampagne. Deployment-ready (z.B. Gigalixir).
- **Worker** (`apps/worker`) — Lokale Installation auf dem Rechner des Spielleiters. Nimmt Audio während der Session auf, transkribiert via Whisper, lässt lokale LLM-Stages über das Transkript laufen und repliziert die Ergebnisse via Event-Log zurück in den Hub.

Eine `shared`-Bibliotheks-App enthält den von beiden Komponenten genutzten Code (Events, Mnesia-Helper, Wire-Protokoll).

## Schnellstart (Entwicklung)

Setzt Elixir `~> 1.19` und Erlang/OTP voraus.

```bash
mix deps.get
mix compile
cd apps/hub && mix phx.server   # Hub auf http://localhost:4000
```

Für den lokalen Worker gegen deinen Dev-Hub siehe `CLAUDE.md` → „Local multi-BEAM setup" und [`docs/Worker-Setup.md`](docs/Worker-Setup.md).

## Lizenz

LoreTracker steht unter der **[PolyForm Noncommercial License 1.0.0](LICENSE)**.

**Das heißt:**

- ✅ Frei nutzbar, modifizierbar, forkbar und selbst-hostbar für persönliche, Hobby-, Forschungs-, Bildungs-, gemeinnützige und sonstige nicht-kommerzielle Zwecke.
- ❌ Kommerzielle Nutzung braucht eine separate kommerzielle Lizenz. Siehe [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md) (englisch, rechtlich) — Kurzfassung: E-Mail an <thschwald@gmail.com>.

Bewusste Entscheidung: der Source ist offen, damit jeder ihn lesen, lernen, forken und für die eigene Spielrunde laufen lassen kann — aber das Verkaufsrecht bleibt beim ursprünglichen Autor.

## Mitmachen

Siehe [`CONTRIBUTING.md`](CONTRIBUTING.md). Beiträge sind willkommen; mit dem Einreichen erklärst du dich einverstanden, dass der Maintainer den Beitrag relizensieren darf (inklusive kommerziell).

## Third-party-Lizenzen

LoreTracker baut auf Phoenix, Ecto, Bandit und vielen weiteren ausgezeichneten Open-Source-Bibliotheken auf. Alle Runtime-Dependencies stehen unter permissiven Lizenzen (MIT, Apache-2.0, ISC, BSD-3-Clause). Jede Dependency behält ihre eigene Lizenz unter `deps/<dep>/LICENSE` nach `mix deps.get`.
