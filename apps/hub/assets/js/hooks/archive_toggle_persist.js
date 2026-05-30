// Issue #57: Dashboard-Toggle "Archivierte zeigen" in LocalStorage pinnen.
//
// Beim Mount: gespeicherten Wert lesen + per `hydrate_show_archived` an die LV
// pushen. Beim folgenden `toggle_archived`-Event übernimmt die LV den Wechsel
// und broadcastet zurück; wir greifen das vom checkbox-State ab und schreiben
// LocalStorage neu.

const KEY = "lore.dashboard.show_archived";

export const ArchiveTogglePersist = {
  mounted() {
    try {
      const raw = localStorage.getItem(KEY);
      if (raw !== null) {
        const value = raw === "true";
        this.pushEvent("hydrate_show_archived", { value });
      }
    } catch (_) {}

    this.checkbox = this.el.querySelector('input[type="checkbox"]');
    if (!this.checkbox) return;

    this.handler = () => {
      try {
        localStorage.setItem(KEY, this.checkbox.checked ? "true" : "false");
      } catch (_) {}
    };
    this.checkbox.addEventListener("change", this.handler);
  },

  destroyed() {
    if (this.checkbox && this.handler) {
      this.checkbox.removeEventListener("change", this.handler);
    }
  },
};
