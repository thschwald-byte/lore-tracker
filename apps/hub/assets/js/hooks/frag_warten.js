// Issue #850: der Wartetext im Frag-Fenster — Braille-Spinner plus wechselnde
// Sprüche (Worker.Warten liefert sie, hier laufen sie).
//
// Warum im Browser und nicht auf dem Server: Bei zwei Minuten Laufzeit wären
// das rund fünfzig Diffs für eine Textzeile (#1200-Klasse). Der Server sagt
// einmal, WELCHE Sprüche es gibt; gedreht wird hier.
//
// Der Spinner ist bewusst kein Würfel: Ein Würfel sagt „Zufall", und das ist
// die falsche Botschaft für eine Antwort, die ausschließlich aus geprüften
// Fakten stammt.

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const SPINNER_MS = 80;

export const FragWarten = {
  mounted() {
    this.spruecheEl = this.el.querySelector("[data-spruch]");
    this.spinnerEl = this.el.querySelector("[data-spinner]");

    let liste = [];
    try {
      liste = JSON.parse(this.el.dataset.sprueche || "[]");
    } catch (_) {
      liste = [];
    }
    this.liste = mische(liste);
    this.i = 0;
    this.s = 0;

    // Wer Bewegung abbestellt hat, bekommt den Text ohne Zappeln — die Sprüche
    // wechseln weiter, denn sie sind die Information, nicht die Zierde.
    this.ruhig = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;

    this.zeige();
    if (!this.ruhig) {
      this.spinTimer = setInterval(() => this.dreh(), SPINNER_MS);
    }
    const ms = parseInt(this.el.dataset.wechselMs || "2500", 10);
    this.textTimer = setInterval(() => this.weiter(), ms);
  },

  destroyed() {
    clearInterval(this.spinTimer);
    clearInterval(this.textTimer);
  },

  dreh() {
    this.s = (this.s + 1) % SPINNER.length;
    if (this.spinnerEl) this.spinnerEl.textContent = SPINNER[this.s];
  },

  weiter() {
    if (this.liste.length < 2) return;
    this.i = (this.i + 1) % this.liste.length;
    this.zeige();
  },

  zeige() {
    if (this.spruecheEl && this.liste.length) {
      this.spruecheEl.textContent = this.liste[this.i];
    }
  },
};

// Fisher-Yates: Jeder Lauf beginnt woanders, damit nicht jedes Mal dieselben
// drei Sprüche zu sehen sind — bei fünfzig Stück und zwei Minuten Laufzeit
// sieht man ohnehin nur eine Handvoll.
function mische(a) {
  const b = a.slice();
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
}
