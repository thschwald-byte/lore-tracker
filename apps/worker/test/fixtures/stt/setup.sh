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
#
# Skript-Output (alles unter apps/worker/test/fixtures/stt/faust/, gitignored):
#
#   raw/         — heruntergeladene Librivox-MP3 + 16k mono WAV-Konvertierung
#   turns/       — pro Szene/Sprecher Per-Turn-WAVs (Cut aus raw)
#   multitrack/  — Issue #377: Per-Sprecher-Multitrack-Spuren auf Master-Clock-
#                  Timeline für End-to-End-Pipeline-Eval. Drei Varianten:
#                    clean/      — Stille + sequentielle Turns (kein Bleed)
#                    realistic/  — clean + Inter-Mic-Bleed -25dB + Pink-Noise -50dB
#                    overlap/    — wie clean, aber 2 Turns absichtlich überlappend

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_DIR="$SCRIPT_DIR/faust/raw"
TURNS_DIR="$SCRIPT_DIR/faust/turns"
MULTITRACK_DIR="$SCRIPT_DIR/faust/multitrack"
BASE_URL="https://archive.org/download/faust1teil_1412_librivox"

mkdir -p "$RAW_DIR" "$TURNS_DIR" "$MULTITRACK_DIR"

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

# ─── Multitrack-Build (Issue #377) ──────────────────────────────────────────
# Pro Sprecher eine Spur auf gemeinsamer Master-Clock-Timeline. Drei Varianten:
#
#   clean      — Stille (anullsrc) + sequentielle Turns via adelay/apad, dann
#                amix=normalize=0 (kein 1/N-Pegel-Confound). Pure Baseline.
#   realistic  — clean-Spur des Sprechers + Bleed der anderen Sprecher-Spuren
#                bei -25 dB + Pink-Noise-Raumton bei -50 dB (lowpass 4 kHz).
#   overlap    — wie clean, aber zwei Turns starten früher → echte Simultanrede.
#
# Einheiten-Konvention (siehe Plan #377 Section A):
#   adelay=<ms>          — Millisekunden ohne Suffix
#   apad=whole_dur=<s>   — SEKUNDEN ohne Suffix (NICHT ms!)
#   anullsrc/anoisesrc duration=<s> — Sekunden
#
# Master-Clock-Quelle: apps/worker/test/fixtures/stt/faust/sessions/gartenszene.json
# (Felder duration_ms + turns[].start_ms). Werte unten müssen synchron bleiben
# mit dem JSON — falls einer geändert wird, beide nachziehen.

GARTEN_DURATION_MS=72000
GARTEN_DURATION_S=$((GARTEN_DURATION_MS / 1000))

# Per-Sprecher: "<turn-file-stem>:<start_ms>"-Einträge, in Reihenfolge der Turns
# innerhalb dieses Sprechers (nicht-überlappend).
GARTEN_MARGARETE_TURNS=(
  "garten_01_margarete:0"
  "garten_03_margarete:25000"
)
GARTEN_FAUST_TURNS=(
  "garten_02_faust:15000"
)
GARTEN_MARTE_TURNS=(
  "garten_04_marte:38000"
  "garten_06_marte:57000"
)
GARTEN_MEPHISTO_TURNS=(
  "garten_05_mephisto:44000"
)
GARTEN_SPEAKERS=(margarete faust marte mephisto)

# Overlap-Variante (negative ms = früher → echte Überlappung)
GARTEN_OVERLAP_OFFSETS=(
  "garten_02_faust:-3000"
  "garten_05_mephisto:-2500"
)

# Liefert den overlap-adjusted start_ms für (turn-file, original_start_ms).
overlap_adjust() {
  local file="$1"
  local original="$2"
  local off
  for off in "${GARTEN_OVERLAP_OFFSETS[@]}"; do
    if [ "${off%%:*}" = "$file" ]; then
      echo "$((original + ${off##*:}))"
      return
    fi
  done
  echo "$original"
}

# Iteriert die per-Sprecher-Turn-Arrays — wir dispatchen über den Sprecher-Namen.
turns_for_speaker() {
  case "$1" in
    margarete) printf '%s\n' "${GARTEN_MARGARETE_TURNS[@]}" ;;
    faust)     printf '%s\n' "${GARTEN_FAUST_TURNS[@]}" ;;
    marte)     printf '%s\n' "${GARTEN_MARTE_TURNS[@]}" ;;
    mephisto)  printf '%s\n' "${GARTEN_MEPHISTO_TURNS[@]}" ;;
    *) echo "Unknown speaker: $1" >&2; return 1 ;;
  esac
}

# Pass 1: pro Sprecher eine clean- oder overlap-Spur bauen.
#   $1 = variant (clean|overlap), $2 = speaker, $3 = duration_s
build_speaker_track_pass1() {
  local variant="$1"
  local speaker="$2"
  local dur_s="$3"
  local out_dir="$MULTITRACK_DIR/gartenszene/$variant"
  local out="$out_dir/$speaker.wav"

  mkdir -p "$out_dir"

  local -a inputs=()
  local filter=""
  local mix_labels=""
  local idx=0

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local file="${entry%%:*}"
    local start_ms="${entry##*:}"
    if [ "$variant" = "overlap" ]; then
      start_ms="$(overlap_adjust "$file" "$start_ms")"
    fi
    inputs+=("-i" "$TURNS_DIR/$file.wav")
    filter+="[$idx:a]adelay=${start_ms},apad=whole_dur=${dur_s}[s${idx}];"
    mix_labels+="[s${idx}]"
    idx=$((idx + 1))
  done < <(turns_for_speaker "$speaker")

  if [ $idx -eq 0 ]; then
    echo "  WARN: keine Turns für Sprecher $speaker — überspringe."
    return
  fi

  if [ $idx -eq 1 ]; then
    # Single-Turn-Sprecher: amix=inputs=1 funktioniert, aber redundant.
    filter+="${mix_labels}anull[out]"
  else
    filter+="${mix_labels}amix=inputs=${idx}:normalize=0[out]"
  fi

  ffmpeg "${inputs[@]}" -filter_complex "$filter" -map "[out]" \
    -ar 16000 -ac 1 -t "$dur_s" -y "$out" -loglevel error
  echo "  Gebaut: $variant/$speaker.wav"
}

# Pass 2: realistic-Spur = clean-Spur des Sprechers + Bleed der anderen
# clean-Spuren bei -25 dB + Pink-Noise-Raumton bei -50 dB (lowpass 4 kHz).
# Voraussetzung: ALLE clean-Spuren existieren bereits.
build_speaker_track_pass2() {
  local speaker="$1"
  local dur_s="$2"
  local clean_dir="$MULTITRACK_DIR/gartenszene/clean"
  local out_dir="$MULTITRACK_DIR/gartenszene/realistic"
  local out="$out_dir/$speaker.wav"

  mkdir -p "$out_dir"

  local -a inputs=("-i" "$clean_dir/$speaker.wav")
  local filter="[0:a]anull[me];"
  local mix_labels="[me]"
  local idx=1

  local other
  for other in "${GARTEN_SPEAKERS[@]}"; do
    [ "$other" = "$speaker" ] && continue
    inputs+=("-i" "$clean_dir/$other.wav")
    filter+="[${idx}:a]volume=-25dB[b${idx}];"
    mix_labels+="[b${idx}]"
    idx=$((idx + 1))
  done

  # Pink-Noise als zusätzlicher Input via lavfi.
  inputs+=("-f" "lavfi" "-t" "$dur_s" "-i" "anoisesrc=color=pink:sample_rate=16000")
  filter+="[${idx}:a]lowpass=f=4000,volume=-50dB[noise];"
  mix_labels+="[noise]"
  local total=$((idx + 1))

  filter+="${mix_labels}amix=inputs=${total}:normalize=0[out]"

  ffmpeg "${inputs[@]}" -filter_complex "$filter" -map "[out]" \
    -ar 16000 -ac 1 -t "$dur_s" -y "$out" -loglevel error
  echo "  Gebaut: realistic/$speaker.wav"
}

# Pass 3 (Issue #394): Noisy-Varianten für die Live-vs-Confirmed-Stage. Pro
# Sprecher die clean-Spur + Per-Track-Pink-Noise + Per-Track-Gain-Variation.
# Zwei Stufen:
#   noisy_moderate — Noise -45..-30 dB, Gain ±6 dB (realistische Discord-Mics)
#   noisy_heavy    — Noise -35..-20 dB, Gain ±12 dB + 50-Hz-Brumm auf manchen
#                    Tracks (Stresstest, drückt WER + provoziert Divergenz).
# dB-Werte deterministisch pro (variant, speaker) aus cksum-Hash → reproduzierbar.

# Stabiler 0..99-Wert aus einem String (deterministisch).
hash_pct() { echo $(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 100 )); }

build_noisy_track() {
  local variant="$1"   # noisy_moderate | noisy_heavy
  local speaker="$2"
  local dur_s="$3"
  local clean="$MULTITRACK_DIR/gartenszene/clean/$speaker.wav"
  local out_dir="$MULTITRACK_DIR/gartenszene/$variant"
  local out="$out_dir/$speaker.wav"

  mkdir -p "$out_dir"
  if [ -f "$out" ]; then
    echo "  bereits vorhanden: $variant/$speaker.wav"
    return
  fi
  if [ ! -f "$clean" ]; then
    echo "  WARN: clean/$speaker.wav fehlt — erst clean-Variante bauen. Übersprungen."
    return
  fi

  local h
  h="$(hash_pct "$variant-$speaker")"
  local noise_db gain_db
  if [ "$variant" = "noisy_moderate" ]; then
    noise_db=$(( -45 + h * 15 / 100 ))   # -45..-30
    gain_db=$(( -6 + h * 12 / 100 ))     # -6..+6
  else
    noise_db=$(( -35 + h * 15 / 100 ))   # -35..-20
    gain_db=$(( -12 + h * 24 / 100 ))    # -12..+12
  fi

  local -a inputs=("-i" "$clean")
  local filter="[0:a]volume=${gain_db}dB[me];"
  local labels="[me]"
  inputs+=("-f" "lavfi" "-t" "$dur_s" "-i" "anoisesrc=color=pink:sample_rate=16000")
  filter+="[1:a]volume=${noise_db}dB[noise];"
  labels+="[noise]"
  local n=2

  # Heavy: 50-Hz-Netzbrumm auf Tracks mit geradem Hash.
  if [ "$variant" = "noisy_heavy" ] && [ $((h % 2)) -eq 0 ]; then
    inputs+=("-f" "lavfi" "-t" "$dur_s" "-i" "sine=frequency=50:sample_rate=16000")
    filter+="[2:a]volume=-38dB[hum];"
    labels+="[hum]"
    n=3
  fi

  filter+="${labels}amix=inputs=${n}:normalize=0[out]"

  ffmpeg "${inputs[@]}" -filter_complex "$filter" -map "[out]" \
    -ar 16000 -ac 1 -t "$dur_s" -y "$out" -loglevel error
  echo "  Gebaut: $variant/$speaker.wav (noise=${noise_db}dB gain=${gain_db}dB)"
}

echo ""
echo "=== Multitrack-Build: Gartenszene (clean + overlap) ==="
for variant in clean overlap; do
  for speaker in "${GARTEN_SPEAKERS[@]}"; do
    out="$MULTITRACK_DIR/gartenszene/$variant/$speaker.wav"
    if [ -f "$out" ]; then
      echo "  bereits vorhanden: $variant/$speaker.wav"
    else
      build_speaker_track_pass1 "$variant" "$speaker" "$GARTEN_DURATION_S"
    fi
  done
done

echo ""
echo "=== Multitrack-Build: Gartenszene (realistic) ==="
for speaker in "${GARTEN_SPEAKERS[@]}"; do
  out="$MULTITRACK_DIR/gartenszene/realistic/$speaker.wav"
  if [ -f "$out" ]; then
    echo "  bereits vorhanden: realistic/$speaker.wav"
  else
    build_speaker_track_pass2 "$speaker" "$GARTEN_DURATION_S"
  fi
done

echo ""
echo "=== Multitrack-Build: Gartenszene (noisy_moderate + noisy_heavy) — Issue #394 ==="
for variant in noisy_moderate noisy_heavy; do
  for speaker in "${GARTEN_SPEAKERS[@]}"; do
    build_noisy_track "$variant" "$speaker" "$GARTEN_DURATION_S"
  done
done

echo ""
echo "=== Fertig ==="
echo "WAV-Turns:        $(ls "$TURNS_DIR"/*.wav 2>/dev/null | wc -l) Dateien in $TURNS_DIR"
echo "Multitrack-Spuren: $(find "$MULTITRACK_DIR" -name '*.wav' 2>/dev/null | wc -l) Dateien in $MULTITRACK_DIR"
echo ""
echo "Whisper-direkt-Bench:   mix lore.stt_bench"
echo "Multi-Source-Pipeline:  mix lore.eval.multisource --session gartenszene --variant clean"
