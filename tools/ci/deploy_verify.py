#!/usr/bin/env python3
"""Issue #876: Post-Deploy-Verify gegen die Gigalixir-API (Free-Tier-Guard).

Der deploy-Step endet mit dem `git push` — Buildpack-Build + Pod-Start passieren
DANACH, unbeobachtet. Ein OOM-Crash-Loop (Free-Tier: 400 MB bei size 0.4) oder
ein nie hochkommendes Release blieben bisher unsichtbar, bis ein User klagt.

Dieser Check läuft als eigener CI-Step nach dem deploy und verifiziert:

1. Das Release mit CI_COMMIT_SHA erscheint in /releases (Buildpack-Build ok).
2. Alle Pods laufen auf dieser Release-Version mit Status "Healthy",
   replicas_running == replicas_desired (Pod-Start ok).
3. Kein Pod hat lastState terminated/OOMKilled (kein Crash-Loop).
4. Free-Tier-Konformität: size <= 0.5, replicas_desired == 1
   (FREE erlaubt max 0.5 / genau 1 Replica — Drift schlüge beim nächsten
   Scale fehl oder eskaliert Kosten beim Tier-Wechsel).
5. HTTP-Check auf https://<app>.gigalixirapp.com/ liefert 200/301/302/303.
6. Grace-Recheck nach 30 s: Pod weiterhin Healthy (fängt den schnellen
   Crash-Loop direkt nach dem Boot).

Nur Stdlib (urllib) — läuft im python:3.12-slim-Image ohne pip-Install.
Env: GIGALIXIR_EMAIL, GIGALIXIR_API_KEY, GIGALIXIR_APP_NAME, CI_COMMIT_SHA.

API-Shapes (verifiziert 2026-07-17 gegen api.gigalixir.com):
  GET /api/apps/<app>/releases -> {"data": [{"version", "sha", "created_at", ...}, ...]}
  GET /api/apps/<app>/status   -> {"data": {"size", "replicas_running",
                                   "replicas_desired", "pods": [{"version",
                                   "status", "sha", "lastState"}, ...]}}
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.gigalixir.com/api/apps"
RELEASE_POLL_TIMEOUT_S = 15 * 60  # Buildpack-Build braucht typisch 5-10 min
POD_POLL_TIMEOUT_S = 5 * 60
POLL_INTERVAL_S = 20
GRACE_RECHECK_S = 30
FREE_TIER_MAX_SIZE = 0.5
HTTP_OK = {200, 301, 302, 303}


def log(msg):
    print(f"[deploy_verify] {msg}", flush=True)


def fail(msg):
    log(f"FEHLER: {msg}")
    sys.exit(1)


def api_get(path, auth_header):
    req = urllib.request.Request(f"{API}/{path}", headers={"Authorization": auth_header})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["data"]


def poll(what, timeout_s, fn):
    """Ruft fn() alle POLL_INTERVAL_S auf, bis es einen Wert liefert (nicht None).

    API-/Netzfehler zählen als "noch nicht da" (Gigalixir kann während des
    Deploys kurz 5xx liefern) — erst der Gesamt-Timeout ist ein Fehler.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result is not None:
                return result
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            log(f"{what}: API-Fehler ({e}), weiter pollen")
        time.sleep(POLL_INTERVAL_S)
    fail(f"Timeout ({timeout_s}s) beim Warten auf: {what}")


def check_no_oomkill(pods):
    for pod in pods:
        last = pod.get("lastState") or {}
        terminated = last.get("terminated") or {}
        if terminated.get("reason") == "OOMKilled":
            fail(
                f"Pod {pod.get('name')} wurde OOMKilled (lastState={last}) — "
                "RAM-Limit des Free-Tier-Pods gerissen. Rollback erwägen: "
                "gigalixir releases:rollback -a <app>"
            )


def check_status(status, expected_version):
    pods = status.get("pods") or []
    check_no_oomkill(pods)

    running = status.get("replicas_running")
    desired = status.get("replicas_desired")
    healthy = [p for p in pods if p.get("status") == "Healthy" and p.get("version") == expected_version]

    if running == desired and desired >= 1 and len(healthy) == len(pods) == desired:
        return status
    log(
        f"Pods noch nicht bereit: running={running}/{desired}, "
        f"healthy-auf-v{expected_version}={len(healthy)}/{len(pods)}"
    )
    return None


def check_http(app):
    url = f"https://{app}.gigalixirapp.com/"

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(url, timeout=30) as resp:
            code = resp.status
    except urllib.error.HTTPError as e:
        code = e.code
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail(f"HTTP-Check {url} nicht erreichbar: {e}")

    if code not in HTTP_OK:
        fail(f"HTTP-Check {url} lieferte {code} (erwartet: {sorted(HTTP_OK)})")
    log(f"HTTP-Check ok: {url} -> {code}")


def main():
    email = os.environ["GIGALIXIR_EMAIL"]
    api_key = os.environ["GIGALIXIR_API_KEY"]
    app = os.environ["GIGALIXIR_APP_NAME"]
    sha = os.environ["CI_COMMIT_SHA"]
    auth = "Basic " + base64.b64encode(f"{email}:{api_key}".encode()).decode()

    log(f"Warte auf Release mit sha={sha} …")

    def release_arrived():
        releases = api_get(f"{app}/releases", auth)
        if releases and releases[0].get("sha") == sha:
            return releases[0]
        newest = releases[0].get("sha", "?")[:12] if releases else "keins"
        log(f"Neuestes Release: {newest} (warte auf {sha[:12]})")
        return None

    release = poll("Release im Buildpack", RELEASE_POLL_TIMEOUT_S, release_arrived)
    version = str(release["version"])
    log(f"Release v{version} ist da. Warte auf Healthy-Pods …")

    status = poll(
        f"Pods Healthy auf v{version}",
        POD_POLL_TIMEOUT_S,
        lambda: check_status(api_get(f"{app}/status", auth), version),
    )

    # Free-Tier-Konformität (Punkt 4)
    size = status.get("size")
    desired = status.get("replicas_desired")
    if size is None or size > FREE_TIER_MAX_SIZE:
        fail(f"size={size} überschreitet Free-Tier-Limit {FREE_TIER_MAX_SIZE}")
    if desired != 1:
        fail(f"replicas_desired={desired} — Free-Tier erlaubt genau 1 Replica")
    log(f"Free-Tier-konform: size={size}, replicas={desired}")

    check_http(app)

    log(f"Grace-Recheck in {GRACE_RECHECK_S}s (fängt Crash-Loop nach Boot) …")
    time.sleep(GRACE_RECHECK_S)
    final = api_get(f"{app}/status", auth)
    if check_status(final, version) is None:
        fail("Pod nach Grace-Periode nicht mehr Healthy — Crash-Loop?")

    log(f"Deploy verifiziert: v{version} ({sha[:12]}) Healthy, Free-Tier-konform.")


if __name__ == "__main__":
    main()
