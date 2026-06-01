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

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
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
