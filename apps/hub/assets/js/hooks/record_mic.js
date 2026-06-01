// Browser-mic hooks for LoreTracker.
//
// Issue #405 split the old single RecordMic hook into two, so the live
// recording capture can survive page navigation:
//
//   MicSetup   — lives in CampaignLive. Device-enumeration + setup-modal VU +
//                (Issue #400) the phrase-recognition test: as soon as a device
//                is open it auto-listens (NO record button), captures the
//                spoken phrase as a short clip via MediaRecorder and ships it
//                to the server for ASR. On a match the LiveView hands off to
//                MicLive; on a miss the server re-arms listening.
//
//   MicCapture — lives in the sticky HubWeb.MicLive (root layout). Owns the
//                MediaRecorder, audio-chunk forwarding, recording-phase VU and
//                the silence watchdog. Because its DOM element sits in a sticky
//                nested LiveView, it is NOT destroyed on live navigation — the
//                mic keeps recording while the user browses other pages.
//
// Setup → Capture handoff carries just the device_id (string) + session_id +
// source ("mic" | "system"); MicCapture re-opens the device (permission is
// already granted).

const VOICE_DB_THRESHOLD = -40; // dBFS above which we count "voice"
const LEVEL_PUSH_HZ = 5; // VU push rate (setup + recording)
const SILENCE_LIMIT_MS = 5 * 60 * 1000; // 5 min without voice → warn
const SILENCE_COOLDOWN_MS = 60 * 1000; // re-warn no sooner than 1 min
const DEVICE_KEY = "lore.mic.device_id";

// Issue #400: VAD-Parameter für den Auto-Listen-Phrasen-Clip im Setup.
const CLIP_MIN_SPEECH_MS = 350; // <so wenig Sprache → Klick/Husten, Clip verwerfen
const CLIP_TRAILING_SILENCE_MS = 1200; // Stille nach Sprache → Äußerung zu Ende
const CLIP_MAX_MS = 8000; // harte Obergrenze pro Clip

const MIC_CONSTRAINTS = {
  echoCancellation: false,
  noiseSuppression: false,
  autoGainControl: false,
  channelCount: 1,
  sampleRate: 16000,
};

// ─── MicSetup (CampaignLive) ──────────────────────────────────────────
//
// Server pushes:
//   mic:setup_start        {session_id, source}  → enumerate + maybe self-open preferred
//   mic:setup_select       {device_id}           → open stream on that device
//   mic:setup_listen_again {}                     → re-arm listening (phrase miss/timeout)
//   mic:setup_abort        {}                     → drop the setup stream
//   mic:setup_release      {}                     → setup done, drop the temp stream
//                                                   (MicLive re-opens for recording)
// We push:
//   mic_setup_devices_ready {devices, preferred_id}
//   mic_setup_local_level   {level}              (5 Hz, modal VU)
//   mic_setup_phrase_clip   {chunk, device_id}   (a spoken-phrase clip, base64)
//   mic_error               {reason}
export const MicSetup = {
  mounted() {
    this.state = "IDLE";
    this.stream = null;
    this.currentDeviceId = null;
    this.audioCtx = null;
    this.analyser = null;
    this.analyserBuf = null;
    this.rafId = null;
    this.lastRafTs = 0;
    this.levelTimer = null;
    // Issue #400: phrase-clip VAD state.
    this.clipPhase = "WAIT_SPEECH"; // WAIT_SPEECH | RECORDING | WAITING_RESULT
    this.clipRecorder = null;
    this.clipChunks = [];
    this.clipMime = null;
    this.sendClip = false;
    this.speechMs = 0;
    this.silenceMs = 0;
    this.clipMs = 0;

    this.handleEvent("mic:setup_start", ({ session_id, source }) =>
      this.setupStart(session_id, source || "mic")
    );
    this.handleEvent("mic:setup_select", ({ device_id }) =>
      this.setupSelectDevice(device_id)
    );
    this.handleEvent("mic:setup_listen_again", () => this.rearmListen());
    this.handleEvent("mic:setup_abort", () => this.teardown());
    this.handleEvent("mic:setup_release", () => this.teardown());
  },

  destroyed() {
    this.teardown();
  },

  async setupStart(_sessionId, _source) {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      this.pushEvent("mic_error", { reason: "no_getusermedia" });
      return;
    }

    this.state = "SETUP_LISTING";

    // Permission pump: enumerateDevices only returns labels once mic permission
    // was granted at least once. Open a throwaway stream + release immediately.
    try {
      const pump = await navigator.mediaDevices.getUserMedia({ audio: true });
      pump.getTracks().forEach((t) => t.stop());
    } catch (err) {
      console.error("MicSetup: permission denied", err);
      this.pushEvent("mic_error", { reason: "permission_denied" });
      this.state = "IDLE";
      return;
    }

    let devices = [];
    try {
      const all = await navigator.mediaDevices.enumerateDevices();
      devices = all
        .filter((d) => d.kind === "audioinput")
        .map((d) => ({ deviceId: d.deviceId, label: d.label || "Mikrofon" }));
    } catch (err) {
      console.error("MicSetup: enumerateDevices failed", err);
    }

    let preferredId = null;
    try {
      const saved = window.localStorage.getItem(DEVICE_KEY);
      if (saved && devices.some((d) => d.deviceId === saved)) preferredId = saved;
    } catch (_) {
      // localStorage unavailable (private mode) — ignore.
    }

    this.pushEvent("mic_setup_devices_ready", {
      devices,
      preferred_id: preferredId,
    });
    this.state = "SETUP_AWAITING_USER";

    // Happy-path reload: a preferred device is known. <option selected> fires no
    // change event, so the server never pushes mic:setup_select — open here.
    if (preferredId) this.openStreamAndListen(preferredId);
  },

  setupSelectDevice(deviceId) {
    if (!deviceId) return;
    if (deviceId === this.currentDeviceId && this.stream) return;
    this.abortClip();
    if (this.rafId) {
      window.cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.releaseStream();
    this.openStreamAndListen(deviceId);
  },

  // Drop an in-flight phrase clip without shipping it (device switch / abort).
  abortClip() {
    if (this.clipRecorder) {
      this.clipRecorder.onstop = null;
      this.clipRecorder.ondataavailable = null;
      try {
        if (this.clipRecorder.state !== "inactive") this.clipRecorder.stop();
      } catch (_) {}
      this.clipRecorder = null;
    }
    this.clipChunks = [];
    this.clipPhase = "WAIT_SPEECH";
    this.sendClip = false;
  },

  async openStreamAndListen(deviceId) {
    this.currentDeviceId = deviceId;
    try {
      window.localStorage.setItem(DEVICE_KEY, deviceId);
    } catch (_) {}

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { deviceId: { exact: deviceId }, ...MIC_CONSTRAINTS },
      });
    } catch (err) {
      console.error("MicSetup: getUserMedia failed for device", deviceId, err);
      this.currentDeviceId = null;
      this.pushEvent("mic_error", { reason: "device_gone" });
      return;
    }

    this.state = "SETUP_LISTENING";
    this.setupAnalyser(this.stream);
    this.startLevelLoop("mic_setup_local_level");
    this.runListenLoop();
  },

  // Issue #400: re-arm the auto-listen loop after a phrase miss/timeout
  // (server-pushed mic:setup_listen_again). No-op unless a stream is open.
  rearmListen() {
    if (this.state === "SETUP_LISTENING" && this.stream && this.analyser) {
      this.runListenLoop();
    }
  },

  // VAD-style auto-listen: no record button. Speech onset (level above the
  // voice threshold) starts a MediaRecorder clip; trailing silence — or the
  // hard CLIP_MAX_MS cap — ends it. A clip with too little actual speech
  // (a click/cough) is dropped and we silently re-arm; a real utterance is
  // base64-encoded and shipped as mic_setup_phrase_clip for ASR.
  runListenLoop() {
    if (this.rafId) window.cancelAnimationFrame(this.rafId);
    this.clipPhase = "WAIT_SPEECH";
    this.speechMs = 0;
    this.silenceMs = 0;
    this.clipMs = 0;
    this.lastRafTs = 0;

    const tick = (ts) => {
      if (this.state !== "SETUP_LISTENING" || !this.analyser) return;
      const dt = this.lastRafTs ? ts - this.lastRafTs : 0;
      this.lastRafTs = ts;

      const loud = this.currentDb() > VOICE_DB_THRESHOLD;

      if (this.clipPhase === "WAIT_SPEECH") {
        if (loud) {
          this.startClip();
          this.speechMs = dt;
          this.silenceMs = 0;
          this.clipMs = dt;
        }
      } else if (this.clipPhase === "RECORDING") {
        this.clipMs += dt;
        if (loud) {
          this.speechMs += dt;
          this.silenceMs = 0;
        } else {
          this.silenceMs += dt;
        }

        const trailingDone = this.silenceMs >= CLIP_TRAILING_SILENCE_MS;
        const capped = this.clipMs >= CLIP_MAX_MS;
        if (trailingDone || capped) {
          // Enough real speech → ship it; otherwise treat as click/cough and
          // re-arm without bothering the server.
          this.stopClip(this.speechMs >= CLIP_MIN_SPEECH_MS);
          return; // rAF stops; re-armed by finishClip (drop) or the server (sent)
        }
      }
      this.rafId = window.requestAnimationFrame(tick);
    };
    this.rafId = window.requestAnimationFrame(tick);
  },

  startClip() {
    const mime = pickMime();
    if (!mime) {
      this.pushEvent("mic_error", { reason: "no_codec" });
      return;
    }
    this.clipPhase = "RECORDING";
    this.clipChunks = [];
    this.clipMime = mime;
    this.sendClip = false;
    try {
      this.clipRecorder = new MediaRecorder(this.stream, { mimeType: mime });
    } catch (err) {
      console.error("MicSetup: MediaRecorder failed", err);
      this.pushEvent("mic_error", { reason: "recorder_error" });
      this.clipPhase = "WAIT_SPEECH";
      return;
    }
    this.clipRecorder.ondataavailable = (ev) => {
      if (ev.data && ev.data.size > 0) this.clipChunks.push(ev.data);
    };
    this.clipRecorder.onstop = () => this.finishClip();
    this.clipRecorder.start(); // single blob on stop()
  },

  stopClip(send) {
    this.sendClip = send;
    this.clipPhase = send ? "WAITING_RESULT" : "WAIT_SPEECH";
    if (this.clipRecorder && this.clipRecorder.state !== "inactive") {
      try {
        this.clipRecorder.stop(); // onstop → finishClip
        return;
      } catch (_) {}
    }
    this.finishClip();
  },

  async finishClip() {
    const chunks = this.clipChunks;
    const mime = this.clipMime;
    const send = this.sendClip;
    this.clipChunks = [];
    this.clipRecorder = null;

    if (!send || chunks.length === 0) {
      // Click/cough or empty capture → silently listen again.
      this.rearmListen();
      return;
    }

    const blob = new Blob(chunks, { type: mime || "audio/webm" });
    const b64 = await blobToBase64(blob);
    // Carry the open device so the LiveView always has it (even the
    // auto-opened preferred-device reload path, which fires no select).
    this.pushEvent("mic_setup_phrase_clip", {
      chunk: b64,
      device_id: this.currentDeviceId,
    });
  },

  setupAnalyser(stream) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    this.audioCtx = new Ctx();
    if (this.audioCtx.state === "suspended") this.audioCtx.resume().catch(() => {});
    const src = this.audioCtx.createMediaStreamSource(stream);
    this.analyser = this.audioCtx.createAnalyser();
    this.analyser.fftSize = 1024;
    this.analyser.smoothingTimeConstant = 0.3;
    this.analyserBuf = new Float32Array(this.analyser.fftSize);
    src.connect(this.analyser);
  },

  currentDb() {
    if (!this.analyser) return -100;
    this.analyser.getFloatTimeDomainData(this.analyserBuf);
    let peak = 0;
    for (let i = 0; i < this.analyserBuf.length; i++) {
      const a = Math.abs(this.analyserBuf[i]);
      if (a > peak) peak = a;
    }
    return 20 * Math.log10(peak || 1e-10);
  },

  currentLevel() {
    return Math.max(0, Math.min(1, (this.currentDb() + 60) / 60));
  },

  startLevelLoop(eventName) {
    this.stopLevelLoop();
    this.levelTimer = window.setInterval(() => {
      if (!this.analyser) return;
      this.pushEvent(eventName, { level: this.currentLevel() });
    }, Math.round(1000 / LEVEL_PUSH_HZ));
  },

  stopLevelLoop() {
    if (this.levelTimer) {
      window.clearInterval(this.levelTimer);
      this.levelTimer = null;
    }
  },

  teardown() {
    if (this.rafId) {
      window.cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.stopLevelLoop();
    // Drop any in-flight phrase clip without shipping it (detached onstop so
    // finishClip can't fire a stray push / re-arm during teardown).
    this.abortClip();
    if (this.analyser) {
      try {
        this.analyser.disconnect();
      } catch (_) {}
      this.analyser = null;
    }
    if (this.audioCtx) {
      try {
        this.audioCtx.close();
      } catch (_) {}
      this.audioCtx = null;
    }
    this.releaseStream();
    this.currentDeviceId = null;
    this.state = "IDLE";
  },

  releaseStream() {
    if (this.stream) {
      this.stream.getTracks().forEach((t) => t.stop());
      this.stream = null;
    }
  },
};

// ─── MicCapture (sticky MicLive) ──────────────────────────────────────
//
// Server pushes:
//   mic_capture:start {device_id, session_id, source}  → open + record
//   mic_capture:stop  {}                                → stop + release
//   mic_capture:silence_ack {}                          → reset watchdog
// We push:
//   audio_chunk         {session_id, chunk}   (every ~500 ms)
//   mic_level           {level}               (5 Hz, pill VU)
//   mic_silence_warning {minutes}             (after 5 min silence)
//   mic_capture_started {session_id}
//   mic_capture_error   {reason}
export const MicCapture = {
  mounted() {
    this.state = "IDLE";
    this.recorder = null;
    this.stream = null;
    this.sessionId = null;
    this.audioCtx = null;
    this.analyser = null;
    this.analyserBuf = null;
    this.levelTimer = null;
    this.silenceTimer = null;
    this.lastVoiceAt = 0;

    this.handleEvent("mic_capture:start", ({ device_id, session_id, source }) =>
      this.startCapture(device_id, session_id, source || "mic")
    );
    this.handleEvent("mic_capture:stop", () => this.stop());
    this.handleEvent("mic_capture:silence_ack", () => {
      this.lastVoiceAt = nowMs();
    });
  },

  destroyed() {
    // Only fires on full LiveSocket teardown (tab close) — survives live nav.
    this.teardown();
  },

  async startCapture(deviceId, sessionId, source) {
    if (this.recorder) this.teardown(); // switching campaigns: stop the old one

    this.sessionId = sessionId;

    try {
      if (source === "system") {
        this.stream = await navigator.mediaDevices.getDisplayMedia({
          audio: true,
          video: false,
        });
        const tracks = this.stream.getAudioTracks();
        if (tracks.length === 0) {
          this.releaseStream();
          this.pushEvent("mic_capture_error", { reason: "no_system_audio" });
          return;
        }
        this.stream.getVideoTracks().forEach((t) => {
          t.stop();
          this.stream.removeTrack(t);
        });
      } else {
        const audio = deviceId
          ? { deviceId: { exact: deviceId }, ...MIC_CONSTRAINTS }
          : MIC_CONSTRAINTS;
        this.stream = await navigator.mediaDevices.getUserMedia({ audio });
      }
    } catch (err) {
      console.error("MicCapture: getUserMedia/Display failed", err);
      this.pushEvent("mic_capture_error", {
        reason: source === "system" ? "system_audio_denied" : "device_gone",
      });
      return;
    }

    this.beginRecordingPhase();
  },

  beginRecordingPhase() {
    const mime = pickMime();
    if (!mime) {
      this.pushEvent("mic_capture_error", { reason: "no_codec" });
      this.teardown();
      return;
    }

    this.state = "RECORDING";
    this.setupAnalyser(this.stream);
    this.startLevelLoop("mic_level");
    this.lastVoiceAt = nowMs();
    this.startSilenceWatchdog();

    this.stream.getAudioTracks().forEach((t) => {
      t.onended = () => this.pushEvent("mic_capture_error", { reason: "track_ended" });
    });

    this.recorder = new MediaRecorder(this.stream, { mimeType: mime });
    this.recorder.ondataavailable = async (ev) => {
      if (!ev.data || ev.data.size === 0) return;
      const b64 = await blobToBase64(ev.data);
      this.pushEvent("audio_chunk", { session_id: this.sessionId, chunk: b64 });
    };
    this.recorder.onerror = (ev) => {
      this.pushEvent("mic_capture_error", {
        reason: "recorder_error:" + (ev.error && ev.error.name),
      });
    };
    this.recorder.onstop = () => this.teardown();

    this.recorder.start(500);
    this.pushEvent("mic_capture_started", { session_id: this.sessionId });
  },

  setupAnalyser(stream) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    this.audioCtx = new Ctx();
    if (this.audioCtx.state === "suspended") this.audioCtx.resume().catch(() => {});
    const src = this.audioCtx.createMediaStreamSource(stream);
    this.analyser = this.audioCtx.createAnalyser();
    this.analyser.fftSize = 1024;
    this.analyser.smoothingTimeConstant = 0.3;
    this.analyserBuf = new Float32Array(this.analyser.fftSize);
    src.connect(this.analyser);
  },

  currentDb() {
    if (!this.analyser) return -100;
    this.analyser.getFloatTimeDomainData(this.analyserBuf);
    let peak = 0;
    for (let i = 0; i < this.analyserBuf.length; i++) {
      const a = Math.abs(this.analyserBuf[i]);
      if (a > peak) peak = a;
    }
    return 20 * Math.log10(peak || 1e-10);
  },

  currentLevel() {
    return Math.max(0, Math.min(1, (this.currentDb() + 60) / 60));
  },

  startLevelLoop(eventName) {
    this.stopLevelLoop();
    this.levelTimer = window.setInterval(() => {
      if (!this.analyser) return;
      const db = this.currentDb();
      if (db > VOICE_DB_THRESHOLD) this.lastVoiceAt = nowMs();
      this.pushEvent(eventName, { level: this.currentLevel() });
    }, Math.round(1000 / LEVEL_PUSH_HZ));
  },

  stopLevelLoop() {
    if (this.levelTimer) {
      window.clearInterval(this.levelTimer);
      this.levelTimer = null;
    }
  },

  startSilenceWatchdog() {
    this.stopSilenceWatchdog();
    this.silenceTimer = window.setInterval(() => {
      if (nowMs() - this.lastVoiceAt >= SILENCE_LIMIT_MS) {
        this.pushEvent("mic_silence_warning", { minutes: 5 });
        this.lastVoiceAt = nowMs() - SILENCE_LIMIT_MS + SILENCE_COOLDOWN_MS;
      }
    }, 5000);
  },

  stopSilenceWatchdog() {
    if (this.silenceTimer) {
      window.clearInterval(this.silenceTimer);
      this.silenceTimer = null;
    }
  },

  stop() {
    if (this.recorder) {
      try {
        this.recorder.stop(); // onstop → teardown
        return;
      } catch (_) {}
    }
    this.teardown();
  },

  teardown() {
    this.stopLevelLoop();
    this.stopSilenceWatchdog();
    if (this.analyser) {
      try {
        this.analyser.disconnect();
      } catch (_) {}
      this.analyser = null;
    }
    if (this.audioCtx) {
      try {
        this.audioCtx.close();
      } catch (_) {}
      this.audioCtx = null;
    }
    this.releaseStream();
    this.recorder = null;
    this.sessionId = null;
    this.state = "IDLE";
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
      const idx = r.result.indexOf(",");
      resolve(idx >= 0 ? r.result.slice(idx + 1) : r.result);
    };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
}

function nowMs() {
  return Date.now();
}
