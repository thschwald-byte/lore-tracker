// Audible signals for session/recording state transitions (Issue #9).
//
// LiveView pushes `signal:play` with `{kind: "rec_start" | "rec_stop" |
// "session_start" | "session_end"}`. We synthesize short beeps via the
// Web Audio API — no sample files, no asset pipeline coupling.
//
// Tone scheme (intentional, so people in the room can hear which event):
//   rec_start     — single short 880 Hz bip
//   rec_stop      — single short 440 Hz bip
//   session_start — two-tone rise 660 → 990 Hz
//   session_end   — two-tone fall 880 → 440 Hz
//   mic_join      — two-tone rise 550 → 770 Hz (quieter, shorter than session_start)
//   mic_leave     — two-tone fall 770 → 550 Hz (mirror of mic_join)
//
// Autoplay note: AudioContext is created lazily on first play, after at
// least one user gesture has happened on the page (REC click etc.).
// Sessions started by another worker may still arrive without a local
// gesture — in that case the browser silently drops the beep, which is
// fine (the visual state still updates).

let ctx = null;

function ensureCtx() {
  if (ctx) return ctx;
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) return null;
  ctx = new AC();
  return ctx;
}

function tone(freq, durationMs, startOffsetMs = 0, gain = 0.18) {
  const c = ensureCtx();
  if (!c) return;
  const t0 = c.currentTime + startOffsetMs / 1000;
  const osc = c.createOscillator();
  const g = c.createGain();
  osc.type = "sine";
  osc.frequency.value = freq;
  // ADSR-ish envelope so it doesn't click
  g.gain.setValueAtTime(0, t0);
  g.gain.linearRampToValueAtTime(gain, t0 + 0.01);
  g.gain.linearRampToValueAtTime(gain, t0 + durationMs / 1000 - 0.02);
  g.gain.linearRampToValueAtTime(0, t0 + durationMs / 1000);
  osc.connect(g).connect(c.destination);
  osc.start(t0);
  osc.stop(t0 + durationMs / 1000);
}

const PATTERNS = {
  rec_start: () => tone(880, 180),
  rec_stop: () => tone(440, 180),
  session_start: () => {
    tone(660, 140, 0);
    tone(990, 220, 160);
  },
  session_end: () => {
    tone(880, 140, 0);
    tone(440, 220, 160);
  },
  mic_join: () => {
    tone(550, 100, 0, 0.12);
    tone(770, 140, 110, 0.12);
  },
  mic_leave: () => {
    tone(770, 100, 0, 0.12);
    tone(550, 140, 110, 0.12);
  },
};

export const Signals = {
  mounted() {
    this.handleEvent("signal:play", ({ kind }) => {
      const fn = PATTERNS[kind];
      if (fn) fn();
    });
  },
};
