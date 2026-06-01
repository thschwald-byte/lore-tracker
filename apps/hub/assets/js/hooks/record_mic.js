// Browser-mic capture hook for LoreTracker (M10-BMP + Issue #391 Setup-Flow).
//
// Attached via `phx-hook="RecordMic"` on a wrapper div in CampaignLive.
//
// Two entry paths:
//
//   A) Per-Spieler-Mikro (source="mic") — Issue #391 Setup-Flow:
//      server pushes "mic:setup_start" → we run the device-enumeration +
//      voice-test phase, the server renders the setup modal. Sequence:
//        mic:setup_start  {session_id, source}  → enumerate + maybe self-open preferred
//        (we push)  mic_setup_devices_ready {devices, preferred_id}
//        mic:setup_select {device_id}           → open stream on that device
//        (we push)  mic_setup_local_level {level}   (5 Hz, modal VU)
//        (we push)  mic_setup_voice_ok {}           (−40 dB / 200 ms sustained)
//        mic:start_recording {session_id}       → MediaRecorder on the open stream
//        mic:setup_abort {}                     → drop the setup stream
//
//   B) Listen-Modus (source="system") — legacy direct path:
//        mic:start {session_id, source:"system"} → getDisplayMedia + record
//
// During recording we push:
//   pushEvent("audio_chunk", {session_id, chunk:<base64>})   (every ~500 ms)
//   pushEvent("mic_level", {level})                          (5 Hz, pill VU)
//   pushEvent("mic_silence_warning", {minutes})              (after 5 min silence)
//   pushEvent("mic_error", {reason})                         (any failure)
//
// The LiveView forwards audio via Hub.Commands.forward_audio_chunk/4.

const VOICE_DB_THRESHOLD = -40; // dBFS above which we count "voice"
const VOICE_SUSTAIN_MS = 200; // how long sustained before auto-advance
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

export const RecordMic = {
  mounted() {
    this.state = "IDLE";
    this.recorder = null;
    this.stream = null;
    this.sessionId = null;
    this.pendingSource = null;
    this.currentDeviceId = null;

    // AnalyserNode / AudioContext for both the setup voice-test and the
    // recording-phase VU + silence watchdog.
    this.audioCtx = null;
    this.analyser = null;
    this.analyserBuf = null;
    this.rafId = null;

    // Voice-detection accumulator (setup phase).
    this.voiceMs = 0;
    this.lastRafTs = 0;
    this.voiceDetected = false;

    // Intervals.
    this.levelTimer = null;
    this.silenceTimer = null;
    this.lastVoiceAt = 0;

    // Setup-flow events.
    this.handleEvent("mic:setup_start", ({ session_id, source }) =>
      this.setupStart(session_id, source || "mic")
    );
    this.handleEvent("mic:setup_select", ({ device_id }) =>
      this.setupSelectDevice(device_id)
    );
    this.handleEvent("mic:setup_abort", () => this.setupAbort());
    this.handleEvent("mic:start_recording", ({ session_id }) =>
      this.startRecording(session_id)
    );
    this.handleEvent("mic:silence_ack", () => this.silenceAck());

    // Legacy / system-audio path.
    this.handleEvent("mic:start", ({ session_id, source }) =>
      this.startSystem(session_id, source || "system")
    );
    this.handleEvent("mic:stop", () => this.stop());
  },

  destroyed() {
    this.teardown();
  },

  // ─── Setup phase ────────────────────────────────────────────────

  async setupStart(sessionId, source) {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      this.pushEvent("mic_error", { reason: "no_getusermedia" });
      return;
    }

    this.state = "SETUP_LISTING";
    this.sessionId = sessionId;
    this.pendingSource = source;
    this.voiceDetected = false;

    // Permission pump: enumerateDevices only returns device labels once the
    // user has granted mic permission at least once. Open a throwaway stream
    // and immediately release it.
    try {
      const pump = await navigator.mediaDevices.getUserMedia({ audio: true });
      pump.getTracks().forEach((t) => t.stop());
    } catch (err) {
      console.error("RecordMic: permission denied during setup", err);
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
      console.error("RecordMic: enumerateDevices failed", err);
    }

    let preferredId = null;
    try {
      const saved = window.localStorage.getItem(DEVICE_KEY);
      if (saved && devices.some((d) => d.deviceId === saved)) {
        preferredId = saved;
      }
    } catch (_) {
      // localStorage may be unavailable (private mode) — ignore.
    }

    this.pushEvent("mic_setup_devices_ready", {
      devices,
      preferred_id: preferredId,
    });
    this.state = "SETUP_AWAITING_USER";

    // Happy-path reload: a preferred device is known. An HTML `<option selected>`
    // fires no change event, so the server would never push mic:setup_select —
    // open the stream ourselves so the user can just speak.
    if (preferredId) {
      this.openStreamAndListen(preferredId);
    }
  },

  setupSelectDevice(deviceId) {
    if (!deviceId) return;
    if (deviceId === this.currentDeviceId && this.stream) return; // already open
    this.releaseStream();
    this.openStreamAndListen(deviceId);
  },

  async openStreamAndListen(deviceId) {
    this.currentDeviceId = deviceId;
    try {
      window.localStorage.setItem(DEVICE_KEY, deviceId);
    } catch (_) {
      // ignore
    }

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { deviceId: { exact: deviceId }, ...MIC_CONSTRAINTS },
      });
    } catch (err) {
      console.error("RecordMic: getUserMedia failed for device", deviceId, err);
      this.currentDeviceId = null;
      this.pushEvent("mic_error", { reason: "device_gone" });
      return;
    }

    this.state = "SETUP_LISTENING";
    this.voiceMs = 0;
    this.voiceDetected = false;
    this.setupAnalyser(this.stream);

    // VU pushes for the modal bar (local only — no PubSub fan-out).
    this.startLevelLoop("mic_setup_local_level");

    // Voice-detection loop runs off the same analyser via rAF.
    this.lastRafTs = 0;
    this.runVoiceLoop();
  },

  runVoiceLoop() {
    const tick = (ts) => {
      if (this.state !== "SETUP_LISTENING" || !this.analyser) return;

      const dt = this.lastRafTs ? ts - this.lastRafTs : 0;
      this.lastRafTs = ts;

      const db = this.currentDb();
      if (db > VOICE_DB_THRESHOLD) {
        this.voiceMs += dt;
      } else {
        this.voiceMs = 0;
      }

      if (!this.voiceDetected && this.voiceMs >= VOICE_SUSTAIN_MS) {
        this.voiceDetected = true;
        this.pushEvent("mic_setup_voice_ok", {});
        // Keep the stream + analyser open; the modal may stay open if consent
        // is still missing. Local VU keeps pushing. Stop only the voice loop.
        return;
      }

      this.rafId = window.requestAnimationFrame(tick);
    };
    this.rafId = window.requestAnimationFrame(tick);
  },

  setupAbort() {
    this.teardown();
    this.state = "IDLE";
  },

  // ─── Recording phase ────────────────────────────────────────────

  // Per-Spieler path: stream + analyser are already open from the setup phase.
  startRecording(sessionId) {
    if (!this.stream) {
      this.pushEvent("mic_error", { reason: "no_stream" });
      return;
    }
    this.sessionId = sessionId;
    this.beginRecordingPhase();
  },

  // System-audio path: acquire the display-media stream, then share the
  // common recording-phase setup (analyser + VU + watchdog).
  async startSystem(sessionId, source) {
    if (this.recorder) {
      console.warn("RecordMic: already running, ignoring start");
      return;
    }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
      this.pushEvent("mic_error", { reason: "no_getdisplaymedia" });
      return;
    }

    try {
      this.stream = await navigator.mediaDevices.getDisplayMedia({
        audio: true,
        video: false,
      });
    } catch (err) {
      console.error("RecordMic: getDisplayMedia denied", err);
      this.pushEvent("mic_error", { reason: "system_audio_denied" });
      return;
    }

    const audioTracks = this.stream.getAudioTracks();
    if (audioTracks.length === 0) {
      console.warn("RecordMic: getDisplayMedia returned no audio tracks");
      this.releaseStream();
      this.pushEvent("mic_error", { reason: "no_system_audio" });
      return;
    }

    // Drop incidental video tracks so MediaRecorder doesn't encode video.
    this.stream.getVideoTracks().forEach((t) => {
      t.stop();
      this.stream.removeTrack(t);
    });

    this.sessionId = sessionId;
    this.pendingSource = source;
    this.setupAnalyser(this.stream);
    this.beginRecordingPhase();
  },

  beginRecordingPhase() {
    const mime = pickMime();
    if (!mime) {
      this.pushEvent("mic_error", { reason: "no_codec" });
      this.teardown();
      return;
    }

    this.state = "RECORDING";

    // Switch the analyser VU from the local-modal channel to the broadcast one.
    this.stopLevelLoop();
    this.startLevelLoop("mic_level");

    // Silence watchdog.
    this.lastVoiceAt = nowMs();
    this.startSilenceWatchdog();

    // Ungraceful device-loss (USB pulled mid-recording).
    this.stream.getAudioTracks().forEach((t) => {
      t.onended = () => this.pushEvent("mic_error", { reason: "track_ended" });
    });

    this.recorder = new MediaRecorder(this.stream, { mimeType: mime });

    this.recorder.ondataavailable = async (ev) => {
      if (!ev.data || ev.data.size === 0) return;
      const b64 = await blobToBase64(ev.data);
      this.pushEvent("audio_chunk", { session_id: this.sessionId, chunk: b64 });
    };

    this.recorder.onerror = (ev) => {
      this.pushEvent("mic_error", {
        reason: "recorder_error:" + (ev.error && ev.error.name),
      });
    };

    this.recorder.onstop = () => {
      this.teardown();
    };

    this.recorder.start(500);
    this.pushEvent("mic_started", { session_id: this.sessionId });
  },

  // ─── Audio analysis ─────────────────────────────────────────────

  setupAnalyser(stream) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    this.audioCtx = new Ctx();
    if (this.audioCtx.state === "suspended") {
      this.audioCtx.resume().catch(() => {});
    }
    const src = this.audioCtx.createMediaStreamSource(stream);
    this.analyser = this.audioCtx.createAnalyser();
    this.analyser.fftSize = 1024;
    this.analyser.smoothingTimeConstant = 0.3;
    this.analyserBuf = new Float32Array(this.analyser.fftSize);
    src.connect(this.analyser);
  },

  // Peak amplitude → dBFS. Returns a large negative for silence.
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

  // dBFS [-60, 0] → level [0, 1].
  currentLevel() {
    const db = this.currentDb();
    return Math.max(0, Math.min(1, (db + 60) / 60));
  },

  startLevelLoop(eventName) {
    this.stopLevelLoop();
    this.levelTimer = window.setInterval(() => {
      if (!this.analyser) return;
      const db = this.currentDb();
      // Recording phase feeds the silence watchdog from the same sampling.
      if (eventName === "mic_level" && db > VOICE_DB_THRESHOLD) {
        this.lastVoiceAt = nowMs();
      }
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
        // Cooldown: push lastVoiceAt forward so we don't re-fire every tick
        // even if the user never acks (e.g. tab in background).
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

  silenceAck() {
    this.lastVoiceAt = nowMs();
  },

  // ─── Teardown ───────────────────────────────────────────────────

  stop() {
    if (this.recorder) {
      try {
        this.recorder.stop(); // onstop → teardown
        return;
      } catch (_) {
        // fall through to hard teardown
      }
    }
    this.teardown();
  },

  teardown() {
    if (this.rafId) {
      window.cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
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
    this.pendingSource = null;
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

function nowMs() {
  return Date.now();
}
