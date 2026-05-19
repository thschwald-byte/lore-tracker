# LoreTracker — Anleitung für Mitspieler

LoreTracker zeichnet Pen&Paper-Sessions auf und destilliert sie automatisch
zu einem laufenden Kampagnen-Buch („Epos"), einer In-Game-Zeitlinie
(„Chronik") und „Was letztes Mal geschah"-Resümees. Damit musst du dir
zwischen Sessions nichts mehr merken.

---

## Was LoreTracker für dich tut

Während ihr spielt:

- **Protokoll** — was du sagst wird live transkribiert, Zeile für Zeile,
  mit deinem Discord-Namen davor. Wie ein Stenografie-Protokoll der Runde.

Nach Session-Ende (DM klickt Stopp):

- **Resümee** — ein kurzer Rückblick auf die Session, etwa „Letztes Mal
  geschah …"-Stil. 3-6 Sätze, nur die plot-relevanten Dinge.
- **Epos** — das Hauptbuch der Kampagne. Wird komplett neu aus allen
  bisherigen Resümees zusammengewebt, in epischer Fantasy-Prosa.
- **Chronik** — die In-Game-Zeitlinie. Bullet-Liste mit Datum + Ereignis,
  extrahiert aus dem Epos.

Alle vier sind **editierbar** und werden live im Browser aktualisiert —
sobald jemand etwas ändert, sehen das alle anderen sofort, ohne F5.

---

## Erstmal reinkommen

1. **Einladungslink vom DM bekommen.** Sieht so aus:
   `https://loretracker.gigalixirapp.com/invite/<langer-token>`
2. Link anklicken. Falls noch nicht eingeloggt: du wirst zu Discord
   weitergeleitet, dort einmal „Authorize" klicken.
3. Nach dem Login bist du Mitglied der Kampagne. Die Kampagne erscheint
   in deinem **Dashboard** (Übersichts-Grid aller Kampagnen).

Ein Klick auf die Karte öffnet die **Campaign-View** mit den vier Spalten
oben.

---

## Während einer Session

### Der DM startet die Aufnahme

- Im Browser klickt der DM **REC**. Oder im Discord-Server tippt der DM
  `/lore record start campaign:<name>`.
- In der Recording-Bar oben erscheint „● Aufnahme läuft".

### Du gibst dein Mikro frei

- In der Recording-Bar steht jetzt rechts ein Knopf **„🎙 Mit Mikro beitreten"**.
- Klick drauf. Der Browser fragt einmalig nach Mikro-Erlaubnis — „Erlauben".
- Der Knopf wird zu **„Mikro aus"**. Daneben: „🎙 N streamen (alice, bob, …)" —
  die Liste aller, die gerade Audio liefern.
- Du musst **nicht** im Discord-Voice sein. Der Browser-Tab reicht.

### Spielen

Sprich normal. Dein Audio wird in 500ms-Chunks gestreamt; nach Session-Ende
transkribiert ein lokales Whisper-Modell deinen Anteil — getrennt von den
anderen Mitspielern, damit der Sprecher pro Zeile korrekt zugeordnet bleibt.

### Pausen / Wiederaufnehmen

- Pause-Knopf hält die Recording-Bar an, die LLM-Pipeline läuft nicht.
- Resume zurück in den Aufnahme-Modus.
- „Marker"-Knopf setzt einen Plot-Marker an die aktuelle Stelle (taucht
  später in der Chronik auf).

### Session-Ende

- DM klickt **Stopp**. Oder im Discord: `/lore record stop`.
- Sofort danach:
  1. Stage 1 (Transcribe) — Whisper läuft pro Spieler, ein paar Sekunden
     bis Minuten je nach Session-Länge. Pulsender Punkt neben „Protokoll".
  2. Stage 2 (Resümee) — LLM verdichtet das Transkript dieser Session.
  3. Stage 3 (Epos) — LLM webt alle Resümees zu neuem Buch-Text.
  4. Stage 4 (Chronik) — LLM extrahiert Datums-Bullets.

Während eine Stage arbeitet, pulsiert ein kleiner Punkt neben der
Spalten-Überschrift. Du kannst zugucken wie nach und nach Resümee,
dann Epos, dann Chronik-Einträge erscheinen.

---

## Spalten verstehen

Reihenfolge (links → rechts):

### Chronik
In-Game-Zeitlinie. Jeder Eintrag: ein Datum (z.B. „552 CY — Spring"),
ein kurzer Titel, ein Satz Zusammenfassung. Reihenfolge: chronologisch
nach In-Game-Datum. Klick auf ein Datum springt im Epos zum Kapitel.
*(Editier-Funktion: kommt.)*

### The Epos
Das Buch der Kampagne. Markdown, lange Form. Wird bei jeder neuen Session
vom LLM komplett neu geschrieben — daher: **wenn du etwas im Epos manuell
veränderst, übernimmt der LLM beim nächsten Mal deinen Text als Referenz**.
- **Bearbeiten**-Knopf öffnet einen Markdown-Editor. Speichern → der Stand
  wird im Versions-Verlauf abgelegt.
- **Versionen**-Sektion unten zeigt LLM-Versionen vs. menschliche Edits.
  Klick auf zwei Versionen für einen Diff-Vergleich.
- Konflikte (zwei Leute editieren gleichzeitig) → Last-Write-Wins, die
  überschriebene Version lebt in der History weiter.

### Resümee
Liste der „Was letztes Mal geschah"-Texte, ein Eintrag pro Session,
chronologisch absteigend (neueste oben). Jeder Eintrag hat einen
Zeitstempel + Pill „llm" oder „manual".

### Protokoll
Live-Transkript. Während Aufnahme läuft, kommen Zeilen wie sie gesprochen
werden rein. Nach Session-Ende bleiben sie stehen — und Aufnahmen
*früherer* Sessions sind ebenfalls sichtbar, gruppiert pro Session.
- Format pro Zeile: `<Zeit> <Discord-ID> <Text>`
- „pending"-Zeilen (kursiv) sind frische Whisper-Outputs vor manueller
  Bestätigung; werden später vom DM bestätigt oder editiert.

---

## Wenn ihr im selben Discord-Server seid

Der Bot **lore-spy** stellt euch im Discord-Server zwei Slash-Commands
zur Verfügung — Alternative zum Browser-UI:

- `/lore status` — zeigt: ist der Hub erreichbar, läuft der Worker, etc.
- `/lore record start campaign:<Name>` — startet die Aufnahme (DM-Recht).
- `/lore record stop` — beendet die Aufnahme + triggert die Pipeline.

Die Aufnahme-Steuerung im Discord macht **dasselbe** wie REC/Stopp im
Browser — eines schließt das andere nicht aus.

---

## Wenn niemand pairt / "Warte auf Worker"

Der Hub selbst speichert nur das Event-Log. Die Domain-Daten (Kampagnen,
Sessions, Utterances) leben in einem **Worker** beim DM (oder einem anderen
Mitspieler) lokal auf seinem Rechner. Wenn kein Worker connected ist,
zeigt der Browser „Warte auf Worker" — der DM muss seinen Worker starten.
Sobald er da ist, refresht sich die Seite automatisch.

Mehrere Worker können parallel angedockt sein (z.B. DM + ein zweiter
Spieler) — die Daten replizieren sich automatisch. Fällt einer aus,
übernehmen die anderen.

---

## Häufige Fragen

**Muss ich Discord-Voice nutzen?**
Nein. Browser-Mikro reicht. Geht auch wenn ihr in Person spielt oder
über Zoom/Telegram/etc.

**Hört mich der DM live?**
Nein — der Browser streamt das Audio an den Worker, der erst nach
Session-Ende transkribiert. „Live-Mithören" gibt's nicht. Wer in
Discord-Voice ist, hört sich darüber.

**Ich bin in einem anderen Discord-Account/-Channel?**
Egal. Es zählt allein, mit welchem Discord-Account du beim LoreTracker
eingeloggt bist. Dein Audio kommt aus deinem Browser, nicht aus Discord.

**Was wenn ich mitten in der Session dazustoße?**
Im Browser auf die Kampagne gehen → „Mit Mikro beitreten" — alles ab
diesem Moment wird mit aufgenommen. Was vorher passiert ist, fehlt
in deinem Spur.

**Wenn ich am Mikro vergesse zu klicken?**
Dein Anteil fehlt im Transkript. Die Recording-Bar zeigt „🎙 N streamen"
mit Namen — wenn du nicht in der Liste bist, ist dein Mikro aus.
Im Zweifel: Knopf drücken bevor du den ersten Satz sagst.

**Können mehrere Browser-Tabs aufnehmen?**
Nein, nur einer pro Spieler — der zweite Tab wird abgewiesen.

**Datenschutz?**
- Audio bleibt auf dem Worker (DM-Rechner), wird nicht zum Hub gestreamt.
- Nur die Text-Transkripte landen im Event-Log am Hub (Postgres).
- Sprich entsprechend nichts vors Mikro, was nicht in deinem
  Kampagnen-Buch stehen darf.

**Kann ich Text korrigieren?**
Epos-Spalte: ja (Bearbeiten-Knopf). Protokoll-Zeilen einzeln: noch nicht
direkt, kommt mit einem Inline-Editor. Workaround: über die Resümee-/Epos-
Spalten korrigieren — die LLMs nehmen das beim nächsten Lauf als Ground
Truth.

---

## Für DMs: einmaliges Setup

(Nur relevant wenn du selbst eine Kampagne hosten willst — als Spieler
brauchst du das nicht.)

1. LoreTracker lokal klonen + Worker einrichten (siehe Repo-README).
2. Worker mit `HUB_BASE_URL=https://loretracker.gigalixirapp.com` starten,
   pairen → Browser öffnet Setup-Flow.
3. Im Browser: „+ Kampagne gründen" → Name eintragen.
4. „Einladung erstellen" in der Campaign-View → kopierten Link an
   Mitspieler schicken.

Der Discord-Bot `lore-spy` muss zusätzlich auf eurem Discord-Server
installiert sein (Bot-Invite-Link vom DM); pro Server einmalig.
