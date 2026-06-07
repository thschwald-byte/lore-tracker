# Seed-Asset: „Ein Skandal in Böhmen" (Fidelity-Testset, Issue #644)

Ein **Stage-2-Treue-Testset**, kein Klick-Demo. Eine als Call-of-Cthulhu / BRP /
Gaslight (mythos-frei, viktorianisches London 1888) gespielte Tischrunde, die
Arthur Conan Doyles „A Scandal in Bohemia" (1891, gemeinfrei) **abbildet — nicht
dazudichtet**.

## Wozu

Reproduzierbar messen, wie treu ein Pipeline-Resümee (Stage 2) gegenüber einer
**bekannten Referenz** ist. Drei Dinge werden zugleich getestet:

1. **Regel-Noise-Filterung** — die Tischrunde würfelt (BRP-Proben: Entdecken,
   Verkleiden, Überreden, Bibliotheksnutzung, Glück, Ausweichen …) und plaudert
   OOC. Diese Noise ist **diegetisch platziert**: eine Probe steht genau dort, wo
   das Buch eine Handlung hat, die sie auslöst — nicht zufällig gestreut. Ein
   treues Resümee muss sie wegfiltern und nur das erzählte Ereignis behalten.
2. **Figur-aus-Kontext-Attribution** — der **eine** Spielleiter spricht **alle**
   NPCs (König von Böhmen / Wilhelm von Ormstein, Irene Adler, Godfrey Norton,
   Kutscher, Haushälterin). Das Datenmodell trägt **kein Figur-Feld pro
   Utterance** (nur den Sprecher); die Figur lebt im gesprochenen Text
   („Der König, hinter der Maske: …", „Irene, kühl: …"). Genau wie in einer echten
   Aufnahme. Ein gutes Resümee attribuiert „der König sagt X", „Irene sagt Y"
   korrekt aus dem Kontext.
3. **Faktentreue** — weil der Cast = der Cast der Quelle ist (Holmes + Watson als
   PCs, sonst niemand), deckt die Referenz alles ab; jede Abweichung des Resümees
   vom Buch ist ein echter Treuefehler, nicht ein Artefakt eines erfundenen
   dritten Ermittlers. Würfelausgänge sind an den Buch-Plot gekoppelt (gelingt im
   Buch → Probe geschafft).

## Ground Truth

- `reference-summary.md` — kanonisches Gold-Resümee (pro Session + Voll-Fall).
- `fact-key.json` — maschinenlesbar: `required_entities`, `required_facts`
  (pro Session), `attribution_facts` (welcher NPC sagte/tat was), `decoys`
  (Fast-Ereignisse, die NICHT passierten → Fabrikations-Fallen),
  `rule_noise_markers` (Würfel-/OOC-Strings, die im Resümee NICHT auftauchen
  dürfen).

Noch konsumiert kein Code diese Assets — sie dienen jetzt der manuellen Review und
später der Scoring-Task `mix lore.eval.summary` (separates Folge-Issue).

## Aufbau

- `generator.exs` — deterministisch; emittiert die JSONL. Injiziert **keine**
  zufällige Noise — alles steht hand-geschrieben in den Beats.
- `s1_beats.exs` / `s2_beats.exs` — die buchtreuen Beats (Erzählung + Dialog +
  diegetische Proben). Konvention: In-Text-Zitate mit typografischen
  Anführungszeichen (`„…"`, `‚…'`), nie mit geraden `"` (sonst bricht der
  Elixir-String).
- `01_setup.jsonl`, `02_session1.jsonl`, `03_session2.jsonl` — generiert.

PCs (mit `CampaignAliasSet`): Holmes-Spieler → „Sherlock Holmes",
Watson-Spieler → „Dr. Watson". Der SL ist Member mit dem Alias **„Spielleiter"** —
ein reines Rollen-Label, **kein** Charakter (die NPCs leben weiter nur im Text).
Ohne den Member+Alias-Eintrag fiele die member-scoped Sprecher-Auflösung beim
`--as-admin`-Seed auf die rohe discord_id zurück statt „Spielleiter".
Discord-IDs im `30000000000000000`-Range (kollisionsfrei zu Romeo `1e16`,
Musketiere/Ehre `2e16`).

## Umfang

Zwei Sessions, **rein protokollarisch** (keine geseedeten Resümees — Stage 2 muss
sie generieren). Die Wortzahl ergibt sich **ehrlich aus dem Buch** (Doyles Vorlage
hat ~8,5k Wörter Prosa) — bewusst nicht künstlich auf 4-h-Volumen aufgebläht.

```
elixir apps/hub/priv/seeds/skandal-boehmen/generator.exs   # regeneriert die JSONL
```

## Einspielen (auch auf eine Teststage)

Hub + (gepairter) Worker müssen laufen — `/dev/event` braucht einen online Worker.

```
mix lore.seed.skandal                              # gegen http://127.0.0.1:4000
mix lore.seed.skandal --hub http://localhost:4001  # Teststage-Hub
mix lore.seed.skandal --as-admin <discord-id>      # Caller als Owner+Admin
mix lore.seed.skandal --reset                      # erst CampaignDeleted, dann re-seed
```

Refused `MIX_ENV=prod`. Berührt nur die Kampagne `skandal-boehmen-demo`.
