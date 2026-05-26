# STT VAD-Benchmark

Wirkung des Silero-VAD-Pre-Pass (whisper-vad-speech-segments) auf die Stage-1-Transkriptions-Qualität.

> **Stichtag**: 2026-05-26
> **Bench-Tool**: `mix lore.stt_bench --vad <path> | --no-vad` (siehe Issue #232).
> **Real-World-Anker**: CoC-Vorfall 26.05. (siehe unten).
> **Reproduktions-Hardware-Anker**: docs/Performance.md → „Mess-Setup".

## TL;DR

VAD (Silero v5.1.2) als **prod-Default ja**.

Auf einer realen 110-Min-CoC-Session mit 5 Speakern (Crawford, caleb, Pater O'Reilly, Henri, Agnes) brachte das Aktivieren des VAD-Pre-Pass eine **×8.6 Verbesserung der Drop-Rate** (99.43% → 95.10%) und vor allem die Rettung von Speaker-Profilen, die unter dem Whisper-Self-Vergiftungs-Loop (siehe Issue #234) nur 5 statt ~197 Utterances ergaben.

Bei Speakers mit besonders viel Stille (Pater, Agnes) liegt der Verbesserungs-Faktor zwischen ×13 und ×40.

## Real-World-Anker — CoC 26.05.

Aufgenommen wurde eine 110-Min-Pen-und-Paper-Session „Call of Cthulhu" mit deutscher Sprache. Pro Speaker eine eigene Audio-Spur via Discord-Bot. Whisper-Modell: `ggml-large-v3-turbo.bin`. Erst ohne VAD durchgelaufen, dann Re-Run mit `whisper_vad_model = ggml-silero-v5.1.2.bin`.

| Speaker | ohne VAD | mit VAD | Faktor |
|---|---:|---:|---:|
| Crawford | ? | 2 | — ¹ |
| caleb | 1 | 0 | (Mic-Test-Squeaky, jetzt gefiltert via #234) |
| Pater O'Reilly | 5 | 197 | **×39.4** |
| Henri | 67 | 318 | **×4.7** |
| Agnes | 26 | 339 | **×13.0** |
| **Summe** | **100** | **856** | **×8.6** |

¹ Crawford war Spielleiter mit überwiegend kurzen Anweisungen; Baseline-Lauf vor Profilierung verloren gegangen.

Drop-Rate (Whisper-Raw-Segments vs. emittierte Utterances): **99.43 % → 95.10 %**.

## Bench-Reproduktion auf Faust-Fixtures

Für ein deterministisches A/B-Setup auf Librivox-Faust I (CC0):

```bash
# Einmalig: Fixtures herunterladen (~150 MB MP3 → WAV-Slices)
bash apps/worker/test/fixtures/stt/setup.sh

# Bench-Runs
mix lore.stt_bench --all-sessions --no-vad
mix lore.stt_bench --all-sessions --vad ~/.cache/whisper/ggml-silero-v5.1.2.bin
```

Der Bench schreibt eine Markdown-Tabelle (WER + Latenz + RTF) pro Modell × Session. Wenn diese vorliegt, hier einkopieren und Speaker-by-Speaker-Diffs interpretieren.

**Geplante Bench-Daten (TBD)** — sobald die Faust-Fixtures auf einer Mess-Maschine prepariert sind, die WER-Diff `--no-vad` vs `--vad` in eine Tabelle hier einfügen.

## Edge-Cases zu beobachten

Silero ist ein single-channel Multi-Lingual-VAD. In folgenden Szenarien lieber explizit gegen-vermessen bevor man pauschal auf VAD-an wechselt:

- **Sehr leise Sprache** (Flüstern, Murmeln): Silero könnte zu aggressiv filtern und ganze Speech-Phasen droppen.
- **Schnelle Sprecher-Wechsel im selben Channel** (Multi-Speaker-Diarisation): Silero kennt keine Speaker-Boundaries; bei mehreren Stimmen pro Spur kann der Slice-Cut suboptimal sitzen. Im Lore-Tracker-Setup ist das aber unkritisch — **jede Discord-Voice-Spur ist pro Speaker getrennt**.
- **Code-Switching DE↔EN**: Silero ist multilingual aber nicht spezifisch deutsch tuned. Bei Mischsätzen ggf. kürzere Slices als optimal.

Bisher keine real-world-Beobachtung von Regressionen — die ×8.6-Verbesserung war konsistent über alle Speaker mit nicht-trivialer Stille-Anteil.

## Settings

Default in `Worker.Settings`: `whisper_vad_model = nil` (also VAD aus, falls nichts gesetzt). Empfohlene Setzung pro Worker:

```elixir
Worker.Settings.put(:whisper_vad_model, "~/.cache/whisper/ggml-silero-v5.1.2.bin" |> Path.expand())
```

VAD-Modell aus dem [whisper.cpp ggml-Repo](https://huggingface.co/ggerganov/whisper.cpp/tree/main) herunterladen.

UI-Setzung wäre ein eigenes Folge-Issue (heute via Mnesia-State / iex).

## Verwandte Issues

- **#232** (dieses Doc): VAD-Bench + Empfehlung.
- **#234**: Whisper Self-Vergiftung via Rolling-Context-Prompt — VAD wirkt **teilweise** mitigierend (Stille-Phasen weg = kein Boden mehr für Loops), aber der eigentliche Fix steht in Issue #234 (gemerged 26.05.).
- **#212/#214** (closed): STT Quick-Wins + Prompt-System.
- **#94** (closed): STT-Bench-Fixture-Pipeline (Issue #232 baut darauf auf).
