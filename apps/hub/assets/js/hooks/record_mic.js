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
// Issue #398: ein „Verstanden" am Stille-Modal wird pro Recording-Session in
// localStorage persistiert, damit ein Reload (Browser-Neustart, Tab-Discard)
// den bewussten Dismiss nicht vergisst und das Modal nicht alle 5 min neu kommt.
const SILENCE_ACK_PREFIX = "lore:mic-silence-ack:";
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
    // Issue #412: setup passed → hand the LIVE stream to MicCapture instead of
    // dropping it (no second getUserMedia, which mobile rejects for the same
    // device) and instead of broadcasting per-user (which would trigger every
    // other device of this user).
    this.handleEvent("mic:setup_handoff", (detail) => this.handoff(detail || {}));

    // Issue #415: mirror this browser's recording state into CampaignLive so the
    // three-way button (stop / take-over / join) is correct. The state lives in
    // the MicCapture hook (sticky MicLive); it reaches us browser-locally via a
    // window event. Request the current state now so a freshly (re-)mounted
    // CampaignLive syncs after live navigation.
    this._onMicState = (ev) =>
      this.pushEvent("mic_local_state", { recording: !!(ev.detail && ev.detail.recording) });
    window.addEventListener("lore:mic-state", this._onMicState);
    window.dispatchEvent(new CustomEvent("lore:mic-state-request"));
  },

  destroyed() {
    if (this._onMicState) window.removeEventListener("lore:mic-state", this._onMicState);
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

    // Issue #412: auto-open the saved preferred device, else the FIRST
    // available one. The <select> only fires phx-change on a real change —
    // on mobile (Android Chrome) there's typically a single "default" input
    // that's already the select value, so a change event never fires and the
    // listen loop never starts ("phone doesn't hear"). The #400 design is
    // button-less auto-listen anyway, so opening the default device up front
    // is the intended UX on every platform (the dropdown still lets you
    // switch). Report the auto-opened id back as preferred_id so the modal
    // marks it selected.
    const autoId = preferredId || (devices[0] && devices[0].deviceId) || null;

    this.pushEvent("mic_setup_devices_ready", {
      devices,
      preferred_id: autoId,
    });
    this.state = "SETUP_AWAITING_USER";

    if (autoId !== null) this.openStreamAndListen(autoId);
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
    this.currentDeviceId = deviceId || null;
    try {
      if (deviceId) window.localStorage.setItem(DEVICE_KEY, deviceId);
    } catch (_) {}

    // Issue #412: a falsy/empty deviceId (mobile "default" before labels are
    // exposed) would make { exact: "" } throw OverconstrainedError — open the
    // default device without the exact-id constraint in that case.
    const audio = deviceId
      ? { deviceId: { exact: deviceId }, ...MIC_CONSTRAINTS }
      : MIC_CONSTRAINTS;

    // Issue #396: bei einer Übernahme aus einem anderen Tab gibt der alte Tab das
    // Mikro erst async frei (CampaignLive supersedet ihn beim mic_join). Bis dahin
    // wirft getUserMedia auf PipeWire/Firefox NotReadableError ("device in use").
    // Kurz retrien, damit das Setup das frisch freigegebene Device greift, statt
    // sofort mit device_gone aufzugeben.
    let lastErr = null;
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        this.stream = await navigator.mediaDevices.getUserMedia({ audio });
        lastErr = null;
        break;
      } catch (err) {
        lastErr = err;
        const transient =
          err && (err.name === "NotReadableError" || err.name === "AbortError");
        if (!transient || attempt === 4) break;
        await sleep(300);
      }
    }
    if (lastErr) {
      console.error("MicSetup: getUserMedia failed for device", deviceId, lastErr);
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

  // Issue #412: setup passed — hand the open device over to MicCapture in the
  // SAME browser via a window stash + CustomEvent. We tear down the listening
  // apparatus (analyser/AudioContext/loops) but DO NOT stop the stream tracks,
  // so MicCapture can keep recording on them without a second getUserMedia.
  handoff({ campaign_id, session_id, source }) {
    const stream = this.stream;
    const deviceId = this.currentDeviceId;

    if (this.rafId) {
      window.cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    this.stopLevelLoop();
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
    // Release our ownership WITHOUT stopping the tracks — they go to MicCapture.
    this.stream = null;
    this.currentDeviceId = null;
    this.state = "IDLE";

    const detail = {
      campaignId: campaign_id,
      sessionId: session_id,
      source: source || "mic",
      deviceId,
    };

    if (stream) {
      window.__loreMicHandoff = { stream, deviceId };
      window.dispatchEvent(new CustomEvent("lore:mic-handoff", { detail }));
      // Leak guard: if MicCapture never claims it (unmounted / error), stop the
      // orphaned stream so the mic doesn't stay hot.
      window.setTimeout(() => {
        const h = window.__loreMicHandoff;
        if (h && h.stream === stream) {
          stream.getTracks().forEach((t) => t.stop());
          window.__loreMicHandoff = null;
        }
      }, 4000);
    } else {
      // No live setup stream (shouldn't happen) — let MicCapture open fresh.
      window.dispatchEvent(new CustomEvent("lore:mic-handoff", { detail }));
    }
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
    this.campaignId = null;
    this.captureSource = null;
    this.audioCtx = null;
    this.analyser = null;
    this.analyserBuf = null;
    this.levelTimer = null;
    this.silenceTimer = null;
    this.lastVoiceAt = 0;
    // Issue #398: für die laufende Session bewusst weg-geklickt? Unterdrückt
    // weitere Stille-Warnungen bis Session-Ende/Stop; aus localStorage restauriert.
    this.silenceAcked = false;
    // Issue #397: gemerkte deviceId + Resume-Guard für transparentes Wieder-
    // aufnehmen, wenn dasselbe Mikro mid-Recording ab- und wieder angesteckt wird.
    this.deviceId = null;
    this.resuming = false;

    this.handleEvent("mic_capture:start", ({ device_id, session_id, source }) =>
      this.startCapture(device_id, session_id, source || "mic")
    );
    // Echter Stop / SessionEnded (MicLive pusht mic_capture:stop) → Dismiss
    // zurücksetzen. Ein Reload läuft NICHT hierdurch (nur destroyed→teardown),
    // daher überlebt der Dismiss den Reload.
    this.handleEvent("mic_capture:stop", () => {
      clearSilenceAck(this.sessionId);
      this.silenceAcked = false;
      this.stop();
    });
    this.handleEvent("mic_capture:silence_ack", () => {
      this.lastVoiceAt = nowMs();
      this.silenceAcked = true;
      writeSilenceAck(this.sessionId);
    });

    // Issue #412: browser-local handoff from the MicSetup hook (same browser,
    // different sticky LiveView). Carries the LIVE setup stream so we record on
    // it directly — no second getUserMedia. Per-user PubSub is NOT used for the
    // mic path anymore, so other devices of the same user are never triggered.
    this._onHandoff = (ev) => this.startFromHandoff(ev.detail || {});
    window.addEventListener("lore:mic-handoff", this._onHandoff);

    // Issue #415: CampaignLive (MicSetup-Hook) fragt beim Mount den aktuellen
    // Recording-Zustand DIESES Browsers ab — wir antworten browser-lokal, damit
    // der Drei-Wege-Button (stop / übernehmen / beitreten) auch nach Live-Nav
    // stimmt.
    this._onStateReq = () => this.emitLocalState(this.state === "RECORDING");
    window.addEventListener("lore:mic-state-request", this._onStateReq);
  },

  destroyed() {
    // Only fires on full LiveSocket teardown (tab close) — survives live nav.
    if (this._onHandoff) window.removeEventListener("lore:mic-handoff", this._onHandoff);
    if (this._onStateReq) window.removeEventListener("lore:mic-state-request", this._onStateReq);
    this.teardown();
  },

  // Issue #415: browser-lokales Recording-State-Signal an den MicSetup-Hook
  // (lebt in CampaignLive, gleicher Browser). Per-User-PubSub kann zwei Geräte
  // desselben Users nicht unterscheiden — dieses window-Event schon.
  emitLocalState(recording) {
    window.dispatchEvent(new CustomEvent("lore:mic-state", { detail: { recording } }));
  },

  // Issue #412: start recording on the stream handed over by MicSetup. Falls
  // back to opening the device ourselves if the handoff stream is missing
  // (defensive — keeps the previous behaviour as a safety net).
  async startFromHandoff({ campaignId, sessionId, source, deviceId }) {
    if (this.recorder) this.teardown();
    this.campaignId = campaignId || null;
    this.sessionId = sessionId;
    this.captureSource = source || "mic";
    this.deviceId = deviceId || null; // Issue #397: für Auto-Resume nach Re-Plug

    let stream = null;
    const h = window.__loreMicHandoff;
    if (h && h.stream && h.stream.getAudioTracks().some((t) => t.readyState === "live")) {
      stream = h.stream;
      window.__loreMicHandoff = null; // claim it
    }

    if (!stream) {
      try {
        stream = await this.openMicWithRetry(deviceId);
      } catch (err) {
        console.error("MicCapture: handoff fallback getUserMedia failed", deviceId, err);
        this.pushEvent("mic_capture_error", { reason: "device_gone" });
        return;
      }
    }

    this.stream = stream;
    this.beginRecordingPhase();
  },

  async startCapture(deviceId, sessionId, source) {
    if (this.recorder) this.teardown(); // switching campaigns: stop the old one

    this.sessionId = sessionId;
    this.captureSource = source;
    this.deviceId = deviceId; // Issue #397: für Auto-Resume nach Re-Plug
    // System/listen path: MicLive already set its recording state from the
    // server {:start_capture}, so don't re-set it from mic_capture_started.
    this.campaignId = null;

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
        this.stream = await this.openMicWithRetry(deviceId);
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

  // Issue #412: Setup→Capture-Handoff-Race. Der MicSetup-Hook (CampaignLive)
  // gibt seinen Setup-Stream via mic:setup_release frei, während wir dasselbe
  // Gerät hier neu öffnen — die beiden Hooks leben in getrennten LiveViews,
  // ohne garantierte Reihenfolge. Hält der Setup-Stream das Device noch, wirft
  // getUserMedia auf Firefox/PipeWire NotReadableError ("device in use").
  // Transiente Busy-Fehler also kurz zurücksetzen lassen + retrien; harte
  // Fehler (permission, exact-deviceId existiert nicht) sofort durchreichen.
  async openMicWithRetry(deviceId) {
    const audio = deviceId
      ? { deviceId: { exact: deviceId }, ...MIC_CONSTRAINTS }
      : MIC_CONSTRAINTS;
    let lastErr;
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        return await navigator.mediaDevices.getUserMedia({ audio });
      } catch (err) {
        lastErr = err;
        const transient =
          err && (err.name === "NotReadableError" || err.name === "AbortError");
        if (!transient || attempt === 3) throw err;
        await sleep(200);
      }
    }
    throw lastErr;
  },

  // ── Issue #397: Auto-Resume nach Device-Pull + Re-Plug ──────────────────
  // Endet der Mic-Track mid-Recording (USB-Mikro abgezogen, Kabel-Wackler),
  // versuchen wir dasselbe Device transparent neu zu öffnen und die Aufnahme
  // fortzusetzen — statt den Setup-Flow neu zu erzwingen.
  handleTrackEnded() {
    // System-Audio (Screen-Share) endet absichtlich → kein Resume, regulärer
    // Fehler. Ebenso wenn wir gar nicht (mehr) aufnehmen.
    if (this.captureSource === "system" || this.state !== "RECORDING") {
      this.pushEvent("mic_capture_error", { reason: "track_ended" });
      return;
    }

    this.attemptResume();
  },

  async attemptResume() {
    if (this.resuming) return;
    this.resuming = true;

    // Audio-Pipeline abbauen, aber Session-Kontext (sessionId/campaignId/source/
    // deviceId/silenceAcked) behalten — KEIN teardown.
    this.suspendPipeline();

    try {
      const stream = await this.reopenForResume(this.deviceId);

      // Zwischenzeitlich gestoppt (mic_capture:stop) → neuen Stream wieder freigeben.
      if (this.state === "IDLE") {
        stream.getTracks().forEach((t) => t.stop());
        this.resuming = false;
        return;
      }

      this.stream = stream;
      this.resuming = false;
      // baut Recorder/Analyser/Level-Loop neu auf + re-attached onended → ein
      // erneuter Pull wird wieder aufgefangen.
      this.beginRecordingPhase();
    } catch (err) {
      this.resuming = false;
      // Stop während des Resume-Fensters → kein Fehler, nur sauber beenden.
      if (this.state === "IDLE") return;
      console.error("MicCapture: auto-resume failed for device", this.deviceId, err);
      this.pushEvent("mic_capture_error", { reason: "track_ended" });
      this.teardown();
    }
  },

  // Audio-Pipeline anhalten ohne den Session-Kontext zu verlieren. Der alte
  // Recorder darf NICHT teardown triggern (onstop genullt), sonst ginge die
  // sessionId verloren.
  suspendPipeline() {
    this.stopLevelLoop();
    this.stopSilenceWatchdog();
    if (this.recorder) {
      this.recorder.onstop = null;
      this.recorder.ondataavailable = null;
      this.recorder.onerror = null;
      try {
        this.recorder.stop();
      } catch (_) {}
      this.recorder = null;
    }
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
    this.emitLocalState(false); // VU/State fällt kurz auf 0 — bewusst (#397).
  },

  // Re-Open desselben Device über ein längeres Fenster: ein Re-Plug braucht ~1–2s
  // bis das OS re-enumeriert. Retry auf JEDEN Fehler außer harten Permission-
  // Fehlern (NotAllowed/Security → sofort aufgeben). Bricht ab, wenn zwischendurch
  // gestoppt wurde.
  async reopenForResume(deviceId) {
    const audio = deviceId
      ? { deviceId: { exact: deviceId }, ...MIC_CONSTRAINTS }
      : MIC_CONSTRAINTS;
    let lastErr;
    for (let attempt = 0; attempt < 12; attempt++) {
      if (this.state === "IDLE") throw new Error("stopped_during_resume");
      try {
        return await navigator.mediaDevices.getUserMedia({ audio });
      } catch (err) {
        lastErr = err;
        if (err && (err.name === "NotAllowedError" || err.name === "SecurityError")) {
          throw err;
        }
        await sleep(500);
      }
    }
    throw lastErr;
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
    // Issue #398: bei (Re-)Start einer Session den persistierten Dismiss laden —
    // nach Reload während laufender Aufnahme bleibt das Modal so unterdrückt.
    // Stale Acks anderer Sessions dabei wegräumen.
    sweepSilenceAcks(this.sessionId);
    this.silenceAcked = readSilenceAck(this.sessionId);
    this.startSilenceWatchdog();

    this.stream.getAudioTracks().forEach((t) => {
      t.onended = () => this.handleTrackEnded();
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
    // Issue #412: carry campaign_id + source so MicLive can set its recording
    // state for the browser-local mic-handoff path (campaign_id null on the
    // system path, where MicLive's state was already set server-side).
    this.pushEvent("mic_capture_started", {
      session_id: this.sessionId,
      campaign_id: this.campaignId,
      source: this.captureSource,
    });
    this.emitLocalState(true); // Issue #415
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
      // Issue #398: in dieser Session bereits bewusst weg-geklickt → still bleiben.
      if (this.silenceAcked) return;
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
    this.campaignId = null;
    this.captureSource = null;
    this.deviceId = null; // Issue #397
    this.resuming = false; // Issue #397
    this.state = "IDLE";
    this.emitLocalState(false); // Issue #415
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

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

// ── Issue #398: persistierter Stille-Dismiss (localStorage, pro session_id) ──
// localStorage kann werfen (Safari Private Mode, deaktivierte Storage) — alle
// Zugriffe defensiv in try/catch, Default „nicht acked".
function readSilenceAck(sessionId) {
  if (!sessionId) return false;
  try {
    return localStorage.getItem(SILENCE_ACK_PREFIX + sessionId) === "1";
  } catch (_) {
    return false;
  }
}

function writeSilenceAck(sessionId) {
  if (!sessionId) return;
  try {
    localStorage.setItem(SILENCE_ACK_PREFIX + sessionId, "1");
  } catch (_) {}
}

function clearSilenceAck(sessionId) {
  if (!sessionId) return;
  try {
    localStorage.removeItem(SILENCE_ACK_PREFIX + sessionId);
  } catch (_) {}
}

// Alte Acks anderer Sessions wegräumen, damit localStorage nicht wächst, falls
// eine Session ohne sauberen Stop endete (z.B. Tab-Close direkt nach Dismiss).
function sweepSilenceAcks(keepSessionId) {
  try {
    const stale = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && k.startsWith(SILENCE_ACK_PREFIX) && k !== SILENCE_ACK_PREFIX + keepSessionId) {
        stale.push(k);
      }
    }
    stale.forEach((k) => localStorage.removeItem(k));
  } catch (_) {}
}
