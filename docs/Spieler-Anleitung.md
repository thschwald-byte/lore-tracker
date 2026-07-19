# LoreTracker — Anleitung für Mitspieler

LoreTracker zeichnet Pen&Paper-Sessions auf und destilliert sie automatisch
zu einem laufenden Kampagnen-Buch („Epos"), einer In-Game-Zeitlinie
(„Chronik") und „Was letztes Mal geschah"-Resümees. Damit musst du dir
zwischen Sessions nichts mehr merken.

---

## Was LoreTracker für dich tut

Während ihr spielt:

- **Protokoll** — was du sagst wird transkribiert, Zeile für Zeile, mit
  deinem Discord-Namen (oder Charakter-Namen, wenn gesetzt) davor. Wie ein
  Stenografie-Protokoll der Runde.

Nach Session-Ende (Spielleiter klickt Stopp):

- **Resümee** — ein kurzer Rückblick auf die Session, etwa „Letztes Mal
  geschah …"-Stil. 3-6 Sätze, nur die plot-relevanten Dinge.
- **Epos** — das Hauptbuch der Kampagne. Jede Session bekommt ihr eigenes,
  neues Kapitel, das ans bestehende Buch angehängt wird — ältere Kapitel
  werden dabei nicht neu geschrieben.
- **Chronik** — die In-Game-Zeitlinie. Bullet-Liste mit Datum + Ereignis,
  automatisch aus den geprüften Fakten der Session sortiert.

Alle vier sind **editierbar** und werden live im Browser aktualisiert —
sobald jemand etwas ändert, sehen das alle anderen sofort, ohne F5.

---

## Knöpfe sind Hex-Icons

Alle Knöpfe in der Oberfläche sind kleine Hex-Symbole mit Neon-Glow.
Was sie bedeuten, steht im **Tooltip** — Maus drüber halten, dann
erscheint die Beschriftung. Farbe + Form sind konsistent:

- 🟢 grün (✓) = Speichern / Bestätigen
- 🔴 rot (🗑 / ⏻ / ⏺) = Löschen / Aufnahme / Power
- 🟣 violett (✎) = Bearbeiten
- ⚪ grau (✕ / ↶) = Abbrechen / Zurücksetzen
- 🔵 cyan (+ / 🔗 / 🔄) = Neue Aktion / Link / Neu generieren

Wenn du Touchgeräte benutzt: einmal antippen zeigt den Tooltip,
nochmal antippen löst die Aktion aus.

---

## Erstmal reinkommen

1. **Einladungslink vom Spielleiter bekommen.** Sieht so aus:
   `https://loretracker.gigalixirapp.com/invite/<langer-token>`
2. Link anklicken. Falls noch nicht eingeloggt: du wirst zu Discord
   weitergeleitet, dort einmal „Authorize" klicken.
3. Nach dem Login bist du Mitglied der Kampagne. Die Kampagne erscheint
   in deinem **Dashboard** (Übersichts-Grid aller Kampagnen).

Ein Klick auf die Karte öffnet die **Campaign-View** mit den fünf Spalten
(Chronik, Resümee, Epos, Geglättet, Protokoll). „Geglättet" zeigt das
aufbereitete Transkript (Sprecher-Blöcke, Füllwörter entfernt) mit
Markierungen: 🕳 = erkannte Erkennungs-Lücke — direkt am Block bestätigen, korrigieren
oder als unbrauchbar markieren (✓ = bestätigt, 🚫 = unbrauchbar); „↪
Protokoll" springt zur Original-Stelle.

---

## Deinen Charakter-Namen setzen (Alias)

Über deinem Discord-Namen kannst du dir pro Kampagne einen Charakter-
Namen setzen, der dann überall statt deines Discord-Tags angezeigt wird —
z.B. „Aragorn" statt „carnivor#1234".

Im Campaign-Header rechts: dein Discord-Avatar + Pencil-Icon → Alias
tippen → Speichern. Reset löscht den Alias und zeigt wieder den Discord-
Namen.

Der Spielleiter kann sich z.B. den Alias „Spielleiter" setzen — dann
heißt es im Protokoll und in den generierten Texten konsistent
„Spielleiter: …" statt seines Discord-Tags.

---

## Während einer Session

### Der Spielleiter startet die Aufnahme

- Im Browser klickt der Spielleiter **REC**.
- In der Recording-Bar oben erscheint „● Aufnahme läuft".
- Du hörst zwei kurze Töne als Signal — Recording-Start (Issue #9).

### Du gibst dein Mikro frei

- In der Recording-Bar steht jetzt rechts ein Knopf **„🎙 Mit Mikro beitreten"**.
- Klick drauf. Der Browser fragt einmalig nach Mikro-Erlaubnis — „Erlauben".
- Der Knopf wird zu **„Mikro aus"**. Daneben: „🎙 N streamen (alice, bob, …)" —
  die Liste aller, die gerade Audio liefern.
- Du brauchst **kein** Discord-Voice. Der Browser-Tab reicht.

### Spielen

Sprich normal. Dein Audio wird in 500ms-Chunks gestreamt; nach Session-
Ende transkribiert ein lokales Whisper-Modell deinen Anteil — getrennt
von den anderen Mitspielern, damit der Sprecher pro Zeile korrekt
zugeordnet bleibt.

### Pausen / Wiederaufnehmen

- Pause-Knopf hält die Recording-Bar an, die LLM-Pipeline läuft nicht.
- Resume zurück in den Aufnahme-Modus.
- **Marker**-Knopf setzt einen Plot-Marker an die aktuelle Stelle.

### Session-Ende

- Spielleiter klickt **Stopp**.
- Zwei kurze Töne als Signal — Recording-Stop (Issue #9).
- Sofort danach läuft die Pipeline:
  1. **Transkription** — Whisper läuft pro Spieler, ein paar
     Sekunden bis Minuten je nach Session-Länge.
  2. **Extraktion** — ein LLM zieht strukturierte Fakten aus dem
     Transkript dieser Session.
  3. **Prüfung** — die Fakten werden gegen den Transkript-Text
     gegengecheckt (Quell-Belege, korrekte Zuordnung zu Personen).
  4. **Erzeugung** — aus den geprüften Fakten entstehen unabhängig
     voneinander: das Resümee, ein neues Epos-Kapitel und die
     Chronik-Einträge dieser Session.

Während die Pipeline arbeitet, pulsiert ein kleiner Punkt neben der
Spalten-Überschrift. Du kannst zugucken wie nach und nach Resümee,
Epos-Kapitel und Chronik-Einträge erscheinen.

---

## Spalten verstehen

Vier Spalten nebeneinander (von links nach rechts): **Chronik**, **Epos**,
**Resümee**, **Protokoll**.

### Spalten ein-/ausklappen

Jede Spalten-Überschrift hat einen Chevron (▾/▸) zum Einklappen — schafft
Platz wenn du dich auf eine andere konzentrieren willst. Mindestens eine
Spalte bleibt offen. Deine Auswahl wird pro Kampagne im Browser
gespeichert.

### Chronik
In-Game-Zeitlinie. Jeder Eintrag: ein Datum (z.B. „552 CY — Spring"),
ein kurzer Titel, ein Satz Zusammenfassung. Reihenfolge: chronologisch
nach In-Game-Datum. **Editierbar**: Datum/Titel/Summary über das ✎-Icon
ändern oder Eintrag über ✕ löschen.

### Epos
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
sortiert nach **Session-Nummer aufsteigend** — Session 1 oben, neueste
Session unten. Jeder Eintrag-Header zeigt Zeitstempel, Quelle (`llm` oder
`manual`), das Session-Label, sowie zwei Knöpfe:

- **✎ bearbeiten** — Resümee-Text direkt überschreiben.
- **🔄 neu generieren** (Spielleiter-only) — lässt die Pipeline für
  diese Session erneut laufen, falls Modell oder Stil geändert wurde.

### Protokoll
Live-Transkript. Während Aufnahme läuft, kommen Zeilen wie sie
gesprochen werden rein. Nach Session-Ende bleiben sie stehen — und
Aufnahmen *früherer* Sessions sind ebenfalls sichtbar, gruppiert pro
Session. Format pro Zeile: `<Zeit> <Spieler> <Text>`.

- **Hover** über eine Zeile → ✎ (bearbeiten) und ✕ (löschen) erscheinen.
  Hilft falls Whisper sich verhört hat oder ein Spieler etwas korrigieren
  will.
- **+ Eintrag** pro Session-Gruppe — manuell eine Zeile hinzufügen (z.B.
  für Sätze die nicht aufgenommen wurden).

---

## Flavor — Stil der LLM-Texte anpassen

Im Header der Kampagne gibt's einen „🎭 Stil"-Akkordeon mit drei Reitern
— **Resümee**, **Epos**, **Chronik**. Resümee und Epos haben je zwei
Textfelder:

- **Ton (allgemein)** — Setting der Kampagne, z.B. „Im grünen Auenland
  voller glücklicher Hobbits" oder „In den Schützengräben von Verdun".
  Gilt für beide Textsorten.
- **Ton speziell für diese Spalte** — beim Resümee z.B. „neutraler
  Erzähler" oder „Reporter eines Boulevardblatts", beim Epos z.B.
  „Tolkien-Stil epischer Erzähler" oder „grimmiger Skalde mit vielen
  Kennings".

Der **Chronik**-Reiter hat keinen Ton-Editor — die Zeitlinie wird
deterministisch aus den geprüften Fakten gebaut, ganz ohne LLM-Prompt.
Dort lässt sich nur die Spalten-Überschrift ändern.

Ohne Flavor sind die Prompts neutral-sachlich. Sobald du Werte tippst,
gelten sie ab dem nächsten Pipeline-Lauf (oder direkt via 🔄 neu
generieren).

Member-only; nicht-Mitglieder sehen das Akkordeon nur als Anzeige.

---

## Kampagne löschen (Spielleiter)

Ganz unten im Campaign-Header (nur als Spielleiter sichtbar): **⚠
Kampagne löschen**. Klick öffnet eine Bestätigungs-Form: du musst den
exakten Kampagnen-Namen eintippen, sonst bleibt der „Endgültig löschen"-
Button disabled. Beim Submit werden Kampagne + alle zugehörigen
Sessions, Protokolle, Resümees, Epos und Chronik-Einträge **unwiderruflich**
gelöscht.

---

## „Warte auf Worker"

Der Hub selbst speichert nur das Event-Log. Die Domain-Daten (Kampagnen,
Sessions, Utterances) leben in einem **Worker** beim Spielleiter (oder
einem anderen Mitspieler) lokal auf seinem Rechner. Wenn kein Worker
connected ist, zeigt der Browser „Warte auf Worker" — der Spielleiter
muss seinen Worker starten. Sobald er da ist, refresht sich die Seite
automatisch.

Mehrere Worker können parallel angedockt sein (z.B. Spielleiter + ein
zweiter Spieler) — die Daten replizieren sich automatisch. Fällt einer
aus, übernehmen die anderen.

---

## Häufige Fragen

**Muss ich Discord-Voice nutzen?**
Nein. Browser-Mikro reicht. Geht auch wenn ihr in Person spielt oder
über Zoom/Telegram/etc.

**Hört mich der Spielleiter live?**
Nein — der Browser streamt das Audio an den Worker, der erst nach
Session-Ende transkribiert. „Live-Mithören" gibt's nicht.

**Welcher Discord-Account zählt?**
Der, mit dem du beim LoreTracker eingeloggt bist. Dein Audio kommt aus
deinem Browser-Mikro — Discord-Voice spielt für die Aufnahme keine Rolle.

**Was wenn ich mitten in der Session dazustoße?**
Im Browser auf die Kampagne gehen → „Mit Mikro beitreten" — alles ab
diesem Moment wird mit aufgenommen. Was vorher passiert ist, fehlt
in deiner Spur.

**Wenn ich am Mikro vergesse zu klicken?**
Dein Anteil fehlt im Transkript. Die Recording-Bar zeigt „🎙 N streamen"
mit Namen — wenn du nicht in der Liste bist, ist dein Mikro aus.
Im Zweifel: Knopf drücken bevor du den ersten Satz sagst.

**Können mehrere Browser-Tabs aufnehmen?**
Nein, nur einer pro Spieler — der zweite Tab wird abgewiesen.

**Datenschutz?**
- Beim ersten Mikro-Klick blendet die UI ein Einwilligungs-Modal ein
  (Was wird aufgezeichnet? Wohin gestreamt? Wie lange gespeichert?).
  Ohne Häkchen + „Akzeptieren" startet die Aufnahme nicht. Die
  Zustimmung wird pro Discord-User einmal vermerkt.
- Audio bleibt auf dem Worker (Spielleiter-Rechner), wird nicht zum
  Hub gestreamt.
- Nur die Text-Transkripte landen im Event-Log am Hub.
- Sprich entsprechend nichts vors Mikro, was nicht in deinem
  Kampagnen-Buch stehen darf.

**Kann ich Text korrigieren?**
Ja — die Spalten sind editierbar:
- Protokoll: ✎ pro Zeile (Hover), Inline-Edit
- Resümee: ✎ pro Eintrag, Markdown-Editor
- Epos: Bearbeiten-Knopf, vollständiger Markdown-Editor + History
- Chronik: ✎ pro Eintrag (Datum/Titel/Summary)

Beim nächsten Pipeline-Lauf nutzt der LLM deinen korrigierten Text
als Ground-Truth.

**Debug-Zugriff für Support?**
Wenn dir ein Admin beim Debugging helfen will (z.B. „GM-Buttons sind grau
obwohl ich Spielleiter bin"), kannst du in **Einstellungen → Debug-Zugriff**
für 5/15/60 min einen temporären Lese-Zugriff aktivieren. Der Admin sieht
solange deinen Snapshot + deine berechneten Permissions in einer Kampagne
(Issue #144). Läuft automatisch ab; du kannst auch jederzeit „widerrufen"
klicken. Solange kein Toggle aktiv ist, hat niemand Zugriff.

---

## Für Spielleiter: einmaliges Setup

Wenn du eine Kampagne hosten willst, brauchst du einen **lokalen Worker**
auf deinem Rechner. Komplette Anleitung dafür: siehe
[`docs/Worker-Setup.md`](Worker-Setup.md).

In Kurzform:
1. Erlang/Elixir + ffmpeg + whisper.cpp + Ollama installieren
2. Repo klonen + `mix deps.get`
3. Worker mit `HUB_BASE_URL=https://loretracker.gigalixirapp.com`
   starten → Setup-Endpoint im Browser öffnet → Discord-OAuth-Pair
4. Im Browser bei LoreTracker einloggen: „+ Kampagne gründen" → Name
   eintragen → „Einladung erstellen" → Link an Mitspieler schicken
