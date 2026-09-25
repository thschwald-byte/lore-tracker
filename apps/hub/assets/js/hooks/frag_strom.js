// Der Denkstrom eines Frage-Laufs (#850).
//
// Er kommt per `push_event`, NICHT über die Assigns: Über einen Lauf sammeln
// sich Tausende Token, und in den Assigns würde das bei jedem Diff kopiert und
// gehalten (#1146). Hier landet es direkt im DOM und wird gedeckelt.
//
// Gedeckelt wird auf @max Zeilen — wer nach fünf Minuten zurückkommt, will
// sehen, was gerade läuft, nicht was vor vier Minuten lief.
const MAX_ZEILEN = 60;

export const FragStrom = {
  mounted() {
    this.handleEvent("frag_strom", ({ stuecke }) => this.anhaengen(stuecke));
  },

  updated() {
    // Nach einem Re-Render ist der Hook derselbe; der Inhalt bleibt, weil
    // phx-update="ignore" am Element steht.
  },

  anhaengen(stuecke) {
    if (!Array.isArray(stuecke)) return;

    // Am Ende kleben ist nur richtig, wenn der Betrachter auch am Ende steht.
    // Wer hochgescrollt hat, liest etwas — dem reissen wir es nicht weg.
    const amEnde =
      this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24;

    for (const s of stuecke) {
      const zeile = document.createElement("div");
      zeile.className = klasse(s.art);
      zeile.textContent = zeichen(s.art) + (s.text || "");
      this.el.appendChild(zeile);
    }

    while (this.el.childElementCount > MAX_ZEILEN) {
      this.el.removeChild(this.el.firstElementChild);
    }

    if (amEnde) this.el.scrollTop = this.el.scrollHeight;
  },
};

function klasse(art) {
  if (art === "denken") return "text-ink-2/45 italic font-sans";
  if (art === "werkzeug") return "text-primary/70";
  return "text-ink-2/40";
}

function zeichen(art) {
  if (art === "denken") return "💭 ";
  if (art === "werkzeug") return "🔎 ";
  return "→ ";
}
