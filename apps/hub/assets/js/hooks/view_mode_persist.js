// Issue #915 (Epic #911, Cut 1): Lesen|Bearbeiten-Modus per-Gerät in
// localStorage pinnen (Muster ArchiveTogglePersist/PersistCols).
//
// Mount: gespeicherten Modus lesen + per `view_mode_restore` an die LV pushen
// (überlebt Reconnect, weil bei jedem Mount neu hydriert wird).
// Server → Client: `persist_view_mode` schreibt LS neu; `scroll_to_session`
// hält den Moduswechsel-Anker (zentrierte Session-Zeile, palette-unabhängig).

const key = (id) => `lore.campaign_view_mode.${id}`;

export const ViewModePersist = {
  mounted() {
    this.cid = this.el.dataset.campaignId;

    try {
      const raw = localStorage.getItem(key(this.cid));
      if (raw === "lesen" || raw === "bearbeiten") {
        this.pushEvent("view_mode_restore", { mode: raw });
      }
    } catch (_) {}

    this.handleEvent("persist_view_mode", ({ mode }) => {
      try {
        localStorage.setItem(key(this.cid), mode);
      } catch (_) {}
    });

    // Issue #1200: sofort umschalten. Knopf-Zustand und das Ausblenden der
    // Bearbeiten-Teile hängen per CSS an `data-view-mode` am Wurzel-div (s.
    // app.css) — hier wird es beim Klick direkt gesetzt, ohne auf die Antwort
    // des Servers zu warten; die kann beim Wechsel nach Bearbeiten Sekunden
    // brauchen. Bewusst KEIN `JS.set_attribute`: das wäre „sticky" und
    // überstimmte den Server auch dann, wenn er einen anderen Modus rendert
    // (Reconnect). So setzt der nächste Patch das Attribut auf seinen Wert.
    this.onModeClick = (e) => {
      const knopf = e.target.closest("[data-mode-knopf]");
      const root = document.getElementById("campaign-live-root");
      if (knopf && root) root.dataset.viewMode = knopf.dataset.modeKnopf;
    };
    this.el.addEventListener("click", this.onModeClick);

    this.handleEvent("scroll_to_session", ({ session_id }) => {
      // rAF: nach dem DOM-Patch (neue Palette gerendert) zentrieren; Fallback
      // top, wenn die Session-Zeile im Zielmodus nicht im DOM ist.
      requestAnimationFrame(() => {
        const row = document.querySelector(
          `[data-session-row="${session_id}"]`,
        );
        if (row) row.scrollIntoView({ block: "center", behavior: "auto" });
      });
    });
  },
};
