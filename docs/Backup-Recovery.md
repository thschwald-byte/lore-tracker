# Backup & Recovery

Wie du **deine Kampagnendaten sicherst** und im Notfall wieder herstellst.

> **Seit Etappe 5c (hub-v1.0.0, Issue #164) ist der Hub komplett stateless** —
> keine Postgres-DB, keine Mnesia-Tabellen. Backup-Story bezieht sich
> ausschließlich auf die **Worker-Maschinen**; der Hub ist redeployable aus
> Git + Env-Vars.

## Was musst du sichern?

Seit der Worker-zentrischen Event-Architektur (Etappen 3–5) leben alle
Kampagnen-Events **kanonisch in den Workern**:

| Was | Wo | Wer schreibt rein |
|---|---|---|
| **Event-Stream pro Campaign** (`worker_campaign_events_<uuid>`) | Worker-Mnesia | Worker selbst (Pipeline-Output, UI-Edits über EventBridge) |
| **Globale Events** (`worker_events_global`: UserRoleSet, UserUpserted, ProbelaufFinished, …) | Worker-Mnesia | Worker selbst |
| **Materialisierter Lese-Zustand** (Campaigns, Members, Utterances, Resümees, Epos, Chronik) | Worker-Mnesia | Worker.Materializer aus dem Event-Stream |
| **Worker-Settings, Pairing-JWT** | Worker-Mnesia | Worker.Setup beim Pairing |

Backup-Strategie: **pro Worker-Maschine** ein Mnesia-Dump. Wenn du Spielleiter
eines Multi-Worker-Setups bist, syncen die anderen Worker fehlende Events via
`pull_since`/`pull_since_global` über den Hub-Broker zurück — du brauchst nur
**einen** lebenden Worker pro Campaign zum Restoren.

Der Hub hat **keine eigenen Daten**. Wenn die Gigalixir-Instance stirbt:
`git push gigalixir HEAD:refs/heads/master` + `LORE_JWT_SECRET` aus dem
Vault + `SECRET_KEY_BASE` + `DISCORD_CLIENT_ID/SECRET` zurück in die Configs
— fertig.

## Worker-Backup: `mix lore.backup` + `mix lore.restore`

Diese Mix-Tasks nutzen `:mnesia.backup/1` / `:mnesia.install_fallback/1` —
Mnesia's eingebaute Disaster-Recovery-API. Ein einzelnes `.bup`-File enthält
das komplette Schema + alle Tabellen-Daten in Mnesia's eigenem Binärformat.

### Backup

```bash
# Worker-BEAM muss vorher gestoppt sein — Mnesia locked den Daten-Ordner.
LORE_MNESIA_DIR=$(pwd)/priv/mnesia/dev-worker \
  mix lore.backup --out ~/lore-backups/worker-$(date +%Y%m%d).bup
```

Pragmatischer Rhythmus: wöchentlich auf USB-Stick oder Cloud-Sync-Ordner.
Falls du eine Pipeline-Generierung gerade durchlaufen hast, lieber sofort
backuppen — die Stunden-LLM-Compute willst du nicht zweimal bezahlen.

### Restore

```bash
# Worker stoppen.
# Optional: bestehenden Mnesia-Ordner wegsichern (cp -r) — Restore überschreibt ihn.

LORE_MNESIA_DIR=$(pwd)/priv/mnesia/dev-worker \
  mix lore.restore --from ~/lore-backups/worker-20260521.bup

# Worker wieder starten.
```

**Achtung:** Restore überschreibt `LORE_MNESIA_DIR` komplett mit dem Inhalt
aus dem Backup-File. Pairing-JWT, Worker-Settings, Materializer-State werden
auf den Backup-Stand zurückgesetzt.

Nach Restore: Worker connectet zum Hub (JWT noch gültig solange
`LORE_JWT_SECRET` nicht rotiert wurde). `pull_since`/`pull_since_global`
holt fehlende Events seit dem Backup-Stand aus anderen Workern derselben
Campaigns (ab der persistenten Sync-Wasserlinie, siehe unten — der Restore
setzt auch die Wasserlinie auf den Backup-Stand zurück, der Pull-Loop holt
den Rest nach).

### Hilfe-Texte

`mix help lore.backup` und `mix help lore.restore` zeigen die volle Doku
der Tasks inkl. CLI-Flags.

## Disaster-Recovery: Worker-Mnesia komplett verloren

Wenn dein Worker-Mnesia komplett unbrauchbar ist (Festplatten-Crash, versehentliches `rm -rf`):

1. **Erst sichern was noch da ist** — auch ein kaputtes Mnesia kann Hinweise enthalten. `cp -r priv/mnesia/prod-worker priv/mnesia/prod-worker.broken-$(date +%s)`.
2. **Letztes Backup einspielen** falls vorhanden (`mix lore.restore --from …`).
3. **Wenn kein Backup:** Worker re-pairen über Discord-OAuth → frischer JWT, leere Mnesia.
4. **Pull-Sync läuft automatisch** beim Reconnect + danach dauerhaft: dein Worker holt den globalen Event-Strom und jede Member-Campaign vollständig aus einem anderen online Worker nach (Details unten).
5. **Worst case** — du bist der einzige Worker einer Campaign und hast die Mnesia verloren: die Campaign-Daten sind weg. Backup-Disziplin ist deine einzige Versicherung.

### Sync-Mechanik (Issues #690 + #693)

Der Pull-Sync läuft über eine **persistente Sync-Wasserlinie pro Scope**
(`Worker.SyncWatermark`, ein Scope = der globale Strom oder eine campaign_id):

- Die Wasserlinie ist die höchste event_id, bis zu der dieser Worker
  **nachweislich per Pull von einem Peer** synchronisiert hat. Nur
  Pull-Batches schieben sie vor — Live-Events nie. Ein frischer Worker
  startet bei `nil` und pullt die volle Historie; Live-Events, die während
  des Backfills eintreffen, können den Cursor nicht mehr „vergiften" (#693).
- Der Quell-Worker antwortet pro Pull-Request mit **einem** Byte-Budget-Chunk
  (Setting `pull_chunk_max_bytes`, Default 200 KB — #690); der Empfänger
  schiebt die Wasserlinie vor und pullt den Rest im Loop, bis eine leere
  Antwort kommt. Große Historien passieren so den Cloud-Proxy als gepacte
  Request/Response-Kette statt als Riesen-Frame.
- Ein **periodischer Sync-Tick** (Setting `sync_tick_ms`, Default 60 s) pullt
  alle Scopes ab Wasserlinie: deckt „Quelle war beim Join offline",
  verlorene Pull-Responses und verlorene Live-Events (Regeneration binnen
  eines Ticks). Duplikate sind harmlos (event_id-Idempotenz).
- Entdeckt der globale Backfill eine neue Member-Campaign (CampaignCreated/
  InviteRedeemed/AdminMemberAdded), wird ihr per-Campaign-Store angelegt,
  subscribed und die Campaign-Historie sofort ab Wasserlinie nachgezogen.

Ziel-Invariante: **jeder Worker hält alle Kampagnen, in denen seine User
Member sind, vollständig und dauerhaft synchron** — solange mindestens ein
anderer Worker mit den Daten online ist.

## Retention + Cleanup

LoreTracker archiviert keine alten Kampagnen automatisch — der per-Campaign
Event-Store wächst monoton. Bei aktuellen Datenmengen (paar tausend Events
pro Kampagne) ist das unproblematisch; eine 5-Akt-Romeo-Kampagne ist ~150
Events ≈ 50 KB pro Worker.

**Manueller Cleanup:** Spielleiter / Admin kann eine Kampagne via UI komplett
löschen — Dashboard → Kampagnen-Kachel → **„Kampagne löschen"** → Name
eintippen + bestätigen (siehe Issue #15-Cascade-Delete). Der
`CampaignDeleted`-Event kaskadiert via Materializer in alle abhängigen
Tabellen (Sessions, Utterances, Marker, Resümees, Epos, Chronik, Members,
Invites) und droppt die per-Campaign-Event-Tabelle.

**EventLog-Pruning (Issue #97 Cut 1):** Bei Storage-Druck lassen sich alte
Events aus dem worker-lokalen Log entfernen, ohne eine Kampagne ganz zu löschen:

```bash
# Gestoppter Worker / Dev (gegen das gewählte Mnesia-Dir):
LORE_MNESIA_DIR=/pfad/zur/worker-mnesia mix lore.eventlog.prune --before-date 2026-01-01 --dry-run
LORE_MNESIA_DIR=…  mix lore.eventlog.prune --before-date 2026-01-01            # echtes Löschen
```

Für einen **laufenden** `worker_prod`-Daemon (Mnesia ist pfad-exklusiv) per RPC:

```elixir
{:ok, cutoff, _} = DateTime.from_iso8601("2026-01-01T00:00:00Z")
:rpc.call(:"worker_prod@<host>", Worker.EventLog, :prune_before, [cutoff, [dry_run: true]])
```

Das prunt nur den **EventLog** (Gossip-/Recovery-Historie) — die materialisierte
Lese-State (Kampagnen/Sessions/Utterances) bleibt unangetastet (disc_copies,
wird beim Boot nicht aus dem Log rekonstruiert). **Destruktiv** für die
Disaster-Recovery der geprunten Events: vorher `mix lore.backup`. **Single-Worker:**
bei Multi-Worker-Gossip (#131) würden andere Worker die geprunten Events wieder
einspielen — die signierte-Prune-Event-Variante für Multi-Worker ist Folge-Issue.

Verschlüsselte Backups + automatische Cloud-Backups sind out-of-scope
dieser Iteration (Issue #96). Pull-Requests willkommen.

## Hub-Restore

Hub ist **stateless seit hub-v1.0.0**. Restore = re-deploy. Es gibt nichts
zu backuppen. Nur die Env-Vars müssen erhalten bleiben:

- `LORE_JWT_SECRET` — bei Verlust müssen alle Worker einmalig re-pairen
- `SECRET_KEY_BASE` — bei Wechsel werden alle Browser-Sessions invalidiert (User loggen sich neu ein)
- `DISCORD_CLIENT_ID` + `DISCORD_CLIENT_SECRET` — aus der Discord-Developer-Portal-Console

Obsolete Env-Vars nach Etappe 5c — können bedenkenlos gelöscht werden
(Hub-Code referenziert sie nicht mehr):

```bash
for k in DATABASE_URL POOL_SIZE LORE_STORAGE_BACKEND LORE_CLOAK_KEY; do
  gigalixir config:unset $k -a loretracker
done
```

`gigalixir config:unset` nimmt nur einen Key pro Aufruf entgegen und
triggert pro Call einen Restart.

## Weiterführend

- `mix help lore.backup` / `mix help lore.restore` — vollständige CLI-Doku.
- `CLAUDE.md` → "Hub: zero persistent state" — Architektur-Stand seit Etappe 5c.
- `CLAUDE.md` → "Rollback + Live-Logs (Gigalixir)" — Hub-Release-Rollback (Code-Stand).
