// Browser-mic capture hook for LoreTracker (M10-BMP).
//
// Attached via `phx-hook="RecordMic"` on a wrapper div in CampaignLive.
// The server pushes:
//   - "mic:start" {session_id} → start getUserMedia + MediaRecorder
//   - "mic:stop"  {}           → stop and release tracks
//
// On each MediaRecorder chunk (~500 ms) we push back:
//   pushEvent("audio_chunk", {session_id, chunk: <base64>})
//
// The LiveView then forwards via Hub.Commands.forward_audio_chunk/4.
export const RecordMic = {
  mounted() {
    this.recorder = null;
    this.stream = null;
    this.sessionId = null;

    this.handleEvent("mic:start", ({ session_id }) => this.start(session_id));
    this.handleEvent("mic:stop", () => this.stop());
  },

  destroyed() {
    this.stop();
  },

  async start(sessionId) {
    if (this.recorder) {
      console.warn("RecordMic: already running, ignoring start");
      return;
    }

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      this.pushEvent("mic_error", { reason: "no_getusermedia" });
      return;
    }

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (err) {
      console.error("RecordMic: getUserMedia denied", err);
      this.pushEvent("mic_error", { reason: "permission_denied" });
      return;
    }

    const mime = pickMime();
    if (!mime) {
      this.pushEvent("mic_error", { reason: "no_codec" });
      this.releaseStream();
      return;
    }

    this.sessionId = sessionId;
    this.recorder = new MediaRecorder(this.stream, { mimeType: mime });

    this.recorder.ondataavailable = async (ev) => {
      if (!ev.data || ev.data.size === 0) return;
      const b64 = await blobToBase64(ev.data);
      this.pushEvent("audio_chunk", { session_id: this.sessionId, chunk: b64 });
    };

    this.recorder.onstop = () => {
      this.releaseStream();
      this.recorder = null;
      this.sessionId = null;
    };

    // 500 ms slices keep latency low + chunks small.
    this.recorder.start(500);
    this.pushEvent("mic_started", { session_id: sessionId });
  },

  stop() {
    if (!this.recorder) return;
    try {
      this.recorder.stop();
    } catch (_) {
      this.releaseStream();
      this.recorder = null;
      this.sessionId = null;
    }
  },

  releaseStream() {
    if (this.stream) {
      this.stream.getTracks().forEach((t) => t.stop());
      this.stream = null;
    }
  },
};

function pickMime() {
  const candidates = [
    "audio/webm;codecs=opus",
    "audio/webm",
    "audio/ogg;codecs=opus",
    "audio/ogg",
  ];

  for (const c of candidates) {
    if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(c)) {
      return c;
    }
  }
  return null;
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onloadend = () => {
      // data:<mime>;base64,<payload>  →  <payload>
      const idx = r.result.indexOf(",");
      resolve(idx >= 0 ? r.result.slice(idx + 1) : r.result);
    };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}
