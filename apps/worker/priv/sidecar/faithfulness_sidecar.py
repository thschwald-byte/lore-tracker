"""
NLI sidecar for Worker.LLM.Faithfulness (Issue #11 Phase 2).

Accepts POST /score with {"premise": "...", "hypothesis": "..."} and
returns the NLI label + per-class scores.  The Worker calls this once
per claim extracted from a generated summary.

Model: cross-encoder/nli-deberta-v3-large (~400 MB, CPU-friendly).
Default port: 8765 (override with --port).

Setup:
  pip install -r requirements.txt
  uvicorn faithfulness_sidecar:app --port 8765

For autostart see faithfulness-sidecar.service (systemd user unit).
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import CrossEncoder

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("faithfulness_sidecar")

MODEL_NAME = "cross-encoder/nli-deberta-v3-large"
# Labels returned by this cross-encoder in score-vector order:
LABELS = ["contradiction", "entailment", "neutral"]

_model: CrossEncoder | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model
    logger.info("Loading NLI model %s …", MODEL_NAME)
    _model = CrossEncoder(MODEL_NAME)
    logger.info("Model loaded.")
    yield
    _model = None


app = FastAPI(title="Faithfulness NLI Sidecar", lifespan=lifespan)


class ScoreRequest(BaseModel):
    premise: str
    hypothesis: str


class ScoreResponse(BaseModel):
    label: Literal["contradiction", "entailment", "neutral"]
    scores: dict[str, float]


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME, "loaded": _model is not None}


@app.post("/score", response_model=ScoreResponse)
def score(req: ScoreRequest):
    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    raw_scores: list[float] = _model.predict(
        [(req.premise, req.hypothesis)], apply_softmax=True
    )[0].tolist()

    scores_map = {label: round(float(s), 4) for label, s in zip(LABELS, raw_scores)}
    best_label = max(scores_map, key=lambda k: scores_map[k])

    return ScoreResponse(label=best_label, scores=scores_map)


@app.post("/score_batch")
def score_batch(pairs: list[ScoreRequest]):
    """Score multiple (premise, hypothesis) pairs in one call — more efficient."""
    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    raw = _model.predict(
        [(p.premise, p.hypothesis) for p in pairs], apply_softmax=True
    ).tolist()

    results = []
    for row in raw:
        scores_map = {label: round(float(s), 4) for label, s in zip(LABELS, row)}
        best_label = max(scores_map, key=lambda k: scores_map[k])
        results.append({"label": best_label, "scores": scores_map})

    return results
