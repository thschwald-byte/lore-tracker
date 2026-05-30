// Issue #10: Scroll-Sync zwischen den 4 Spalten (Protokoll, Resümee,
// Epos, Chronik) via IntersectionObserver.
//
// Idee: wenn der User in einer Spalte scrollt (Master), reagieren die
// anderen Spalten (Slaves) passiv und scrollen den Anchor in den
// Viewport der zum gerade zentrierten Element in der Master-Spalte
// passt. Anchor-Mapping kommt vom Server via `data-sync-index` am
// LV-Root (siehe `build_sync_index/3` in CampaignLive).
//
// Loop-Prävention nutzt den `scrollend`-Event (Baseline seit Dez 2025
// in allen Major-Browsern): vor jedem programmatischen Scroll setzen
// wir ein Flag pro Slave-Container, der scrollend-Handler löscht es.
// Damit triggert ein vom Sync ausgelöster Scroll keinen Sync-Loop.
//
// Aktiv/Inaktiv ist per localStorage steuerbar — ein floating Toggle-
// Button unten rechts. Default an.
//
// Mobile (#17-Dependency): unter 768px Viewport-Breite ist der Hook
// stumm, weil Spalten dort als Tabs gerendert werden (sobald #17 das
// implementiert; bis dahin: Mobile-Browser haben einfach kein Sync).

const STORAGE_KEY = "lore.sync_cols.enabled";
// Tightest sensible debounce — IO bursts (mehrere thresholds pro Scroll-Tick)
// werden via requestAnimationFrame zu einem Sync-Run gebündelt.
const MOBILE_BREAKPOINT_PX = 768;

export const ColumnSync = {
  mounted() {
    this.enabled = readEnabled();
    this.master = null; // welcher data-col gerade Master ist (string oder null)
    this.programmatic = new Set(); // Cols mit aktivem programmatischen Scroll
    this.observers = []; // pro Container ein IO
    this.containers = new Map(); // data-col → HTMLElement
    this.rafPending = false; // requestAnimationFrame coalesce flag
    this.lastTargets = new Map(); // col → lastAnchorId (skip wenn unverändert)

    const idx = this.readSyncIndex() || {};
    const utts = Object.keys(idx.utts_to_entries || {}).length;
    const entries = Object.keys(idx.entries_to_utts || {}).length;
    console.log(`[ColumnSync] mounted — enabled=${this.enabled} viewport=${window.innerWidth}px sync-index: utts=${utts} entries=${entries}`);

    this.setupToggleButton();
    this.installObservers();
  },

  updated() {
    // Nach LV-Re-Render: neue/entfernte Items beobachten.
    console.log("[ColumnSync] updated — re-observing");
    this.installObservers();
  },

  destroyed() {
    this.teardownObservers();
    // Toggle-Button bleibt im DOM (vom Server gerendert).
  },

  // ─── Observer-Setup ───────────────────────────────────────────────

  installObservers() {
    if (window.innerWidth < MOBILE_BREAKPOINT_PX) {
      console.log("[ColumnSync] viewport <768px — Hook deaktiviert (Mobile-Stub)");
      return;
    }

    this.teardownObservers();

    const containers = this.el.querySelectorAll("[data-col]");
    console.log(`[ColumnSync] installObservers — ${containers.length} container gefunden:`, [...containers].map(c => c.dataset.col));

    containers.forEach((container) => {
      const col = container.dataset.col;
      this.containers.set(col, container);

      const items = container.querySelectorAll("[data-anchor-id], [data-utterance-id]");
      console.log(`[ColumnSync]   col=${col}: ${items.length} observable items`);

      // Master-Switch: erstes Wheel/Touch im Container → wird Master
      const onUserInput = () => {
        if (this.master !== col) {
          console.log(`[ColumnSync] master → ${col}`);
          this.master = col;
        }
      };
      container.addEventListener("wheel", onUserInput, { passive: true });
      container.addEventListener("touchstart", onUserInput, { passive: true });

      // scrollend-Listener: programmatic-Flag dieses Containers löschen
      container.addEventListener("scrollend", () => {
        if (this.programmatic.has(col)) {
          this.programmatic.delete(col);
        }
      });

      // Issue #10: native scroll-Events feuern auch wenn IO ruhig bleibt
      // (z.B. Single-Anchor-Master wie Epos: ein Article > Viewport, IO
      // ratio bleibt konstant). Trigger Sync auf jedes Scroll-Frame der
      // Master-Spalte.
      const onScroll = () => {
        if (!this.enabled) return;
        if (col !== this.master) return;
        if (this.programmatic.has(col)) return;
        if (this.rafPending) return;
        this.rafPending = true;
        requestAnimationFrame(() => {
          this.rafPending = false;
          this.syncFromMaster(col);
        });
      };
      container.addEventListener("scroll", onScroll, { passive: true });

      // IntersectionObserver pro Container
      const io = new IntersectionObserver(
        (entries) => this.onIntersect(col, entries),
        {
          root: container,
          threshold: [0, 0.25, 0.5, 0.75, 1],
        }
      );

      items.forEach((item) => io.observe(item));

      this.observers.push({ io, container, col, onUserInput });
    });
  },

  teardownObservers() {
    this.observers.forEach(({ io, container, onUserInput }) => {
      try { io.disconnect(); } catch {}
      container.removeEventListener("wheel", onUserInput);
      container.removeEventListener("touchstart", onUserInput);
    });
    this.observers = [];
    this.containers.clear();
  },

  // ─── Intersection-Callback ───────────────────────────────────────

  onIntersect(col, _entries) {
    if (!this.enabled) return;
    if (col !== this.master) return;
    if (this.programmatic.has(col)) return;

    // Coalesce mehrere IO-Callbacks innerhalb eines Frames zu einem
    // Sync-Run. requestAnimationFrame ist ~16ms statt 150ms-Debounce
    // → spürbar tighter, ohne Browser-Repaint zu doppeln.
    if (this.rafPending) return;
    this.rafPending = true;
    requestAnimationFrame(() => {
      this.rafPending = false;
      this.syncFromMaster(col);
    });
  },

  syncFromMaster(masterCol) {
    const container = this.containers.get(masterCol);
    if (!container) return;

    // Top-3 Anchors: index 0 = center (level 0), index 1-2 = Nachbarn (level 1).
    const nearby = this.findAnchorsNearCenter(container, 3);
    if (nearby.length === 0) return;

    this.clearAnchorHighlights();

    // Slave-Highlight-Akkumulator: pro (col,id) merkt sich das stärkste Level
    // (min wins — 0 ist stärker als 1).
    const slaveLevels = new Map(); // "col:id" → level

    nearby.forEach(({ id: anchorId }, idx) => {
      const level = idx === 0 ? 0 : 1;
      this.highlightAnchor(masterCol, anchorId, true, level);

      const targets = this.resolveTargets(masterCol, anchorId);
      targets.forEach(({ col, id }) => {
        if (col === masterCol) return;
        const key = `${col}:${id}`;
        const existing = slaveLevels.get(key);
        if (existing === undefined || level < existing) slaveLevels.set(key, level);
      });
    });

    slaveLevels.forEach((level, key) => {
      const sepIdx = key.indexOf(":");
      const col = key.slice(0, sepIdx);
      const id = key.slice(sepIdx + 1);
      this.highlightAnchor(col, id, false, level);
    });

    // Scroll-Mapping: nur vom level-0-Anchor angetrieben.
    const centerAnchor = nearby[0].id;
    const centerTargets = this.resolveTargets(masterCol, centerAnchor);
    const syncIdx = this.readSyncIndex();
    let scrollPicks = new Map();
    if (masterCol !== "protokoll") {
      const masterEl = container.querySelector(
        `[data-anchor-id="${cssEscape(centerAnchor)}"], [data-utterance-id="${cssEscape(centerAnchor)}"]`
      );
      const protoTargets = centerTargets.filter((t) => t.col === "protokoll");
      if (masterEl && protoTargets.length > 1) {
        const progress = elementScrollProgress(container, masterEl);
        const pickIdx = Math.min(Math.floor(progress * protoTargets.length), protoTargets.length - 1);
        const pickedUtt = protoTargets[pickIdx].id;
        scrollPicks.set("protokoll", pickedUtt);

        // Cross-derived auch der Scroll-Position folgen: andere derived
        // entries die den scroll-position-picked utt referenzieren
        // überschreiben das Count-basierte Auswahl-Ergebnis.
        const xEntries = syncIdx?.utts_to_entries?.[pickedUtt] || [];
        xEntries.forEach(({ col, id }) => {
          if (col === masterCol) return;
          scrollPicks.set(col, id);
        });
      }
    }

    const scrolledCols = new Set();
    centerTargets.forEach(({ col, id }) => {
      if (col === masterCol) return;
      if (!scrolledCols.has(col)) {
        scrolledCols.add(col);
        const pick = scrollPicks.get(col) || id;
        this.scrollSlaveTo(col, pick);
      }
    });
  },

  // ─── Anchor-Highlights ────────────────────────────────────────────

  clearAnchorHighlights() {
    this.el
      .querySelectorAll(
        ".col-sync-anchor, .col-sync-anchor-near, .col-sync-anchor-master, .col-sync-anchor-master-near"
      )
      .forEach((el) =>
        el.classList.remove(
          "col-sync-anchor",
          "col-sync-anchor-near",
          "col-sync-anchor-master",
          "col-sync-anchor-master-near"
        )
      );
  },

  highlightAnchor(col, anchorId, isMaster, level = 0) {
    const container = this.containers.get(col);
    if (!container) return;
    const sel = `[data-anchor-id="${cssEscape(anchorId)}"], [data-utterance-id="${cssEscape(anchorId)}"]`;
    const el = container.querySelector(sel);
    if (!el) return;
    const cls = isMaster
      ? level === 0 ? "col-sync-anchor-master" : "col-sync-anchor-master-near"
      : level === 0 ? "col-sync-anchor" : "col-sync-anchor-near";
    el.classList.add(cls);
  },

  // ─── Anchor-Detection ─────────────────────────────────────────────

  findCenterAnchor(container) {
    const list = this.findAnchorsNearCenter(container, 1);
    return list[0]?.id || null;
  },

  // Issue #10: Top-N Anchors sortiert nach Distanz zur Container-Mitte.
  // Liefert {id, dist} aufsteigend nach dist. Genutzt für mehrstufiges
  // Highlight (Level 0 = center, Level 1 = Nachbarn).
  findAnchorsNearCenter(container, limit) {
    const rect = container.getBoundingClientRect();
    const centerY = rect.top + rect.height / 2;
    const items = [];

    container.querySelectorAll("[data-anchor-id], [data-utterance-id]").forEach((el) => {
      const r = el.getBoundingClientRect();
      if (r.bottom < rect.top || r.top > rect.bottom) return;
      const itemCenter = r.top + r.height / 2;
      const dist = Math.abs(itemCenter - centerY);
      const id = el.dataset.anchorId || el.dataset.utteranceId;
      items.push({ id, dist });
    });

    items.sort((a, b) => a.dist - b.dist);
    return items.slice(0, limit);
  },

  // ─── Target-Resolution ────────────────────────────────────────────

  resolveTargets(masterCol, anchorId) {
    const idx = this.readSyncIndex();
    if (!idx) return [];

    if (masterCol === "protokoll") {
      // Anchor = utterance-id → ALLE derived entries die das refen.
      return idx.utts_to_entries?.[anchorId] || [];
    }

    // Master = derived col (chronik / summaries / epos).
    // Anchor = entry-id im Master. Source-utts = entries_to_utts[masterCol:anchorId].
    const key = `${masterCol}:${anchorId}`;
    const utts = idx.entries_to_utts?.[key] || [];

    // (a) ALLE source-utts als Protokoll-Targets — Block-Highlight.
    const targets = utts.map((u) => ({ col: "protokoll", id: u }));

    // (b) Cross-derived: utts → utts_to_entries → andere derived entries.
    // Pro Spalte das Entry mit der höchsten Overlap-Anzahl picken
    // (= das Entry das die meisten unserer source-utts teilt).
    const perColCounts = new Map(); // col → Map(id → count)
    utts.forEach((u) => {
      const entries = idx.utts_to_entries?.[u] || [];
      entries.forEach(({ col, id }) => {
        if (col === masterCol) return; // skip self-references
        if (!perColCounts.has(col)) perColCounts.set(col, new Map());
        const m = perColCounts.get(col);
        m.set(id, (m.get(id) || 0) + 1);
      });
    });

    perColCounts.forEach((idCounts, col) => {
      let bestId = null;
      let bestCount = 0;
      idCounts.forEach((count, id) => {
        if (count > bestCount) {
          bestCount = count;
          bestId = id;
        }
      });
      if (bestId) targets.push({ col, id: bestId });
    });

    return targets;
  },

  readSyncIndex() {
    if (this._cachedIndexRaw === this.el.dataset.syncIndex) {
      return this._cachedIndex;
    }
    try {
      this._cachedIndexRaw = this.el.dataset.syncIndex;
      this._cachedIndex = JSON.parse(this._cachedIndexRaw || "{}");
      return this._cachedIndex;
    } catch (e) {
      console.warn("ColumnSync: invalid data-sync-index JSON", e);
      return null;
    }
  },

  // ─── Programmatic Scroll ──────────────────────────────────────────

  scrollSlaveTo(col, anchorId) {
    if (this.lastTargets.get(col) === anchorId) return;
    this.lastTargets.set(col, anchorId);

    const container = this.containers.get(col);
    if (!container) return;

    const sel = `[data-anchor-id="${cssEscape(anchorId)}"], [data-utterance-id="${cssEscape(anchorId)}"]`;
    const target = container.querySelector(sel);
    if (!target) {
      // Issue #370: utt nicht im DOM — Protokoll-Sessions sind per default
      // collapsed. Wenn wir die session_id wissen, triggern wir den
      // protokoll_session_toggle (phx-click). Der LV-Re-Render landet im
      // updated()-Lifecycle → reobserve → nächster Sync-Tick findet die utt.
      // Nur EINMAL pro id versuchen — sonst Endlos-Toggle wenn die utt aus
      // anderen Gründen fehlt.
      this.tryAutoExpand(col, anchorId);
      return;
    }

    this.programmatic.add(col);
    target.scrollIntoView({ behavior: "auto", block: "center" });
  },

  tryAutoExpand(col, anchorId) {
    if (col !== "protokoll") return;
    const idx = this.readSyncIndex();
    const sid = idx?.utt_sessions?.[anchorId];
    if (!sid) return;

    // Schon versucht? — vermeidet Re-Toggle-Cascade wenn der Click nicht
    // expandiert (z.B. wenn die utt aus anderen Gründen fehlt).
    if (!this.autoExpandedSessions) this.autoExpandedSessions = new Set();
    if (this.autoExpandedSessions.has(sid)) return;
    this.autoExpandedSessions.add(sid);

    const btn = document.querySelector(
      `[phx-click="protokoll_session_toggle"][phx-value-session="${cssEscape(sid)}"]`
    );
    if (btn) {
      console.log(`[ColumnSync] auto-expanding session=${sid} (utt=${anchorId} collapsed)`);
      btn.click();
    }
  },

  // ─── Toggle-Button ─────────────────────────────────────────────────

  setupToggleButton() {
    // Issue #10: adopt server-rendered #col-sync-toggle-btn aus dem
    // Recording-Bar-Header statt floating-Position. So bleibt der Button
    // im Tab-Flow + folgt der bestehenden Toolbar-Optik.
    const btn = document.getElementById("col-sync-toggle-btn");
    if (!btn) return;
    this.toggleBtn = btn;
    this.updateToggleVisual();

    btn.addEventListener("click", () => {
      this.enabled = !this.enabled;
      writeEnabled(this.enabled);
      this.updateToggleVisual();
      if (!this.enabled) this.clearAnchorHighlights();
    });
  },

  updateToggleVisual() {
    if (!this.toggleBtn) return;
    // Inline-Style statt classList — Tailwind purgeb dynamische Klassen
    // gerne (text-accent / border-accent/40 müssten via safelist sein),
    // außerdem konfligieren sie mit den text-fg-Klassen aus dem HTML.
    if (this.enabled) {
      this.toggleBtn.style.color = "rgb(var(--color-primary))";
      this.toggleBtn.style.borderColor = "rgb(var(--color-primary) / 0.4)";
      this.toggleBtn.title = "Referenzen: an (klick deaktiviert Spalten-Sync)";
    } else {
      this.toggleBtn.style.color = "rgb(var(--color-fg-muted))";
      this.toggleBtn.style.borderColor = "rgba(255,255,255,0.1)";
      this.toggleBtn.title = "Referenzen: aus (klick aktiviert Spalten-Sync)";
    }
  },
};

// ─── Helpers ─────────────────────────────────────────────────────────

function readEnabled() {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === null ? true : v === "true";
  } catch {
    return true;
  }
}

function writeEnabled(v) {
  try {
    localStorage.setItem(STORAGE_KEY, String(!!v));
  } catch {}
}

function cssEscape(s) {
  if (window.CSS && window.CSS.escape) return window.CSS.escape(s);
  return String(s).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
}

// Issue #10: relative Scroll-Position INNERHALB eines Anchor-Elements
// gemessen vom Container-Zentrum aus. Returnt 0..1 wo 0 = Anchor-Top auf
// Container-Mitte, 1 = Anchor-Bottom auf Container-Mitte. Wird für die
// Block-Mapping bei langen Single-Anchor-Mastern (Epos) genutzt.
function elementScrollProgress(container, el) {
  const cRect = container.getBoundingClientRect();
  const eRect = el.getBoundingClientRect();
  const containerCenter = cRect.top + cRect.height / 2;
  const progress = (containerCenter - eRect.top) / Math.max(eRect.height, 1);
  return Math.max(0, Math.min(1, progress));
}
