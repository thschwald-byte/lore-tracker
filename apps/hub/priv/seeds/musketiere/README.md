# Die drei Musketiere — Seed-Daten

D&D-Tisch-Kampagne lose nach Alexandre Dumas, „Les trois mousquetaires" (1844).
Issue #423.

4 Sessions à 25-40k Wörter, **nur Protokoll** (keine Resümees / Epos / Chronik —
das LLM soll die generieren).

## Quelle: gemeinfrei

Dumas (1802-1870) ist seit 1940 global gemeinfrei. Der Roman selbst, seine
Charakter-Namen, Plot-Beats und Original-Dialoge sind Public Domain. Die
deutschen D&D-Tisch-Dialoge in dieser Seed-Sammlung sind eigenständige
Kompositionen, lose orientiert an Plot-Anker-Punkten des PD-Romans — analog
zum bestehenden Romeo-Schlegel-Seed-Pattern (Shakespeare-Original + Schlegel-
Übersetzung von 1797, ebenfalls PD).

Englische Volltexte:
- [Project Gutenberg #1257 (engl.)](https://www.gutenberg.org/ebooks/1257)
- [Project Gutenberg #13951 (franz. Original)](https://www.gutenberg.org/ebooks/13951)

## Cast

| Discord-ID | Spieler-Account | Charakter | D&D-Klasse |
|---|---|---|---|
| 200000000000000001 | Erzähler | (SL) | DM |
| 200000000000000002 | D'Artagnan-Spieler | D'Artagnan | Mensch / Rogue (Swashbuckler) |
| 200000000000000003 | Athos-Spieler | Athos | Mensch / Fighter (Champion) |
| 200000000000000004 | Porthos-Spieler | Porthos | Mensch / Barbarian (Berserker) |
| 200000000000000005 | Aramis-Spieler | Aramis | Mensch / Cleric (War Domain) |

Alle NPCs (Tréville, Königin Anne, Cardinal Richelieu, Milady de Winter,
Rochefort, Constance Bonacieux, Buckingham, Lord de Winter, Henker von Lille
etc.) werden vom SL gespielt.

## Sessions

- **S1 — D'Artagnans Reise + Triple-Duell**: Meung-Encounter mit Rochefort und
  Milady, Brief gestohlen, Ankunft in Paris, Tréville-Audienz, drei Duelle
  arrangiert, Cardinal-Wachen-Kampf, Aufnahme in die Garde.
- **S2 — Anhänger der Königin**: Constance Bonacieux entführt + gerettet, Anne
  bittet um Anhänger-Rettung, Reise nach London (Porthos / Aramis / Athos
  fallen unterwegs aus), D'Artagnan allein zu Buckingham, knapp zum Ball.
- **S3 — Milady-Verschwörung + La-Rochelle**: D'Artagnan + Milady, das Brandmal,
  Athos' Wiedererkennen, Belagerung von La Rochelle, Bastion-Saint-Gervais-
  Frühstück, Cardinal-Auftrag an Milady.
- **S4 — Lys-Finale**: Milady ermordet Buckingham, vergiftet Constance,
  Hetzjagd, Gerichtsverfahren am Hütte beim Lys, Hinrichtung, Lieutenant-
  Patent in Paris.

## Regenerate

```bash
elixir apps/hub/priv/seeds/musketiere/generator.exs
```

Generator ist deterministisch (fester `:rand`-Seed pro Session). Selber
Generator-Code → identische JSONLs.

## Apply

```bash
mix lore.seed.musketiere                              # default --hub http://127.0.0.1:4000
mix lore.seed.musketiere --hub http://127.0.0.1:4005  # PR-Test-Hub
mix lore.seed.musketiere --reset                      # erst CampaignDeleted, dann re-seed
mix lore.seed.musketiere --as-admin <discord-id>      # Caller als Owner+Admin
```
