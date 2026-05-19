// Browser-mic capture hook for LoreTracker (M10-BMP).
//
// Attached via `phx-hook="RecordMic"` on a wrapper div in CampaignLive.
// The server pushes:
//   - "mic:start" {session_id, source?} → start audio capture + MediaRecorder
//        source: "mic"    (default) → getUserMedia (microphone)
//                "system" (dev/Listen-Modus) → getDisplayMedia (tab/system audio)
//   - "mic:stop"  {}                    → stop and release tracks
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

    this.handleEvent("mic:start", ({ session_id, source }) =>
      this.start(session_id, source || "mic")
    );
    this.handleEvent("mic:stop", () => this.stop());
  },

  destroyed() {
    this.stop();
  },

  async start(sessionId, source) {
    if (this.recorder) {
      console.warn("RecordMic: already running, ignoring start");
      return;
    }

    if (!navigator.mediaDevices) {
      this.pushEvent("mic_error", { reason: "no_mediadevices" });
      return;
    }

    try {
      if (source === "system") {
        if (!navigator.mediaDevices.getDisplayMedia) {
          this.pushEvent("mic_error", { reason: "no_getdisplaymedia" });
          return;
        }

        // User picks a tab/window and (critically) ticks the "Share audio"
        // checkbox. Chromium on Linux supports this for tab-audio; Firefox
        // is hit-and-miss.
        this.stream = await navigator.mediaDevices.getDisplayMedia({
          audio: true,
          video: false,
        });

        const audioTracks = this.stream.getAudioTracks();
        if (audioTracks.length === 0) {
          console.warn("RecordMic: getDisplayMedia returned no audio tracks");
          this.releaseStream();
          this.pushEvent("mic_error", { reason: "no_system_audio" });
          return;
        }

        // Drop any incidental video tracks so MediaRecorder doesn't try to
        // encode video too.
        this.stream.getVideoTracks().forEach((t) => {
          t.stop();
          this.stream.removeTrack(t);
        });
      } else {
        if (!navigator.mediaDevices.getUserMedia) {
          this.pushEvent("mic_error", { reason: "no_getusermedia" });
          return;
        }
        this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      }
    } catch (err) {
      console.error(`RecordMic: capture denied (source=${source})`, err);
      this.pushEvent("mic_error", {
        reason: source === "system" ? "system_audio_denied" : "permission_denied",
      });
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
