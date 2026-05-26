// Issue #268: claude.ai-Style einklappbare Sidebar mit localStorage-Persistenz.
//
// Hook am Toggle-Button (#sidebar-toggle). Beim Mount: liest
// localStorage["sidebar:collapsed"] und setzt data-collapsed auf #app-sidebar.
// Beim Click: toggled das Attribut + speichert es in localStorage.
//
// State lebt rein im DOM + localStorage, keine LV-Roundtrips — so überlebt
// der Toggle auch LV-Navigationen ohne Re-Mount-Flicker.

export const SidebarToggle = {
  mounted() {
    const sidebar = document.getElementById("app-sidebar");
    if (!sidebar) return;

    // Initial-State aus localStorage anwenden
    const stored = localStorage.getItem("sidebar:collapsed");
    if (stored === "true") {
      sidebar.setAttribute("data-collapsed", "true");
    }

    this.handleClick = () => {
      const isCollapsed = sidebar.getAttribute("data-collapsed") === "true";
      const next = !isCollapsed;
      sidebar.setAttribute("data-collapsed", String(next));
      localStorage.setItem("sidebar:collapsed", String(next));
    };

    this.el.addEventListener("click", this.handleClick);
  },

  destroyed() {
    if (this.handleClick) {
      this.el.removeEventListener("click", this.handleClick);
    }
  },
};
