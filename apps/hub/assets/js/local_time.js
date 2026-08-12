// Issue #1014: Zeitstempel in der Geräte-Zeitzone anzeigen.
//
// Gespeichert und serverseitig gerendert wird IMMER UTC — der Server kennt
// keine Zeitzone und soll keine kennen. Dieses Modul schreibt den sichtbaren
// Text von `<time data-local-time>`-Elementen in die lokale Zone um.
//
// ## Warum kein LiveView-Hook
//
// `phx-hook` verlangt eine eindeutige DOM-`id` pro Element. Zeitstempel stehen
// aber in Schleifen (jede Utterance eine Zeile) — id-Vergabe an jeder Call-Site
// wäre fehleranfällig, und ein Duplikat bricht LiveView. Ein MutationObserver
// auf `document.body` braucht überhaupt keine ids, greift auch außerhalb von
// LiveView (dead views) und deckt nachgeladene Zeilen automatisch mit ab.
//
// ## Warum das " UTC"-Kürzel der Marker ist
//
// Der Server rendert `14:32:10 UTC`. Formatiert ist ein Element genau dann,
// wenn das Kürzel WEG ist — daraus folgt Idempotenz ohne Buchhaltung: ein
// zweiter Durchlauf über dasselbe Element tut nichts. Und weil LiveView bei
// jedem Patch den Server-Text (mit Kürzel) zurückschreibt, erkennt derselbe
// Test zuverlässig, dass neu formatiert werden muss. `characterData` im
// Observer ist deshalb PFLICHT: morphdom ersetzt bei einem Diff oft nur den
// Textknoten, ohne dass je eine childList-Mutation anfällt.
//
// Ohne JavaScript (oder im Moment davor) bleibt der Server-Text stehen — eine
// korrekt als UTC beschriftete Zeit. Das ist der Grund für das Kürzel: ein
// stilles, unbeschriftetes UTC wäre eine Falschaussage, kein Schönheitsfehler.

const SUFFIX = " UTC";
const SELECTOR = "time[data-local-time]";

const OPTIONS = {
  time: { hour: "2-digit", minute: "2-digit", second: "2-digit" },
  datetime: {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  },
  datetime_sec: {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  },
};

function formatEl(el) {
  // Schon umgeschrieben → nichts tun (s. Marker-Begründung oben).
  if (!el.textContent.endsWith(SUFFIX)) return;

  const iso = el.getAttribute("datetime");
  if (!iso) return;

  const date = new Date(iso);
  // Fail-safe: bei unparsebarem Wert bleibt der beschriftete Server-Text
  // stehen. Lieber eine korrekte UTC-Zeit als "Invalid Date".
  if (Number.isNaN(date.getTime())) return;

  const opts = OPTIONS[el.dataset.localTime];
  if (!opts) return;

  try {
    // `undefined` als Locale: die Browser-Einstellung des Nutzers gewinnt,
    // nicht ein hier festgenageltes de-DE.
    el.textContent = date.toLocaleString(undefined, opts);
  } catch (_) {}
}

function sweep(root) {
  if (!root || typeof root.querySelectorAll !== "function") return;
  if (root.matches && root.matches(SELECTOR)) formatEl(root);
  root.querySelectorAll(SELECTOR).forEach(formatEl);
}

function onMutations(records) {
  for (const rec of records) {
    if (rec.type === "characterData") {
      // Textknoten gepatcht → das tragende <time> ist der Elternknoten.
      const el = rec.target.parentElement;
      if (el && el.matches && el.matches(SELECTOR)) formatEl(el);
    } else {
      rec.addedNodes.forEach((node) => {
        if (node.nodeType === Node.ELEMENT_NODE) sweep(node);
      });
    }
  }
}

export function startLocalTime() {
  const run = () => {
    sweep(document.body);

    new MutationObserver(onMutations).observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true,
    });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run, { once: true });
  } else {
    run();
  }
}
