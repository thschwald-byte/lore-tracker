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

Hardware-Anforderungen + Mess-Daten: [`docs/Performance.md`](docs/Performance.md).

## Lizenz

LoreTracker steht unter der **[GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE)**.

**Das heißt:**

- ✅ Frei nutzbar, modifizierbar, forkbar, selbst-hostbar — **auch kommerziell** — solange du die Copyleft-Pflichten der AGPL erfüllst (Quellcode deiner Änderungen offenlegen).
- 🔁 **Netzwerk-Copyleft (§13):** wer eine geänderte Version als Netzwerkdienst (SaaS) betreibt, muss den vollständigen Quellcode den Nutzern unter der AGPL zugänglich machen — der bewusste Schutz gegen closed-source-Abgriff eines gehosteten Hubs.
- 💼 Wer die Copyleft-Pflichten **nicht** erfüllen kann/will (proprietäre Einbettung, closed SaaS ohne Quelloffenlegung), kann eine **kommerzielle Lizenz** erwerben. Siehe [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md) (englisch, rechtlich) — Kurzfassung: E-Mail an <thschwald@gmail.com>.

Klassisches Open-Core/Dual-Licensing: der Source ist vollständig Freie Software (AGPL), und der Maintainer finanziert die Entwicklung über den Verkauf von Copyleft-Ausnahmen. Das Verkaufsrecht für proprietäre Nutzung bleibt beim ursprünglichen Autor.

## Mitmachen

Siehe [`CONTRIBUTING.md`](CONTRIBUTING.md). Beiträge sind willkommen; mit dem Einreichen erklärst du dich einverstanden, dass der Maintainer den Beitrag relizensieren darf (inklusive kommerziell).

## Third-party-Lizenzen

LoreTracker baut auf Phoenix, Ecto, Bandit und vielen weiteren ausgezeichneten Open-Source-Bibliotheken auf. Alle Runtime-Dependencies stehen unter permissiven Lizenzen (MIT, Apache-2.0, ISC, BSD-3-Clause). Jede Dependency behält ihre eigene Lizenz unter `deps/<dep>/LICENSE` nach `mix deps.get`.
