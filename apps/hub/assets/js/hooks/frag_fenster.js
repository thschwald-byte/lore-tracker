// Issue #850: das Fenster „Frag die Runde" — bewegen, Größe merken, öffnen.
//
// Warum der Dialog dauerhaft im DOM liegt und nicht per `:if` erscheint: Ein
// neu gemounteter Dialog verlöre Position und Größe bei jedem Öffnen. Der
// Server sagt über `data-offen`, was gelten soll; hier wird es ausgeführt.
//
// `.show()`, NIE `.showModal()` — nicht-modal heißt: kein Backdrop, nichts
// wird inert, Escape schließt nicht, und ein Klick in eine Spalte lässt das
// Fenster stehen. Genau dafür ist es beweglich.
//
// Position und Größe leben per Gerät in localStorage (Muster ViewModePersist,
// PersistCols) — nicht im Worker: Wo jemand sein Fenster hinschiebt, ist kein
// Wissen über die Kampagne.

const KEY = (cid) => `lore.frag_fenster.${cid}`;
const RAND = 8; // px, die sichtbar bleiben müssen

export const FragFenster = {
  mounted() {
    this.cid = this.el.dataset.campaignId || "default";
    this.griff = this.el.querySelector("[data-frag-griff]");

    this.stelleHer();
    this.spiegleOffen();

    this.onDown = (e) => this.greife(e);
    this.griff && this.griff.addEventListener("pointerdown", this.onDown);

    // Größe kommt von CSS `resize`, nicht von uns — wir merken sie nur.
    this.ro = new ResizeObserver(() => this.merke());
    this.ro.observe(this.el);
  },

  updated() {
    this.spiegleOffen();
  },

  destroyed() {
    this.griff && this.griff.removeEventListener("pointerdown", this.onDown);
    this.ro && this.ro.disconnect();
  },

  // ——— öffnen / schließen ———————————————————————————————

  spiegleOffen() {
    const soll = this.el.dataset.offen === "true";
    if (soll && !this.el.open) {
      this.el.show(); // NICHT showModal()
      this.stelleHer(); // nach dem Öffnen: hat das Fenster noch Platz?
      const feld = this.el.querySelector("input[name=frage]");
      feld && feld.focus();
    } else if (!soll && this.el.open) {
      this.el.close();
    }
  },

  // ——— ziehen ————————————————————————————————————————————

  greife(e) {
    if (e.button !== 0) return;
    const r = this.el.getBoundingClientRect();
    this.ab = { x: e.clientX - r.left, y: e.clientY - r.top };

    this.onMove = (ev) => this.ziehe(ev);
    this.onUp = () => this.lass();
    window.addEventListener("pointermove", this.onMove);
    window.addEventListener("pointerup", this.onUp, { once: true });
    e.preventDefault();
  },

  ziehe(e) {
    const r = this.el.getBoundingClientRect();
    this.setze(
      this.imBild(e.clientX - this.ab.x, window.innerWidth, r.width),
      this.imBild(e.clientY - this.ab.y, window.innerHeight, r.height),
    );
  },

  lass() {
    window.removeEventListener("pointermove", this.onMove);
    this.merke();
  },

  // ——— Position ————————————————————————————————————————————

  // Ein Fenster, das aus dem Bild geschoben wurde, ist unerreichbar — und mit
  // ihm die Antwort auf einen offenen Befund. Deshalb bleibt immer ein Rand
  // sichtbar, beim Ziehen wie beim Wiederherstellen (kleinerer Schirm später).
  imBild(v, aussen, eigen) {
    return Math.max(RAND - eigen + 40, Math.min(v, aussen - RAND - 40));
  },

  setze(x, y) {
    this.el.style.left = `${x}px`;
    this.el.style.top = `${y}px`;
    this.el.style.right = "auto";
    this.el.style.bottom = "auto";
  },

  stelleHer() {
    let s = null;
    try {
      s = JSON.parse(localStorage.getItem(KEY(this.cid)) || "null");
    } catch (_) {
      // localStorage nicht verfügbar (privates Fenster) — Standardplatz.
    }
    const r = this.el.getBoundingClientRect();
    const w = (s && s.w) || r.width || 420;
    const h = (s && s.h) || r.height || 560;

    if (s && s.w) this.el.style.width = `${w}px`;
    if (s && s.h) this.el.style.height = `${h}px`;

    const x = s && s.x != null ? s.x : window.innerWidth - w - 24;
    const y = s && s.y != null ? s.y : window.innerHeight - h - 24;
    this.setze(this.imBild(x, window.innerWidth, w), this.imBild(y, window.innerHeight, h));
  },

  merke() {
    const r = this.el.getBoundingClientRect();
    if (!r.width) return;
    try {
      localStorage.setItem(
        KEY(this.cid),
        JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height }),
      );
    } catch (_) {
      // nicht schlimm — das Fenster funktioniert auch ohne Gedächtnis.
    }
  },
};
