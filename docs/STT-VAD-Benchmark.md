# STT VAD-Benchmark

Wirkung des Silero-VAD-Pre-Pass (`whisper-vad-speech-segments`) auf die Stage-1-Transkriptions-Qualität.

> **Stichtag**: 2026-05-26
> **Bench-Tool**: `mix lore.stt_bench --vad <path> | --no-vad` (Issue #232).
> **Whisper-Modell**: `ggml-large-v3-turbo.bin`.
> **VAD-Modell**: `ggml-silero-v5.1.2.bin`.
> **Hardware**: siehe `docs/Performance.md` → „Mess-Setup".

## TL;DR — **Conditional**, nicht pauschal

VAD wirkt **kontextabhängig**:

- ✅ **VAD an** für Discord-Voice-Sessions (Pen-und-Paper, lange Stille zwischen Speech-Phasen, leises Hintergrundrauschen): rettet Speaker-Profile vor Whisper-Self-Vergiftungs-Loops.
- ❌ **VAD aus** für studio-quality continuous-speech (Lesungen, kontrollierte Aufnahmen, geringe Stille-Anteile): Slice-Cuts kappen Wort-Boundaries und addieren ×3-×8 Latenz-Overhead — eindeutige Regression.

Der prod-Default in `Worker.Settings` ist `whisper_vad_model = nil` (= aus). **Per-Worker konfigurierbar**, NICHT pauschaler prod-Default. Die ursprüngliche Empfehlung „VAD als prod-Default" (vor diesen Bench-Daten) ist mit der Faust-Bench widerlegt.

## Real-World-Anker — CoC 26.05. (Discord-Voice)

Reale 110-Min-Pen-und-Paper-Session, deutsche Sprache, 5 Speaker, jeder über eine eigene Discord-Voice-Spur. Erst ohne VAD, dann Re-Run mit `whisper_vad_model = ggml-silero-v5.1.2.bin`.

| Speaker | ohne VAD | mit VAD | Faktor |
|---|---:|---:|---:|
| Crawford | ? | 2 | — ¹ |
| caleb | 1 (`*Squeaky*`) | 0 (gefiltert via #234) | — |
| Pater O'Reilly | 5 | 197 | **×39.4** |
| Henri | 67 | 318 | **×4.7** |
| Agnes | 26 | 339 | **×13.0** |
| **Summe** | **100** | **856** | **×8.6** |

¹ Crawford war Spielleiter, kurze Anweisungen — Baseline-Profilierung verloren.

Drop-Rate (Whisper-Raw-Segments vs. emittierte Utterances): **99.43 % → 95.10 %**.

**Warum VAD hier hilft**: lange Stille zwischen Player-Turns + leises Hintergrundrauschen produzierten ohne VAD massive Whisper-Self-Vergiftungs-Loops (`*Squeaky*` aus dem Mic-Test rein-projiziert auf 30-Min-Stille → exit-code 143 nach Kill). Silero filterte die Stille vorher → kein Boden mehr für die Loops.

> **Hinweis Issue #234**: Die `*Squeaky*`-Self-Vergiftung wurde inzwischen aus einer zweiten Richtung gefixt (Prompt-Filter + erweiterte Hallucination-Patterns). Ein Teil des CoC-Verbesserungs-Effekts kommt mit #234 auch ohne VAD zurück — die ×8.6-Marge schrumpft entsprechend, ist aber nicht null (lange Stille-Phasen lassen Whisper auch andere Halluzinationen produzieren als nur das im Prompt geleakte Squeaky).

## Faust-Bench (Librivox-Studio-Quality)

Goethe Faust I, Librivox CC0, 9 Sprecher-Turns gesamt (6× Gartenszene, 3× Hexenkueche). Ground-Truth aus Goethe-Originaltext.

```bash
mix lore.stt_bench --all-sessions --no-context --no-vad   --model ~/.cache/whisper/ggml-large-v3-turbo.bin
mix lore.stt_bench --all-sessions --no-context --vad ~/.cache/whisper/ggml-silero-v5.1.2.bin   --model ~/.cache/whisper/ggml-large-v3-turbo.bin
```

### Pro Turn

| Turn | WER --no-vad | WER --vad | Δ WER | Latenz --no-vad | Latenz --vad |
|---|---:|---:|---:|---:|---:|
| garten_01_margarete | 0.0% | 7.5% | +7.5% | 1171ms | 4056ms |
| garten_02_faust | 0.0% | 0.0% | 0 | 962ms | 2015ms |
| garten_03_margarete | 0.0% | **20.0%** | **+20.0%** | 1024ms | 6817ms |
| garten_04_marte | 0.0% | 11.1% | +11.1% | 942ms | 2037ms |
| garten_05_mephisto | 0.0% | 4.2% | +4.2% | 1038ms | 2114ms |
| garten_06_marte | 2.8% | 5.6% | +2.8% | 1100ms | 3097ms |
| hexe_01_faust | 22.5% | **30.0%** | +7.5% | 1341ms | 9725ms |
| hexe_02_mephisto | 0.0% | 0.0% | 0 | 1419ms | 12444ms |
| hexe_03_faust | 0.0% | 0.0% | 0 | 1521ms | 12685ms |

### Aggregiert pro Session

| Session | Modus | Avg WER | Avg Latenz/Turn | Avg RTF |
|---|---|---:|---:|---:|
| gartenszene | --no-vad | **0.5 %** | 1039 ms | 0.09 |
| gartenszene | --vad | 8.1 % | 3356 ms | 0.31 |
| hexenkueche | --no-vad | **7.5 %** | 1427 ms | 0.04 |
| hexenkueche | --vad | 10.0 % | 11618 ms | 0.33 |

Auf saubere Studio-Aufnahmen ist VAD also **eindeutig schlechter**:
- WER-Regression auf 7/9 Turns, schwerster Einzeleffekt +20 % auf `garten_03_margarete` (kurze Margarete-Antworten mit 7 VAD-Slices → gekappte Wort-Boundaries).
- Latenz ×3-×8 durch zusätzlichen VAD-Pre-Pass + per-Slice-Whisper-Calls.
- RTF von ≤ 0.09 auf 0.31-0.33 — immer noch unter Echtzeit, aber 3-8× mehr CPU-Last pro Audio-Sekunde.

## Interpretation: Warum die zwei Datensätze so unterschiedlich reagieren

| Aspekt | Discord CoC | Librivox Faust |
|---|---|---|
| Aufnahme | unkontrolliert, pro-Speaker-Spur über Bot | Studio, kontinuierliche Lesung |
| Stille-Anteil | hoch (Player warten aufeinander, Mic immer aktiv) | niedrig (Sprecher liest fortlaufend) |
| Hintergrundrauschen | ja (Lüfter, Atem, leise Klick-Geräusche) | minimal |
| Whisper-Loop-Risiko | hoch (Silence → Self-Vergiftung) | gering |
| VAD-Effekt | Stille raus, kein Loop-Boden mehr → **massiver Gewinn** | Wort-Boundaries gekappt + Overhead → **Regression** |

Silero ist single-channel und kennt keine Wort-Boundaries — wenn der Stille-Detector zwischen zwei eng-zusammengesprochenen Wörtern cuttet, verliert Whisper Kontext und produziert Wort-Truncationen / fehlende Endsilben. Bei Pen-und-Paper-Audio mit minimum 200-400ms Pausen zwischen Sätzen ist das harmlos. Bei dramatischer Lesung mit dichten Phrasen-Übergängen schadet es.

## Empfehlung pro Setup-Typ

| Setup | VAD-Empfehlung | Begründung |
|---|---|---|
| Discord-Voice-Pen-und-Paper (Lore-Tracker-Default-Use-Case) | **an** | viel Stille, Loop-Risiko ohne VAD |
| Studio-Lesung / Hörbuch-artiges Material | **aus** | gekappte Wort-Boundaries + Latenz-Overhead |
| Vorlesung / Konferenz-Aufnahme | **case-by-case** — wenn der Sprecher mit klaren Sätzen + Pausen redet OK, sonst lieber aus | abhängig von Sprecher-Rhythmus |
| Mit Issue #234 gefixtem `*...*`-Filter im Prompt | **schwächeres Argument für VAD** auf Discord — aber lange Stille-Loops sind nicht nur Squeaky | empirisch erneut messen, sobald genug Sessions-Daten da sind |

## Worker-Setting

Default: `whisper_vad_model = nil` (= aus). Empfohlene Setzung für einen Discord-prod-Worker:

```elixir
Worker.Settings.put(
  :whisper_vad_model,
  "~/.cache/whisper/ggml-silero-v5.1.2.bin" |> Path.expand()
)
```

VAD-Modell aus dem [whisper.cpp ggml-Repo](https://huggingface.co/ggerganov/whisper.cpp/tree/main).

UI-Setting wäre ein eigenes Folge-Issue (heute via iex / Mnesia-State).

## Verwandte Issues

- **#232** (dieses Doc): VAD-Bench + Empfehlung.
- **#234**: Whisper Self-Vergiftung via Rolling-Context-Prompt — wirkt orthogonal zu VAD. VAD allein eliminiert NICHT alle Loops, der Prompt-Filter aus #234 ist die saubere Lösung gegen die Self-Vergiftung.
- **#212/#214** (closed): STT Quick-Wins + Prompt-System.
- **#94** (closed): STT-Bench-Fixture-Pipeline.

## Reproduktion

```bash
# Einmalig: ~150 MB Librivox MP3-Download + WAV-Slicing
bash apps/worker/test/fixtures/stt/setup.sh

# A/B-Bench
mix lore.stt_bench --all-sessions --no-context --no-vad \
  --model ~/.cache/whisper/ggml-large-v3-turbo.bin

mix lore.stt_bench --all-sessions --no-context \
  --vad ~/.cache/whisper/ggml-silero-v5.1.2.bin \
  --model ~/.cache/whisper/ggml-large-v3-turbo.bin
```
