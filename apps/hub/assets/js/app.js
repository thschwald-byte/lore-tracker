// LoreTracker hub frontend
//
// Phoenix LiveView wire-up. No app-specific JS yet; everything is server-rendered.

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { MicSetup, MicCapture } from "./hooks/record_mic";
import { Signals } from "./hooks/signals";
import { PersistCols } from "./hooks/persist_cols";
import { CopyToClipboard } from "./hooks/copy_to_clipboard";
import { SidebarToggle } from "./hooks/sidebar_toggle";
import { ScrollToUtterance } from "./hooks/scroll_to_utterance";
import { IconUpload } from "./hooks/icon_upload";
import { ArchiveTogglePersist } from "./hooks/archive_toggle_persist";
import { ColumnSync } from "./hooks/column_sync";
import liveSelect from "live_select";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// Issue #387: zuletzt besuchte Kampagne in LocalStorage merken. CampaignLive
// pinnt die ID via push_event "save-last-campaign"; LiveSocket-params-Funktion
// liefert sie bei jedem Connect/Reconnect ans Backend, wo HubWeb.SidebarContext
// via get_connect_params die Campaign nachlädt und in current_campaign assigned.
const LAST_CAMPAIGN_KEY = "lore.last_campaign_id";

// Issue #702: Reconnect-Stampede-Härtung. Der Phoenix-Default-Backoff startet
// bei 10 ms und cappt bei 5 s — ohne Jitter. Nach einem Pod-Reboot hämmern so
// alle Clients synchron auf den frischen Hub (jeder Mount = voller Snapshot-
// Read), was den OOM-Loop am Leben hielt. Langsamere Steps + Jitter.
const reconnectAfterMs = (tries) => {
  const base = [1000, 2000, 5000, 10000][tries - 1] || 10000;
  return base + Math.floor(Math.random() * base * 0.5);
};

// Issue #702: Longpoll-Stickiness lösen. Phoenix merkt sich einen Transport-
// Fallback in sessionStorage ("phx:fallback:<TransportName>", Name im Bundle
// ggf. minifiziert → Prefix-Match) — Clients aus einer 502-Phase blieben so
// dauerhaft auf Longpoll (serverseitige Pufferung = RAM pro Client). Ein
// frischer Page-Load soll wieder WebSocket probieren.
try {
  Object.keys(sessionStorage)
    .filter((k) => k.startsWith("phx:fallback:"))
    .forEach((k) => sessionStorage.removeItem(k));
} catch (_) {}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 5000,
  reconnectAfterMs,
  params: () => {
    const params = { _csrf_token: csrfToken };
    try {
      const v = localStorage.getItem(LAST_CAMPAIGN_KEY);
      if (v) params.last_campaign_id = v;
    } catch (_) {}
    return params;
  },
  hooks: { MicSetup, MicCapture, Signals, PersistCols, CopyToClipboard, SidebarToggle, ScrollToUtterance, IconUpload, ArchiveTogglePersist, ColumnSync, ...liveSelect },
});

window.addEventListener("phx:save-last-campaign", (e) => {
  try {
    if (e.detail && e.detail.id) {
      localStorage.setItem(LAST_CAMPAIGN_KEY, e.detail.id);
    }
  } catch (_) {}
});

liveSocket.connect();
window.liveSocket = liveSocket;
