#!/bin/sh
# Issue #876: wöchentlicher Free-Tier-Frische-Check (Woodpecker-Cron, OHNE Secrets).
#
# Gigalixir-Free-Tier-Regel: 30 Tage ohne Deploy -> App wird auf 0 Replicas
# skaliert (Warnmail nach 23 Tagen). Wir deployen nur bei master-Push — eine
# Merge-Pause > 30 Tage nimmt Prod unbemerkt offline. Dieser Check läuft als
# Cron-Workflow und rotet die Pipeline, BEVOR das passiert:
#
# 1. HTTP-Check auf Prod (fängt den 0-Replicas-Downscale und jeden anderen
#    Totalausfall — eine downgescalte App liefert kein 302 mehr).
# 2. Alter des letzten master-Commits > 21 Tage -> rot mit Handlungsanweisung.
#    Commit-Datum ist ein ehrlicher Proxy fürs Deploy-Datum (jeder master-Push
#    deployt automatisch, Issue #31); der Detail-Check (Pods/OOM/size) läuft
#    im deploy_verify-Step, der die push-scoped Secrets hat — dieser Cron
#    braucht bewusst KEINE (Secrets sind push-scoped, cron sähe sie nicht).
#
# URL bewusst hardcoded statt Secret: öffentlich bekannt (CLAUDE.md), und der
# Cron-Kontext hat keinen Secret-Zugriff.
set -eu

PROD_URL="https://loretracker.gigalixirapp.com/"
MAX_AGE_DAYS=21

echo "[freetier_check] HTTP-Check auf $PROD_URL"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$PROD_URL" || echo "000")
case "$code" in
  200|301|302|303)
    echo "[freetier_check] ok: HTTP $code"
    ;;
  *)
    echo "[freetier_check] FEHLER: HTTP $code (erwartet 200/301/302/303)."
    echo "  -> App down? 0-Replicas-Downscale (30-Tage-Regel)? Pruefen:"
    echo "     gigalixir ps -a loretracker  /  gigalixir logs -a loretracker"
    exit 1
    ;;
esac

last_commit_ts=$(git log -1 --format=%ct)
now_ts=$(date +%s)
age_days=$(( (now_ts - last_commit_ts) / 86400 ))
echo "[freetier_check] Letzter master-Commit vor $age_days Tagen"

if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
  echo "[freetier_check] FEHLER: $age_days Tage ohne master-Push (> $MAX_AGE_DAYS)."
  echo "  -> Gigalixir skaliert Free-Tier-Apps nach 30 Tagen ohne Deploy auf 0"
  echo "     Replicas. Vor Tag 30 irgendeinen Commit nach master mergen (jeder"
  echo "     master-Push deployt automatisch) oder manuell deployen."
  exit 1
fi

echo "[freetier_check] Free-Tier-Frische ok."
