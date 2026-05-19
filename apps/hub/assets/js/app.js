// LoreTracker hub frontend
//
// Phoenix LiveView wire-up. No app-specific JS yet; everything is server-rendered.

import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { RecordMic } from "./hooks/record_mic";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { RecordMic },
});

liveSocket.connect();
window.liveSocket = liveSocket;
