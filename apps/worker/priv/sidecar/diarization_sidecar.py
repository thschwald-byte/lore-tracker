"""
Diarization sidecar for Worker.Recording.Diarize (Issue #19).

Accepts POST /diarize with {"wav_path": "...", "num_speakers": N} and returns
speaker segments [{speaker_label, start_ms, end_ms}, ...].

Audio input must be 16 kHz Mono WAV — the Worker converts WebM/Opus via ffmpeg
before calling this endpoint.

Model: pyannote/speaker-diarization-3.1 (HF Hub checkpoint).
Requires HUGGINGFACE_TOKEN env-var (model is gated, needs HF account accept).
Default port: 8766 (8765 is the NLI sidecar).

Setup:
  pip install -r requirements.txt
  HUGGINGFACE_TOKEN=hf_... uvicorn diarization_sidecar:app --port 8766

For autostart see diarization-sidecar.service (systemd user unit).

pyannote version: pin to 3.3.2 — 4.0.x has a 6× VRAM regression (~9.5 GB)
that makes it unusable on consumer GPUs with 8 GB VRAM (issue #1963, unfixed).
"""

from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

import soundfile as sf
import torch
import torchaudio

# pyannote.audio 3.3.2 wurde gegen torchaudio <2.9 geschrieben; ROCm-torch
# gibt's aber nur als 2.9.x (matching torchaudio 2.9). 2.9 hat mehrere APIs
# entfernt, die pyannote beim Import noch anfasst — hier geshimmt. Die
# betroffenen Symbole stecken in pyannotes Trainings-Modulen, die bei reiner
# Inference nie ausgeführt werden; nur ihr Import muss durchgehen.
#
# 1) list_audio_backends(): wählt in core/io.py den I/O-Backend-String. Wir
#    laden ohnehin selbst via soundfile (s. /diarize) → soundfile zurückgeben.
if not hasattr(torchaudio, "list_audio_backends"):
    torchaudio.list_audio_backends = lambda: ["soundfile"]

# 2) AudioMetaData: in 2.9 komplett entfernt; in den Segmentation-Task-Mixins
#    nur als Typ-Container importiert. Minimal-Dataclass als Ersatz.
if not hasattr(torchaudio, "AudioMetaData"):
    from dataclasses import dataclass as _dc

    @_dc
    class _AudioMetaData:
        sample_rate: int = 0
        num_frames: int = 0
        num_channels: int = 0
        bits_per_sample: int = 0
        encoding: str = "UNKNOWN"

    torchaudio.AudioMetaData = _AudioMetaData

# 3) torch >=2.6 setzt `torch.load(weights_only=True)` als Default; die
#    pyannote-Lightning-Checkpoints enthalten Nicht-Tensor-Globals
#    (TorchVersion, omegaconf, …) und scheitern damit. Die Gewichte kommen aus
#    dem authentifizierten offiziellen pyannote-HF-Repo (vertrauenswürdig), also
#    weights_only=False erzwingen.
_orig_torch_load = torch.load


def _torch_load_full(*args, **kwargs):
    # pytorch-lightning übergibt weights_only=True explizit → hart überschreiben.
    kwargs["weights_only"] = False
    return _orig_torch_load(*args, **kwargs)


torch.load = _torch_load_full

# 4) MIOpen (ROCm) hat auf RDNA3 (gfx1100) kaputte RNN/LSTM-Kernels →
#    `miopenStatusUnknownError` im Segmentation-LSTM. cuDNN/MIOpen für RNN
#    abschalten zwingt torch zur nativen LSTM-Implementierung, die weiter auf
#    der GPU läuft (nur ohne den optimierten MIOpen-Kernel). Auf NVIDIA/CPU
#    schadet das nicht nennenswert (Diarisierung ist Post-Processing).
torch.backends.cudnn.enabled = False

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from pyannote.audio import Pipeline

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("diarization_sidecar")

MODEL_ID = "pyannote/speaker-diarization-3.1"

_pipeline: Pipeline | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _pipeline
    # Token-Quelle: explizite Env-Var hat Vorrang; sonst `True` → nutzt den
    # gecachten `huggingface-cli login`-Token (~/.cache/huggingface/token).
    hf_token = os.environ.get("HUGGINGFACE_TOKEN") or True
    logger.info("Loading diarization model %s …", MODEL_ID)
    _pipeline = Pipeline.from_pretrained(MODEL_ID, use_auth_token=hf_token)
    if _pipeline is None:
        raise RuntimeError(
            f"Pipeline.from_pretrained returned None for {MODEL_ID} — "
            "Modell vermutlich gated und Bedingungen nicht akzeptiert "
            "(pyannote/speaker-diarization-3.1 UND pyannote/segmentation-3.0) "
            "oder Token ohne Read-Recht."
        )
    # Device-Wahl: DIARIZATION_DEVICE-Env hat Vorrang ("cpu"/"cuda"), sonst
    # auto. Fallback auf CPU falls die GPU (z.B. MIOpen-RNN-Bug) Probleme macht.
    forced = os.environ.get("DIARIZATION_DEVICE")
    device = torch.device(
        forced if forced else ("cuda" if torch.cuda.is_available() else "cpu")
    )
    _pipeline.to(device)
    logger.info("Model loaded on %s.", device)
    yield
    _pipeline = None


app = FastAPI(title="Diarization Sidecar", lifespan=lifespan)


class DiarizeRequest(BaseModel):
    wav_path: str
    num_speakers: int | None = None
    min_speakers: int | None = None
    max_speakers: int | None = None


class Segment(BaseModel):
    speaker_label: str
    start_ms: int
    end_ms: int


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model": MODEL_ID,
        "loaded": _pipeline is not None,
        "device": str(_pipeline.device) if _pipeline is not None else None,
    }


@app.post("/diarize", response_model=list[Segment])
def diarize(req: DiarizeRequest):
    if _pipeline is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    if not os.path.exists(req.wav_path):
        raise HTTPException(status_code=400, detail=f"File not found: {req.wav_path}")

    kwargs: dict = {}
    if req.num_speakers is not None:
        kwargs["num_speakers"] = req.num_speakers
    elif req.min_speakers is not None or req.max_speakers is not None:
        if req.min_speakers is not None:
            kwargs["min_speakers"] = req.min_speakers
        if req.max_speakers is not None:
            kwargs["max_speakers"] = req.max_speakers

    logger.info(
        "Diarizing %s (kwargs=%s) …", os.path.basename(req.wav_path), kwargs
    )

    # torchaudio 2.9 routet `load()` über TorchCodec — pyannotes internes
    # Datei-Laden bricht damit. Wir laden das (vom Worker schon auf 16 kHz Mono
    # PCM konvertierte) WAV selbst via soundfile und übergeben den Waveform-
    # Tensor direkt, statt pyannote den Pfad laden zu lassen.
    audio, sr = sf.read(req.wav_path, dtype="float32", always_2d=True)  # (samples, channels)
    waveform = torch.from_numpy(audio.T)  # → (channels, samples)
    diarization = _pipeline({"waveform": waveform, "sample_rate": sr}, **kwargs)

    segments: list[Segment] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append(
            Segment(
                speaker_label=speaker,
                start_ms=round(turn.start * 1000),
                end_ms=round(turn.end * 1000),
            )
        )

    logger.info(
        "Diarization done: %d segments, %d speakers",
        len(segments),
        len({s.speaker_label for s in segments}),
    )
    return segments
