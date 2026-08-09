#!/usr/bin/env python3
"""Issue #703: informativer Pre-Deploy-Check, ob gerade eine Session-
Aufnahme auf Prod läuft.

Läuft als erste Commands im bestehenden `deploy`-Step, VOR dem `git push
--force gigalixir` — der Restart selbst ist danach nicht mehr aufschiebbar.
Bewusst NIE blockierend (immer exit 0): Sessions laufen stundenlang, ein
Blocking-Gate auf dem Free-Tier-Single-Replica-Setup wäre ein
Verfügbarkeits-Risiko und würde Merges am Spielabend verhindern. Eine laute
Log-Zeile reicht als Signal für den Menschen, der den Merge-Zeitpunkt
kontrolliert (User-Entscheidung, kein technischer Kompromiss).

Netzwerk-/HTTP-Fehler sind fail-open (keine Warnung, kein Fehler) — u.a.
der erwartete Fall beim ALLERERSTEN Deploy nach diesem Merge, wo die noch
laufende alte Prod-Version den /health/recording-Endpoint noch nicht kennt
(404).

Nur Stdlib (urllib) — läuft im python:3.12-slim-Image ohne pip-Install.
Env: GIGALIXIR_APP_NAME (bereits im deploy-Step gesetzt).
"""

import json
import os
import sys
import urllib.request

TIMEOUT_S = 10


def log(msg):
    print(f"[deploy_gate_check] {msg}", flush=True)


def main():
    app = os.environ.get("GIGALIXIR_APP_NAME")
    if not app:
        log("GIGALIXIR_APP_NAME nicht gesetzt — Check übersprungen (fail-open).")
        return

    url = f"https://{app}.gigalixirapp.com/health/recording"

    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT_S) as resp:
            data = json.load(resp)
    except Exception as exc:
        log(f"Check übersprungen ({exc}) — fail-open, Deploy läuft weiter.")
        return

    if data.get("active_recording"):
        log("=" * 66)
        log("WARNUNG: Es läuft aktuell eine Session-Aufnahme auf Prod!")
        log("Der Deploy startet den Hub trotzdem neu (Issue #703: warn-only,")
        log("kein Blocking-Gate). Browser-Mikro reconnectet automatisch, aber")
        log("der Audio-Pfad ist für die Restart-Dauer unterbrochen.")
        log("=" * 66)
    else:
        log("Keine aktive Aufnahme erkannt.")


if __name__ == "__main__":
    main()
    sys.exit(0)
