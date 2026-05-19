// Per-Campaign column-collapse persistence (Issue #8).
//
// On mount: reads localStorage for this campaign and pushes the restored
// list to the LV via `col_restore`. The LV validates against its
// whitelist and last-one-standing invariant.
//
// On server-pushed `persist_cols`: writes the new collapsed list back to
// localStorage. Triggered by the LV's `col_toggle` handler.
//
// Storage key is scoped per campaign so the user can have different
// layouts in different campaigns. The hook element carries the
// campaign id via `data-campaign-id` (set by the LV template).

const KEY_PREFIX = "lore.campaign_cols.";

function storageKey(el) {
  const id = el.dataset.campaignId;
  return id ? KEY_PREFIX + id : null;
}

export const PersistCols = {
  mounted() {
    const key = storageKey(this.el);
    if (!key) return;

    try {
      const raw = localStorage.getItem(key);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          this.pushEvent("col_restore", { collapsed: parsed });
        }
      }
    } catch (_e) {
      // Corrupt JSON or no access — silently ignore. LV stays at defaults.
    }

    this.handleEvent("persist_cols", ({ collapsed }) => {
      const k = storageKey(this.el);
      if (!k || !Array.isArray(collapsed)) return;
      try {
        localStorage.setItem(k, JSON.stringify(collapsed));
      } catch (_e) {
        // Quota or private mode — fail silently. State stays in-memory only.
      }
    });
  },
};
