// Issue #709: Scroll-Anchoring für das gleitende Utterance-Fenster.
//
// Wenn beim Hochscrollen ältere Zeilen OBEN eingefügt werden (Fenster-Prepend
// via phx-viewport-top), verschiebt sich der sichtbare Inhalt nach unten und
// die Ansicht "springt". Wir merken uns vor dem Patch die oberste sichtbare
// Zeile + ihren Abstand zur Container-Oberkante und stellen nach dem Patch
// scrollTop so wieder her, dass diese Ankerzeile optisch stehen bleibt.
// Anker-Row-Technik: funktioniert für Prepend UND Append, ohne Richtungsflag.
//
// Attached auf dem Protokoll-Scroll-Container (`#protokoll-scroll`) und seit
// #883 auch auf der Geglättet-Spalte (`#glatt-scroll`, Anker dort =
// data-anchor-id der Blöcke) via phx-hook="UtteranceWindow".
const ROW_SELECTOR = "[data-utterance-id], [data-anchor-id]";

function rowId(el) {
  return el.dataset.utteranceId || el.dataset.anchorId;
}

export const UtteranceWindow = {
  beforeUpdate() {
    const c = this.el;
    const cTop = c.getBoundingClientRect().top;
    const rows = c.querySelectorAll(ROW_SELECTOR);
    // Erste Zeile, deren Oberkante an/unter der Container-Oberkante liegt.
    this._anchorId = null;
    for (const r of rows) {
      if (r.getBoundingClientRect().top >= cTop) {
        this._anchorId = rowId(r);
        this._anchorGap = r.getBoundingClientRect().top - cTop;
        break;
      }
    }
  },

  updated() {
    if (!this._anchorId) return;
    const esc = cssEscape(this._anchorId);
    const el = this.el.querySelector(
      `[data-utterance-id="${esc}"], [data-anchor-id="${esc}"]`
    );
    this._anchorId = null;
    if (!el) return; // Anker wurde evincd → nichts zu tun.
    const cTop = this.el.getBoundingClientRect().top;
    const now = el.getBoundingClientRect().top - cTop;
    this.el.scrollTop += now - this._anchorGap;
  },
};

function cssEscape(s) {
  if (window.CSS && window.CSS.escape) return window.CSS.escape(s);
  return String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}
