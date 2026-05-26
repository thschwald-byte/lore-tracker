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
      // Defer one tick so any session-toggle re-render finishes first.
      requestAnimationFrame(() => {
        const el = document.querySelector(`[data-utterance-id="${cssEscape(id)}"]`);
        if (!el) {
          console.warn(`ScrollToUtterance: no element for id=${id}`);
          return;
        }
        el.scrollIntoView({ behavior: "smooth", block: "center" });
        el.classList.add("ref-highlight");
        setTimeout(() => el.classList.remove("ref-highlight"), 2000);
      });
    });
  },
};

function cssEscape(s) {
  if (window.CSS && window.CSS.escape) return window.CSS.escape(s);
  return String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}
