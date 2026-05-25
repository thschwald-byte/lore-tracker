#!/usr/bin/env bash
# Erzeugt STT-Bench-Fixtures aus Goethe Faust I (Librivox, CC0).
# Einmalig ausführen: bash apps/worker/test/fixtures/stt/setup.sh
# Voraussetzungen: ffmpeg, wget
#
# Quelle: https://archive.org/details/faust1teil_1412_librivox
# Lizenz: CC0 Public Domain (Text: Goethe 1808; Lesung: Librivox-Volunteers)
# 7 Sprecher: Gesine (Erzähler), Herman Roskams (Mephistopheles), redaer (Faust),
#             Sonja (Gretchen), Availle (Marthe), Herr_Klugbeisser (Wagner/Geister),
#             ekyale (Valentin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_DIR="$SCRIPT_DIR/faust/raw"
TURNS_DIR="$SCRIPT_DIR/faust/turns"
BASE_URL="https://archive.org/download/faust1teil_1412_librivox"

mkdir -p "$RAW_DIR" "$TURNS_DIR"

# ─── Prüfungen ───────────────────────────────────────────────────────────────

for cmd in ffmpeg wget; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Fehlt: $cmd"; exit 1; }
done

# ─── Download ────────────────────────────────────────────────────────────────
# Szenen-Datei-Mapping (aus Librivox-Kapitelindex, manuell geprüft):
#   faust1_14: Garten (Faust + Gretchen + Mephistopheles + Marthe) ~23 Min
#   faust1_15: Ein Gartenhäuschen (Faust + Gretchen + Mephistopheles)
#   faust1_09: Studierzimmer II (Faust + Mephistopheles, langer Dialog)
# Timestamps unten sind Näherungswerte — bei Abweichungen im Bench-Output
# setup.sh anpassen und neu ausführen.

download_and_convert() {
  local num="$1"
  local file="faust1_$(printf '%02d' "$num")_goethe"
  local mp3="$RAW_DIR/$file.mp3"
  local wav="$RAW_DIR/$file.wav"

  if [ ! -f "$mp3" ]; then
    echo "  Lade $file.mp3 ..."
    wget -q "$BASE_URL/$file.mp3" -O "$mp3"
  else
    echo "  $file.mp3 bereits vorhanden."
  fi

  if [ ! -f "$wav" ]; then
    echo "  Konvertiere → WAV 16 kHz mono ..."
    ffmpeg -i "$mp3" -ar 16000 -ac 1 -y "$wav" -loglevel error
  fi
}

echo "=== Lade Roh-Audio ==="
for n in 9 14 15; do
  download_and_convert "$n"
done

# ─── Turns schneiden ─────────────────────────────────────────────────────────
# Format: cut_turn <src_wav> <start> <end> <turn_name>
# Timestamps verifiziert via whisper-cli-Probe (2026-05-25).
# Timestamps sind absolut im jeweiligen WAV-File.

cut_turn() {
  local src="$RAW_DIR/$1.wav"
  local start="$2"
  local end="$3"
  local name="$4"
  local out="$TURNS_DIR/$name.wav"
  if [ ! -f "$out" ]; then
    ffmpeg -i "$src" -ss "$start" -to "$end" -ar 16000 -ac 1 -y "$out" -loglevel error
    echo "  Geschnitten: $name.wav"
  fi
}

echo ""
echo "=== Schneide Sprecher-Turns ==="

# Gartenszene — Datei 15 = Szene 15 "Garten"
# 4 Sprecher: Margarete (Gretchen), Faust, Marte, Mephistopheles
# Szene beginnt nach Librivox-Intro bei ~00:30.
# Timestamps verifiziert: probe(ss=30) → relative Timestamps + 30s = absolute.
cut_turn "faust1_15_goethe" "00:32" "00:46" "garten_01_margarete"
cut_turn "faust1_15_goethe" "00:47" "00:56" "garten_02_faust"
cut_turn "faust1_15_goethe" "00:56" "01:08" "garten_03_margarete"
cut_turn "faust1_15_goethe" "01:09" "01:14" "garten_04_marte"
cut_turn "faust1_15_goethe" "01:15" "01:27" "garten_05_mephisto"
cut_turn "faust1_15_goethe" "01:26" "01:40" "garten_06_marte"

# Hexenküche — Datei 09 = Szene 9 "Hexenküche"
# 2 Sprecher: Faust, Mephistopheles
# Szene beginnt nach Librivox-Intro + Bühnenanweisung bei ~00:53.
# TODO: Mephistopheles-Antwort-Timestamps noch verifizieren (probe nötig).
cut_turn "faust1_09_goethe" "00:53" "01:25" "hexe_01_faust"
cut_turn "faust1_09_goethe" "01:25" "02:00" "hexe_02_mephisto"
cut_turn "faust1_09_goethe" "02:00" "02:40" "hexe_03_faust"

echo ""
echo "=== Fertig ==="
echo "WAV-Turns: $(ls "$TURNS_DIR"/*.wav 2>/dev/null | wc -l) Dateien in $TURNS_DIR"
echo "Bench starten: mix lore.stt_bench"
