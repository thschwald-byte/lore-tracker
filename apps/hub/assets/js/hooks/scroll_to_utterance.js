// Issue #114: Scroll-to-Utterance hook.
//
// LiveView pushes `scroll_to_utterance` with `{id}` when the user clicks
// an entry in the source-refs popover. We find the utterance card by
// `[data-utterance-id="<id>"]`, scroll it into view, and add a highlight
// class for 2s.
//
// Attached on the Campaign-LV root via `phx-hook="ScrollToUtterance"`.
export const ScrollToUtterance = {
  mounted() {
    this.handleEvent("scroll_to_utterance", ({ id }) => {
      if (!id) return;
      // Issue #709: die Ziel-Zeile kann durch ein gleichzeitiges Fenster-/
      // Expand-Re-Render (focus_utterance) erst ein paar Frames später im DOM
      // erscheinen — bis zu 3 rAF-Versuche, bevor wir aufgeben.
      const sel = `[data-utterance-id="${cssEscape(id)}"]`;
      let tries = 0;
      const attempt = () => {
        const el = document.querySelector(sel);
        if (el) {
          el.scrollIntoView({ behavior: "smooth", block: "center" });
          el.classList.add("ref-highlight");
          setTimeout(() => el.classList.remove("ref-highlight"), 2000);
          return;
        }
        if (++tries < 3) {
          requestAnimationFrame(attempt);
        } else {
          console.warn(`ScrollToUtterance: no element for id=${id}`);
        }
      };
      requestAnimationFrame(attempt);
    });
  },
};

function cssEscape(s) {
  if (window.CSS && window.CSS.escape) return window.CSS.escape(s);
  return String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}
