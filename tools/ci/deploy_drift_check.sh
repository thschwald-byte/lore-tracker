#!/bin/sh
# Issue #1224: läuft in Prod wirklich der master-Stand? (Woodpecker-Cron, OHNE Secrets)
#
# Der Fall, für den es diesen Check gibt: Ein master-Lauf wird **gekillt**,
# bevor er `deploy` erreicht — etwa weil 30 Sekunden später ein zweiter Merge
# denselben Branch anstösst (real: Lauf 1089 am 17.09.2026, Lauf 1113 am
# 19.09.). Der Commit steht dann in master, aber nicht in Prod, und **nichts
# meldet das**:
#
#   * `deploy_verify` prüft gründlich — aber nur INNERHALB eines Laufs, der
#     bis dorthin kommt. Ein gekillter Lauf führt es nie aus.
#   * `freetier_check.sh` prüft, ob Prod ANTWORTET und ob der letzte Commit
#     jünger als 21 Tage ist. Beides bleibt grün, während Prod einen zwei
#     Wochen alten Stand ausliefert.
#   * Die Branch-Protection endet beim Merge.
#
# Am 17.09. fiel es nur auf, weil jemand die Releases von Hand verglichen hat.
#
# Die Quelle ist `/health/version` am Hub (#1224) statt der Gigalixir-API:
# Die drei `gigalixir_*`-Secrets sind push-scoped und in einem Cron-Lauf
# unsichtbar — derselbe Grund, aus dem `freetier_check.sh` ohne sie auskommt.
set -eu

PROD_URL="https://loretracker.gigalixirapp.com/health/version"
# Unterhalb dieser Frist ist ein Unterschied normal: Buildpack-Build und
# Pod-Start brauchen Minuten, und der Cron kann kurz nach einem Merge laufen.
# Erst darüber ist „steht noch nicht in Prod" ein Befund statt eines Rennens.
GRACE_MINUTES=60

echo "[deploy_drift] frage $PROD_URL"
# Status UND Body holen — der Status trennt die Fälle, die sonst alle als
# „keine brauchbare Antwort" zusammenfielen. Beim ersten Probelauf meldete
# dieses Skript bei einem 404 „Hub.Version konnte kein git lesen": eine falsche
# Diagnose, die den Suchenden in die Build-Umgebung geschickt hätte, während
# in Wahrheit schlicht ein alter Stand lief.
antwort=$(curl -s -w '\n%{http_code}' --max-time 30 "$PROD_URL" || printf '\n000')
code=$(printf '%s' "$antwort" | tail -n1)
body=$(printf '%s' "$antwort" | sed '$d')

head_ts=$(git log -1 --format=%ct)
now_ts=$(date +%s)
age_min=$(( (now_ts - head_ts) / 60 ))

case "$code" in
  200) ;;
  404)
    # Der Endpunkt kam mit #1224. Fehlt er, ist Prod älter als dieser Commit —
    # das IST der Drift, nur eine Version früher sichtbar als über die SHA.
    if [ "$age_min" -lt "$GRACE_MINUTES" ]; then
      echo "[deploy_drift] /health/version fehlt, master-Commit erst $age_min min alt"
      echo "  -> Deploy vermutlich noch unterwegs. Kein Befund."
      exit 0
    fi
    echo "[deploy_drift] FEHLER: Prod kennt /health/version nicht (HTTP 404)."
    echo "  -> Der Endpunkt kam mit #1224; Prod läuft also auf einem älteren"
    echo "     Stand als master ($age_min Minuten alt). Einen neuen master-Lauf"
    echo "     auslösen; NICHT einen alten Lauf neu starten."
    exit 1
    ;;
  *)
    echo "[deploy_drift] FEHLER: HTTP $code von $PROD_URL."
    echo "  -> App down oder nicht erreichbar. Das prüft freetier_check.sh"
    echo "     genauer: gigalixir ps -a loretracker / gigalixir logs -a loretracker"
    exit 1
    ;;
esac

# Nur Stdlib-Mittel: die SHA aus dem JSON schneiden (kein jq im alpine-Image).
# Leerraum um den Doppelpunkt wird mitgelesen: Phoenix' Jason schreibt zwar
# kompakt (`{"sha":"…"}`), aber ein Muster, das daran hängt, meldet bei jeder
# anderen Formatierung „keine brauchbare SHA" — also einen Build-Fehler, wo in
# Wahrheit ein Drift vorliegt. Beim Test des roten Pfads genau so passiert.
prod_sha=$(printf '%s' "$body" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -z "$prod_sha" ] || [ "$prod_sha" = "unknown" ]; then
  echo "[deploy_drift] FEHLER: HTTP 200, aber keine brauchbare SHA: $body"
  echo "  -> Hub.Version konnte beim Build kein git lesen (sha=\"unknown\")."
  echo "     Build-Umgebung prüfen; der Deploy selbst ist davon unberührt."
  exit 1
fi

head_sha=$(git rev-parse HEAD)
echo "[deploy_drift] Prod: $prod_sha | master: $(printf '%s' "$head_sha" | cut -c1-12)"

# Präfix-Vergleich statt `git rev-parse "$prod_sha"`: Der Woodpecker-Clone ist
# SHALLOW (s. den `--unshallow`-Kommentar im deploy-Step) — ein älterer Commit
# liesse sich hier gar nicht auflösen, und der Check würde an seiner eigenen
# Umgebung scheitern statt eine Aussage zu treffen.
case "$head_sha" in
  "$prod_sha"*)
    echo "[deploy_drift] ok: Prod läuft auf dem master-Stand."
    exit 0
    ;;
esac

if [ "$age_min" -lt "$GRACE_MINUTES" ]; then
  echo "[deploy_drift] Unterschied, aber der master-Commit ist erst $age_min min alt"
  echo "  -> Deploy vermutlich noch unterwegs (Buildpack + Pod-Start). Kein Befund."
  exit 0
fi

echo "[deploy_drift] FEHLER: Prod hängt hinter master zurück."
echo "  master-Commit ist $age_min Minuten alt, Prod läuft auf $prod_sha."
echo "  -> Typisch: ein master-Lauf wurde gekillt, bevor er deploy erreichte"
echo "     (zwei Merges kurz hintereinander killen den ersten Lauf)."
echo "  -> Behebung: einen neuen master-Lauf auslösen. NICHT den alten Lauf"
echo "     neu starten — der deployt seinen eigenen, überholten Commit."
exit 1
