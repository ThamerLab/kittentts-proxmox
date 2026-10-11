import io
import os
import secrets
import threading
from functools import lru_cache
from pathlib import Path
from typing import Literal
import soundfile as sf
from fastapi import FastAPI, Depends, Header, HTTPException
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel, Field

MODEL_ID = os.getenv("MODEL_ID", "KittenML/kitten-tts-2")
WEIGHTS = os.getenv("MODEL_WEIGHTS", "emb4")
API_KEY = os.getenv("API_KEY", "")
MAX_CHARS = int(os.getenv("MAX_TEXT_CHARS", "2000"))
_lock = threading.Lock()
app = FastAPI(title="KittenTTS Home", version="1.0.0")

def authorize(x_api_key: str | None = Header(default=None)):
    if not API_KEY or not secrets.compare_digest(x_api_key or "", API_KEY):
        raise HTTPException(status_code=401, detail="Invalid API key")

@lru_cache(maxsize=1)
def model():
    from kittenml import KittenTTS
    if MODEL_ID == "KittenML/kitten-tts-2":
        return KittenTTS(MODEL_ID, weights=WEIGHTS)
    return KittenTTS(MODEL_ID)

class SpeechRequest(BaseModel):
    text: str = Field(min_length=1)
    voice: str = "Luna"
    preset: Literal["balanced", "expressive", "stable"] | None = None

@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_ID, "loaded": model.cache_info().currsize > 0}

@app.get("/api/voices", dependencies=[Depends(authorize)])
def voices():
    with _lock:
        try:
            result = list(model().available_voices)
        except Exception as exc:
            raise HTTPException(status_code=503, detail="Model initialization failed; inspect logs") from exc
    return {"voices": result, "model": MODEL_ID}

@app.post("/api/tts", dependencies=[Depends(authorize)])
def synthesize(payload: SpeechRequest):
    if not payload.text.strip():
        raise HTTPException(status_code=422, detail="Text cannot be blank")
    if len(payload.text) > MAX_CHARS:
        raise HTTPException(status_code=413, detail=f"Maximum {MAX_CHARS} characters")
    with _lock:
        try:
            engine = model()
            if payload.voice not in engine.available_voices:
                raise HTTPException(status_code=422, detail="Unknown voice; see /api/voices")
            kwargs = {"voice": payload.voice}
            if payload.preset is not None:
                kwargs["preset"] = payload.preset
            audio = engine.generate(payload.text, **kwargs)
            rate = engine.sample_rate
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=503, detail="Synthesis failed; inspect logs") from exc
    buf = io.BytesIO()
    sf.write(buf, audio, rate, format="WAV")
    return Response(buf.getvalue(), media_type="audio/wav",
        headers={"Content-Disposition": 'attachment; filename="speech.wav"', "Cache-Control": "no-store"})

@app.get("/", response_class=HTMLResponse)
def home():
    return Path(__file__).with_name("index.html").read_text(encoding="utf-8")
