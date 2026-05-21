# Backup & Recovery

Wie du **deine Kampagnendaten sicherst** und im Notfall wieder herstellst — abhängig davon ob du Self-Hosted-Spielleiter mit lokalem Worker bist, oder die Prod-Instance auf Gigalixir betreibst.

## Was musst du sichern?

LoreTracker hält die Wahrheit über jede Kampagne in einem **Append-only Event-Log**. Daraus wird zur Laufzeit der Lese-Zustand materialisiert. Beide Stores brauchen Backups:

| Store | Wo lebt der | Wer schreibt rein | Backup-Befehl |
|---|---|---|---|
| **Hub-EventLog** (Source of Truth) | Hub-BEAM | Worker via Channel + Hub-UI direkt | `mix lore.backup` (dev/Mnesia) oder `POST /admin/backup` (live) oder `gigalixir pg:backups` (prod/Postgres) |
| **Worker-Mnesia** (materialisierter Lese-Zustand + Worker-Settings + Hub-Pairing-Token) | Worker-BEAM | Worker selbst (Pipeline-Output, Setting-Edits) | `mix lore.backup` aus dem Worker-Worktree |

Der Hub-EventLog ist die **einzige autoritative Quelle** für Events. Der Worker-State kann aus dem EventLog rekonstruiert werden (Materializer-Replay) — aber nicht ohne Verlust: Pairing-Token, lokale Settings und einige Caches sind im Worker. Beides sichern.

## Self-Hosted-Worker — `mix lore.backup` + `mix lore.restore`

Diese Mix-Tasks nutzen `:mnesia.backup/1` / `:mnesia.install_fallback/1` — Mnesia's eingebaute Disaster-Recovery-API. Ein einzelnes `.bup`-File enthält das komplette Schema + alle Tabellen-Daten in Mnesia's eigenem Binärformat.

### Backup

```bash
# Worker-Daten sichern (LORE_MNESIA_DIR muss auf den Worker-Mnesia-Ordner zeigen):
LORE_MNESIA_DIR=$(pwd)/priv/mnesia/dev-worker \
  mix lore.backup --out ~/lore-backups/worker-$(date +%Y%m%d).bup
```

**Worker-BEAM muss vorher gestoppt sein** — Mnesia locked den Daten-Ordner pro Node. Wenn der Worker läuft, kommt eine klare Fehlermeldung ("dir locked"). Für Live-Backup ohne Worker-Stop siehe den Hub-Endpoint unten.

Pragmatischer Rhythmus für Self-Hosted: wöchentlich ein Backup auf einen USB-Stick oder Cloud-Sync-Ordner.

### Restore

```bash
# Worker stoppen.
# Optional: bestehenden Mnesia-Ordner wegsichern (cp -r) — Restore überschreibt ihn.

LORE_MNESIA_DIR=$(pwd)/priv/mnesia/dev-worker \
  mix lore.restore --from ~/lore-backups/worker-20260521.bup

# Worker wieder starten.
```

**Achtung:** Restore überschreibt `LORE_MNESIA_DIR` komplett mit dem Inhalt aus dem Backup-File. Pairing-Token, Worker-Settings, Materializer-State werden auf den Backup-Stand zurückgesetzt.

### Hilfe-Texte

`mix help lore.backup` und `mix help lore.restore` zeigen die volle Doku der Tasks inkl. CLI-Flags.

## Hub-Dev (Mnesia) — Live-Backup via HTTP

Auf einer Dev-Hub-Instance (Storage-Backend `:mnesia`, Default in `dev`/`test`) gibt es einen Live-Backup-Endpoint:

```
POST /admin/backup
```

**Nur für globale Rolle `:admin`.** Browser-Download:

1. Login als Admin im Hub-UI.
2. Navigiere zu **/admin/users**.
3. Unten auf der Seite: Sektion **„Daten-Sicherung"** → Button **„Hub-Backup herunterladen"** klickt durch zum POST und löst den Download aus.

Curl-Variante (mit gesetztem Session-Cookie aus dem Browser):

```bash
# Cookie aus dem Browser exportieren (z.B. Cookie-Editor), als cookies.txt
curl -sS -b cookies.txt -X POST http://localhost:4000/admin/backup \
  -o ~/lore-backups/hub-$(date +%Y%m%d).bup
```

Restore: das `.bup`-File via `mix lore.restore --from <file>` einspielen — Hub-BEAM vorher stoppen, dann starten.

Der Endpoint nutzt `:mnesia.backup/1` und liefert einen konsistenten Snapshot **ohne Hub-Restart**.

## Hub-Prod (Postgres) — Gigalixir-Backups

Auf einer Postgres-betriebenen Hub-Instance (Storage-Backend `:postgres`, Default in `prod`) liefert `/admin/backup` 503 mit dem Hinweis, dass Postgres-Dumps nicht durch einen Phoenix-Request gehören. Stattdessen managed Gigalixir die Backups.

### Aktuellen Stand prüfen

```bash
gigalixir pg:backups -a loretracker
```

Zeigt verfügbare automatische Backups mit Timestamp + Größe. Gigalixir hält per Default die letzten 7 Tage täglich + 4 Wochen wöchentlich (Stand 2026, im Zweifel `gigalixir pg:backup:schedule` checken).

### Manuelles Backup auslösen

```bash
gigalixir pg:backups:capture -a loretracker
```

Sinnvoll vor riskanten Migrationen oder größeren Daten-Imports.

### Backup herunterladen (für Disaster-Recovery-Test)

```bash
gigalixir pg:backups:url -a loretracker --backup-id <id>
# Liefert eine signierte URL — herunterladen via curl.
```

### Restore auf den Prod-Hub

```bash
gigalixir pg:backups:restore -a loretracker --backup-id <id>
```

**Achtung:** überschreibt die Prod-Datenbank. Vorher `gigalixir ps -a loretracker` checken (Replicas-Status), idealerweise kurz `gigalixir ps:scale --replicas=0` für die Restore-Dauer.

Voraussetzung CLI: `pip install gigalixir` + `gigalixir login -e $EMAIL -k $API_KEY` (Creds in den Codeberg-CI-Secrets, siehe CLAUDE.md → "Deploy"-Sektion).

## Retention + Cleanup

LoreTracker archiviert keine alten Kampagnen automatisch — das EventLog wächst monoton. Bei aktuellen Datenmengen (paar tausend Events pro Kampagne) ist das unproblematisch; eine 5-Akt-Romeo-Kampagne ist ~150 Events ≈ 50 KB.

**Manueller Cleanup:** Owner / Admin kann eine Kampagne via UI komplett löschen — Dashboard → Kampagnen-Kachel → **„Kampagne löschen"** → Name eintippen + bestätigen (siehe Issue #15-Cascade-Delete). Der `CampaignDeleted`-Event kaskadiert via Materializer in alle abhängigen Tabellen (Sessions, Utterances, Marker, Resümees, Epos, Chronik, Members, Invites).

**Achtung:** Cascade-Delete entfernt nur den materialisierten Lese-Zustand. Der EventLog selbst behält die Event-Historie der gelöschten Kampagne (`CampaignCreated` + alle weiteren Events bis `CampaignDeleted`) — das ist eine bewusste Design-Entscheidung des Append-only-Modells. Wer Storage-Druck hat, sichert + leert den EventLog regelmäßig (Backup vorher!).

Verschlüsselte Backups, automatische Cloud-Backups für Self-Hosted und differential backups sind explizit out-of-scope dieser Iteration (Issue #65). Pull-Requests willkommen.

## Disaster-Recovery-Checkliste

Wenn alles brennt:

1. **Was ist tot?** Nur der Worker-BEAM? Worker-Mnesia korrupt? Hub-EventLog weg?
2. **Sicher den aktuellen Zustand** bevor du irgendetwas restorest — auch ein kaputtes Mnesia kann noch Hinweise enthalten. `cp -r priv/mnesia/dev-worker priv/mnesia/dev-worker.broken-$(date +%s)`.
3. **Hub-EventLog ist die autoritative Quelle.** Solange der lebt, kann der Worker per Materializer-Replay rekonstruiert werden — Pairing-Token + Worker-Settings + ggf. Recording-Audio-Buffer gehen verloren, der Rest kommt zurück.
4. **Reihenfolge beim Restore:** zuerst Hub (EventLog), dann Worker (materialisierter State). Wenn Worker mit alten EventLog-State pairt, weiß er nicht was er gesehen hat → Re-Sync ab letzter bekannter `seq`.
5. **Verifizieren:** nach Restore eine bekannte Kampagne aufrufen, Klick durch die Sessions, prüf dass Resümee/Epos/Chronik gerendert werden.

## Weiterführend

- `mix help lore.backup` / `mix help lore.restore` — vollständige CLI-Doku.
- `CLAUDE.md` → "Hub storage backend" — Adapter-Modell (`:mnesia` vs `:postgres`).
- `CLAUDE.md` → "Rollback + Live-Logs (Gigalixir)" — Release-Rollback (Code-Stand, nicht Daten).
- `CONTRIBUTING.md` → "Debug-Patterns" — iex-Snippets zum Inspizieren von EventLog + Mnesia.
