// Browser-mic hooks for LoreTracker.
//
// Issue #405 split the old single RecordMic hook into two, so the live
// recording capture can survive page navigation:
//
//   MicSetup   — lives in CampaignLive. Device-enumeration + voice-test +
//                setup-modal VU. NO MediaRecorder. Reports the chosen device
//                and "voice detected"; then the LiveView hands off to MicLive.
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
const VOICE_SUSTAIN_MS = 200; // sustained voice before auto-advance (setup)
const LEVEL_PUSH_HZ = 5; // VU push rate (setup + recording)
const SILENCE_LIMIT_MS = 5 * 60 * 1000; // 5 min without voice → warn
const SILENCE_COOLDOWN_MS = 60 * 1000; // re-warn no sooner than 1 min
const DEVICE_KEY = "lore.mic.device_id";

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
//   mic:setup_start  {session_id, source}  → enumerate + maybe self-open preferred
//   mic:setup_select {device_id}           → open stream on that device
//   mic:setup_abort  {}                     → drop the setup stream
//   mic:setup_release {}                    → setup done, drop the temp stream
//                                             (MicLive re-opens for recording)
// We push:
//   mic_setup_devices_ready {devices, preferred_id}
//   mic_setup_local_level   {level}              (5 Hz, modal VU)
//   mic_setup_voice_ok      {device_id}          (−40 dB / 200 ms sustained)
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
    this.voiceMs = 0;
    this.lastRafTs = 0;
    this.voiceDetected = false;
    this.levelTimer = null;

    this.handleEvent("mic:setup_start", ({ session_id, source }) =>
      this.setupStart(session_id, source || "mic")
    );
    this.handleEvent("mic:setup_select", ({ device_id }) =>
      this.setupSelectDevice(device_id)
    );
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
    this.voiceDetected = false;

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
    this.releaseStream();
    this.openStreamAndListen(deviceId);
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
    this.voiceMs = 0;
    this.voiceDetected = false;
    this.setupAnalyser(this.stream);
    this.startLevelLoop("mic_setup_local_level");
    this.lastRafTs = 0;
    this.runVoiceLoop();
  },

  runVoiceLoop() {
    const tick = (ts) => {
      if (this.state !== "SETUP_LISTENING" || !this.analyser) return;
      const dt = this.lastRafTs ? ts - this.lastRafTs : 0;
      this.lastRafTs = ts;

      const db = this.currentDb();
      if (db > VOICE_DB_THRESHOLD) this.voiceMs += dt;
      else this.voiceMs = 0;

      if (!this.voiceDetected && this.voiceMs >= VOICE_SUSTAIN_MS) {
        this.voiceDetected = true;
        // Carry the open device so the LiveView always has it (even the
        // auto-opened preferred-device reload path, which fires no select).
        this.pushEvent("mic_setup_voice_ok", { device_id: this.currentDeviceId });
        return;
      }
      this.rafId = window.requestAnimationFrame(tick);
    };
    this.rafId = window.requestAnimationFrame(tick);
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
    this.voiceDetected = false;
    this.voiceMs = 0;
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
