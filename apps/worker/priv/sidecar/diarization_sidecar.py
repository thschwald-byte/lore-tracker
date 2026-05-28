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

import torch
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
    hf_token = os.environ.get("HUGGINGFACE_TOKEN")
    if not hf_token:
        logger.warning(
            "HUGGINGFACE_TOKEN not set — model load will fail for gated HF checkpoints"
        )
    logger.info("Loading diarization model %s …", MODEL_ID)
    _pipeline = Pipeline.from_pretrained(MODEL_ID, use_auth_token=hf_token)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
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
    diarization = _pipeline(req.wav_path, **kwargs)

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
