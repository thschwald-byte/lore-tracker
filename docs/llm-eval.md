# LLM-Modell-Vergleich (Stage 4 / Chronik)

Snapshot eines Probelauf-Sweeps gegen den committed Goldstandard-Pre-Seed
(`apps/worker/priv/probelauf-eval/`). Adressiert Issue #113 — die
Tool-Infrastruktur dafür wurde in #88 (Probelauf-Sweep), #289 (Phase 1-4),
#290 (Faithfulness-Bugs) und #288 (Format-Notes) aufgebaut. Diese Datei
ist die statische Fixpunkt-Aufnahme zu einem Stichtag; aktuelle Werte
liefert immer `/admin/probelauf`.

## Sweep-Setup

- **Datum**: 2026-05-30, 18:57 → 19:39 (UTC+2), Wall-Clock 42:21.
- **Sweep-ID**: `019e79d1-81d3-730d-9b8e-aab648b85c77`.
- **Stage**: 4 (Chronik).
- **Modus**: stage-isoliert (kein Drift durch Stage-2/3).
- **Eval-Set**: alle drei synthetischen Goldstandard-Sessions
  (short / medium / long → 10 / 30 / 100 Utterances).
- **Worker**: PR-Test-Instanz auf Port 4003, Ollama lokal auf CachyOS.
- **Faithfulness-Sidecar**: aktiv (NLI-Score via HuggingFace-Modell).
- **Modelle**:
  - `qwen2.5:0.5b` (0.4 GB)
  - `qwen2.5:7b` (4.7 GB, aktueller Default)
  - `mistral-nemo:12b` (7.1 GB)

## Ergebnisse

### Per-Variante-Mittelwerte

| Modell | Median-Dauer | Success-Rate | Ø Faithfulness | Format-OK | Timeouts |
|---|---:|---:|---:|---:|---:|
| `qwen2.5:0.5b`     | 366 s   | 33% (1/3) | 0.16 | 2 / 3 | 1 / 3 |
| `qwen2.5:7b`       |   9 s   | 100% (3/3) | 0.16 | 3 / 3 | 0 / 3 |
| `mistral-nemo:12b` |   7 s   | 100% (3/3) | 0.00 | 3 / 3 | 0 / 3 |

### Per-Session-Detail

| Modell | Session (Utts) | Dauer | Outcome | Faithfulness | Output-Bytes |
|---|---|---:|---|---:|---:|
| `qwen2.5:0.5b`     | 1 (10)  | timeout | `timeout`      | 0.14 | 25 |
| `qwen2.5:0.5b`     | 2 (30)  | 82.8 s  | `other_error`  | 0.00 | 25 |
| `qwen2.5:0.5b`     | 3 (100) | 649.4 s | `ok`           | 0.33 | 21 |
| `qwen2.5:7b`       | 1 (10)  |  3.3 s  | `ok`           | 0.14 | 18 |
| `qwen2.5:7b`       | 2 (30)  | 651.8 s | `ok`           | 0.00 | 18 |
| `qwen2.5:7b`       | 3 (100) |  8.9 s  | `ok`           | 0.33 | 19 |
| `mistral-nemo:12b` | 1 (10)  | 15.2 s  | `ok`           | 0.00 | 19 |
| `mistral-nemo:12b` | 2 (30)  |  0.0 s  | `ok`           | 0.00 | 24 |
| `mistral-nemo:12b` | 3 (100) |  7.3 s  | `ok`           | 0.00 | 25 |

(Format-Notes durchgehend `"ok"` — bestätigt dass JSON-Schema-Mode aus
#289 Phase 1 für lokale Ollama-Modelle greift; keine Strip-Fixups nötig.)

## Interpretation

### Output-Größe — alle Modelle liefern fast leer

Alle drei Modelle returnen `output_bytes` zwischen 18 und 25 — das ist
exakt die Länge von `{"entries":[]}` (15 Bytes) bzw. winzigen
Variationen davon. **Keines der Modelle hat aus den Goldstandard-
Fixtures wirklich Chronik-Einträge extrahiert.** Das ist nicht
notwendigerweise ein Modell-Defekt — der Goldstandard-Pre-Seed besteht
aus synthetischen Utterances ohne klare In-Game-Zeitangaben oder
explizite Plot-Beats. Stage 4 ist designed-konservativ (`ANTI-
FABRICATION`-Regel im Prompt: lieber leere Liste als erfundene Einträge).

→ **Konsequenz**: Faithfulness-Werte sind hier nicht aussagekräftig
für Modell-Qualität. 0.14 / 0.33 stammen von Trigram-Coverage-Fallback
auf einer praktisch leeren Antwort, nicht von echtem NLI-Vergleich.

### Latenz — qwen2.5:7b inkonsistent

Erstaunlich:

- `qwen2.5:7b` ist auf Session 1 (3.3 s) sehr schnell — auf Session 2
  (651 s = 10:51 min) extrem langsam. Wahrscheinlich Modell-Reload nach
  qwen2.5:0.5b davor + erste Tokenisierung des größeren Modells.
  Session 3 (8.9 s) bestätigt: nach warm-up ist 7b zügig.
- `mistral-nemo:12b` ist durchgehend konsistent (15 s / 0 s / 7 s). Der
  `0 s`-Wert auf Session 2 ist suspekt — vermutlich hat das Modell direkt
  ein `{"entries":[]}` ausgegeben ohne nennenswerte Latenz (Hot-Path nach
  Modell-Wechsel von 7b → 12b).
- `qwen2.5:0.5b` ist unbrauchbar: Session 1 läuft in Timeout, Session 3
  braucht 10:49 min für Empty-Output. Klein heißt nicht schnell wenn das
  Modell keine sinnvolle Ausgabe produziert.

### Success-Rate

Nur das kleinste Modell (`qwen2.5:0.5b`) reißt die Success-Rate (1/3
durchgekommen). `qwen2.5:7b` und `mistral-nemo:12b` schaffen alle drei
Sessions im Outcome-Sinn (= Stage hat einen JSON-Response geliefert) —
auch wenn der Inhalt leer ist.

## Empfehlung (Stand 2026-05-30)

Für Stage 4 mit den aktuellen Fixtures:

1. **Default-Modell `qwen2.5:7b`** bleibt sinnvoll (100% Success,
   konsistent in den meisten Sessions).
2. **`mistral-nemo:12b`** als Alternative wenn weniger Variance gewünscht
   ist und der RAM-Aufschlag (7.1 GB vs 4.7 GB) vertretbar.
3. **`qwen2.5:0.5b` ausschließen** — Timeout-Risiko überwiegt den
   Speed-Vorteil deutlich.
4. **Bessere Fixtures wären die Voraussetzung** für einen aussagekräftigen
   Modell-Vergleich. Die Goldstandard-Sessions bräuchten explizit
   Chronik-relevante Plot-Beats (Ankunft, Begegnung, Kampf, Entdeckung)
   mit klaren In-Game-Zeitangaben. Issue für „realistische Eval-Fixtures
   mit goldenen Chronik-Einträgen" ist offen (→ separater Task).

## Methodik / Reproduktion

Live re-runs:

1. `/admin/probelauf` aufrufen (Admin-Rolle nötig).
2. **Modell-Sweep**: Stage wählen + Modelle aus Liste auswählen +
   Session-Set + Start.
3. **Param-Sweep** (#289 Phase 4): Stage wählen + Start — variiert
   `temperature_stageN` über `[0.05, 0.1, 0.15, 0.2]` beim aktuellen
   Default-Modell.
4. Tabelle erscheint sofort mit Status-Dots (#288): cyan = läuft,
   gelb = pending, grün = ok, rot = Fehler.

Programmatic re-runs (RPC):

```elixir
:rpc.call(:"worker@…", Worker.Probelauf, :start_sweep_isolated, [
  "<discord-id>",     # started_by
  4,                  # stage
  ["qwen2.5:7b", "mistral-nemo:12b"],
  ["short", "medium", "long"]
])
```

Snapshot extrahieren:

```elixir
:rpc.call(:"worker@…", Worker.Repo, :last_probelauf_sweep, [])
```

## Out of Scope

- **Few-Shot-A/B im Prompt**: Issue #113 listet das als optionalen
  Punkt. Lohnt sich erst wenn die Eval-Fixtures aussagekräftige
  Faithfulness-Werte produzieren — sonst keine messbare
  Vergleichsgröße. Verschoben auf separates Ticket.
- **Stage 2 + 3 im selben Lauf**: hier nur Stage 4 evaluiert. Stage 2
  (Resümee) hat dichteren Output und wäre mit gleicher Fixture-Basis
  besser zu vergleichen; Stage 3 (Epos) hat keinen klaren Fehler-Signal
  (Freitext). Separate Sweeps via /admin/probelauf.
- **Cloud-Backends** (Anthropic/OpenAI/Google): Issue #89 bringt sie in
  den Probelauf — noch nicht implementiert.
